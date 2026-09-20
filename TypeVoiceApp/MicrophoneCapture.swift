import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var receivedAnyWarmBuffer = false
    private var receivedRecordingBuffer = false

    /// True only while samples are being written to the current dictation file.
    var isActive: Bool {
        isRecording
    }

    /// The input graph is already running. This is the warm-start prerequisite:
    /// keyboard requests are allowed to gate samples, but never to call engine.start().
    var isWarmReady: Bool {
        engine?.isRunning == true && tapInstalled && receivedAnyWarmBuffer
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

    /// Starts the microphone graph while TypeVoice is in the foreground.
    /// The tap stays installed and idle samples are discarded between recordings.
    func warmUp(firstBufferTimeout: Duration = .milliseconds(900)) async throws {
        if isWarmReady {
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
        receivedAnyWarmBuffer = false
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

        do {
            try newEngine.start()
            engine = newEngine
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            engine = nil
            throw error
        }

        let startedAt = ContinuousClock.now
        while !hasReceivedAnyWarmBuffer {
            if ContinuousClock.now - startedAt >= firstBufferTimeout {
                shutdown(removeRecording: true)
                throw MicrophoneCaptureError.noAudioFlow
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Begins a dictation by opening the file gate on the already-running graph.
    /// This function intentionally never calls AVAudioEngine.start().
    func startRecording(firstBufferTimeout: Duration = .milliseconds(650)) async throws -> URL {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        guard isWarmReady, let engine, engine.isRunning else {
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

        let startedAt = ContinuousClock.now
        while !hasReceivedRecordingBuffer {
            if ContinuousClock.now - startedAt >= firstBufferTimeout {
                discardRecording()
                throw MicrophoneCaptureError.noAudioFlow
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        return url
    }

    /// Closes only the recording gate. The input engine remains warm.
    func finishRecording() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()
        return url
    }

    /// Discards the current recording while preserving the warm engine.
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

    /// Fully releases the input graph. Used when Quick Dictation is disabled or
    /// the audio system was interrupted/reset.
    func shutdown(removeRecording: Bool = true) {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedAnyWarmBuffer = false
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

    private var hasReceivedAnyWarmBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedAnyWarmBuffer
    }

    private var hasReceivedRecordingBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedRecordingBuffer
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        receivedAnyWarmBuffer = true
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
            return "The warm microphone engine is no longer available. Open TypeVoice to restore it."
        case .noAudioFlow:
            return "The microphone started but no audio arrived."
        }
    }
}
