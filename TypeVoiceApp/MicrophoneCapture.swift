import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var receivedAnyPreparedBuffer = false
    private var receivedRecordingBuffer = false

    /// True only while samples are actively being written to a dictation file.
    var isActive: Bool {
        isRecording && engine?.isRunning == true
    }

    /// The exact input graph and tap already exist and have previously delivered
    /// real audio. In standby the engine is PAUSED, not stopped/reset/destroyed.
    var isPreparedForResume: Bool {
        engine != nil && tapInstalled && receivedAnyPreparedBuffer
    }

    var isEngineRunning: Bool {
        engine?.isRunning == true
    }

    /// Compatibility name used by AppModel. "Warm" now means prepared+paused
    /// standby is available; it no longer means the microphone engine is running.
    var isWarmReady: Bool {
        isPreparedForResume
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordingFile != nil
    }

    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }

        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Builds and validates the graph while TypeVoice is foregrounded, then
    /// pauses it. The graph/tap stay prepared while active audio processing stops.
    func preparePausedStandby(
        firstBufferTimeout: Duration = .milliseconds(900)
    ) async throws {
        if isPreparedForResume {
            try await validateAndPausePreparedEngine(
                firstBufferTimeout: firstBufferTimeout
            )
            return
        }

        shutdown(removeRecording: true)

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneCaptureError.inputUnavailable
        }

        lock.lock()
        receivedAnyPreparedBuffer = false
        receivedRecordingBuffer = false
        lock.unlock()

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil
        ) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true

        newEngine.prepare()
        engine = newEngine

        do {
            try newEngine.start()
            try await waitForPreparedBuffer(timeout: firstBufferTimeout)
            newEngine.pause()
        } catch {
            shutdown(removeRecording: true)
            throw error
        }
    }

    /// Foreground recovery for an existing prepared graph. It proves that the
    /// same graph can still start, sees a real buffer, then returns to pause.
    private func validateAndPausePreparedEngine(
        firstBufferTimeout: Duration
    ) async throws {
        guard let engine, tapInstalled else {
            throw MicrophoneCaptureError.warmStandbyUnavailable
        }

        if engine.isRunning {
            engine.pause()
        }

        lock.lock()
        receivedAnyPreparedBuffer = false
        lock.unlock()

        do {
            try engine.start()
            try await waitForPreparedBuffer(timeout: firstBufferTimeout)
            engine.pause()
        } catch {
            throw error
        }
    }

    /// Resumes the SAME prepared engine from its paused state and opens the file
    /// gate. This is the only background engine.start() in the experiment.
    func startRecording(
        firstBufferTimeout: Duration = .milliseconds(650)
    ) async throws -> URL {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        guard isPreparedForResume,
              let engine,
              tapInstalled else {
            throw MicrophoneCaptureError.warmStandbyUnavailable
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneCaptureError.inputUnavailable
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typevoice-\(UUID().uuidString.lowercased())")
            .appendingPathExtension("wav")

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        lock.lock()
        recordingURL = url
        recordingFile = file
        receivedRecordingBuffer = false
        lock.unlock()

        do {
            if !engine.isRunning {
                try engine.start()
            }

            try await waitForRecordingBuffer(timeout: firstBufferTimeout)
            return url
        } catch {
            discardRecording()
            if engine.isRunning {
                engine.pause()
            }
            throw error
        }
    }

    /// Closes the recording gate and pauses the engine without destroying the
    /// graph. The next dictation resumes this same prepared engine.
    func finishRecordingAndPause() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        if engine?.isRunning == true {
            engine?.pause()
        }

        return url
    }

    /// Discards current recording and returns the existing graph to paused standby.
    func discardRecordingAndPause() {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        if engine?.isRunning == true {
            engine?.pause()
        }

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes only the file gate; used after a failed resume while the graph
    /// itself may still be reusable for foreground recovery.
    func discardRecording() {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Fully releases the prepared graph. Used when Quick Dictation is disabled
    /// or iOS invalidates the audio stack.
    func shutdown(removeRecording: Bool = true) {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedAnyPreparedBuffer = false
        receivedRecordingBuffer = false
        lock.unlock()

        if let engine {
            if engine.isRunning {
                engine.stop()
            }

            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }

            engine.reset()
        }

        tapInstalled = false
        self.engine = nil

        if removeRecording, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func waitForPreparedBuffer(timeout: Duration) async throws {
        let startedAt = ContinuousClock.now

        while !hasReceivedAnyPreparedBuffer {
            if ContinuousClock.now - startedAt >= timeout {
                throw MicrophoneCaptureError.noAudioFlow
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForRecordingBuffer(timeout: Duration) async throws {
        let startedAt = ContinuousClock.now

        while !hasReceivedRecordingBuffer {
            if ContinuousClock.now - startedAt >= timeout {
                throw MicrophoneCaptureError.noAudioFlow
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var hasReceivedAnyPreparedBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedAnyPreparedBuffer
    }

    private var hasReceivedRecordingBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedRecordingBuffer
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        receivedAnyPreparedBuffer = true
        let file = recordingFile

        if let file {
            receivedRecordingBuffer = true
            try? file.write(from: buffer)
        }
        lock.unlock()
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case alreadyRecording
    case inputUnavailable
    case warmStandbyUnavailable
    case noAudioFlow

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .inputUnavailable:
            return "The microphone input is unavailable."
        case .warmStandbyUnavailable:
            return "The prepared microphone engine is no longer available. Open TypeVoice to restore it."
        case .noAudioFlow:
            return "The microphone engine started but no audio arrived."
        }
    }
}
