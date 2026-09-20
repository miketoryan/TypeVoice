import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var keepAlivePlayer: AVAudioPlayerNode?
    private var keepAliveBuffer: AVAudioPCMBuffer?

    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var receivedRecordingBuffer = false

    /// True only while microphone samples are actively being written.
    var isActive: Bool {
        isRecording && engine?.isRunning == true && tapInstalled
    }

    /// v0.20 standby invariant:
    /// - one AVAudioEngine is already running;
    /// - only a silent OUTPUT node is rendering;
    /// - no input tap exists, so the microphone path is idle.
    ///
    /// Keyboard dictation is allowed only from this state. Starting a dictation
    /// must never call AVAudioEngine.start() from the background.
    var isStandbyReady: Bool {
        engine?.isRunning == true
            && keepAlivePlayer?.isPlaying == true
            && !tapInstalled
            && !isRecording
    }

    var isEngineRunning: Bool {
        engine?.isRunning == true
    }

    /// Compatibility name used by the bridge/UI.
    var isWarmReady: Bool {
        isStandbyReady || isActive
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

    /// Creates one engine while TypeVoice is foregrounded and keeps that engine
    /// running with a looping silent OUTPUT buffer. The input node is deliberately
    /// untouched here. This keeps background audio execution alive without
    /// continuously rendering microphone input.
    func armActiveSession() throws {
        if isStandbyReady {
            return
        }

        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        shutdown(removeRecording: true)

        let newEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 8_000,
            channels: 1
        ) else {
            throw MicrophoneCaptureError.outputAnchorUnavailable
        }

        let frameCapacity: AVAudioFrameCount = 8_000
        guard let silentBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw MicrophoneCaptureError.outputAnchorUnavailable
        }

        silentBuffer.frameLength = frameCapacity
        if let channelData = silentBuffer.floatChannelData {
            channelData[0].initialize(
                repeating: 0,
                count: Int(frameCapacity)
            )
        }

        newEngine.attach(player)
        newEngine.connect(
            player,
            to: newEngine.mainMixerNode,
            format: outputFormat
        )
        newEngine.prepare()

        do {
            try newEngine.start()
        } catch {
            newEngine.disconnectNodeOutput(player)
            newEngine.detach(player)
            throw error
        }

        player.scheduleBuffer(
            silentBuffer,
            at: nil,
            options: .loops
        )
        player.play()

        guard newEngine.isRunning, player.isPlaying else {
            player.stop()
            newEngine.stop()
            newEngine.disconnectNodeOutput(player)
            newEngine.detach(player)
            throw MicrophoneCaptureError.outputAnchorUnavailable
        }

        engine = newEngine
        keepAlivePlayer = player
        keepAliveBuffer = silentBuffer
        tapInstalled = false
    }

    /// Starts microphone capture without starting/restarting the engine.
    ///
    /// The engine was already started in the foreground by armActiveSession().
    /// A keyboard request only attaches the input tap to that running graph and
    /// waits for the first real microphone buffer.
    func startRecording(
        firstBufferTimeout: Duration = .milliseconds(800)
    ) async throws -> URL {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        guard isStandbyReady,
              let engine,
              engine.isRunning else {
            throw MicrophoneCaptureError.activeStandbyUnavailable
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
            input.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: nil
            ) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            tapInstalled = true

            // Deliberately NO engine.start() here.
            try await waitForRecordingBuffer(timeout: firstBufferTimeout)
            return url
        } catch {
            closeInputTap()
            discardRecordingFile()
            throw error
        }
    }

    /// Closes the microphone path but keeps the same output-only engine running.
    /// This is the normal return to standby after every dictation.
    func finishRecordingToStandby() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        closeInputTap()
        return url
    }

    /// Cancels the current dictation and returns to output-only standby.
    func discardRecordingToStandby() {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        closeInputTap()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Fully releases the audio graph. Used when Quick Dictation is disabled,
    /// when iOS interrupts/resets audio, or before a foreground rebuild.
    func shutdown(removeRecording: Bool = true) {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        closeInputTap()

        keepAlivePlayer?.stop()

        if let engine {
            if engine.isRunning {
                engine.stop()
            }

            if let keepAlivePlayer {
                engine.disconnectNodeOutput(keepAlivePlayer)
                engine.detach(keepAlivePlayer)
            }

            engine.reset()
        }

        keepAlivePlayer = nil
        keepAliveBuffer = nil
        self.engine = nil

        if removeRecording, let url {
            try? FileManager.default.removeItem(at: url)
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

    private var hasReceivedRecordingBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedRecordingBuffer
    }

    private func closeInputTap() {
        guard tapInstalled else { return }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
    }

    private func discardRecordingFile() {
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

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
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
    case activeStandbyUnavailable
    case outputAnchorUnavailable
    case noAudioFlow

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .inputUnavailable:
            return "The microphone input is unavailable."
        case .activeStandbyUnavailable:
            return "The active standby audio engine is no longer available. Open TypeVoice to restore it."
        case .outputAnchorUnavailable:
            return "TypeVoice could not start the output-only background audio anchor."
        case .noAudioFlow:
            return "The microphone path opened but no audio arrived."
        }
    }
}
