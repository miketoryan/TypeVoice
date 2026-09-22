import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    /// One foreground-created capture engine is kept alive only for the selected
    /// short standby window. While warm, its input tap continues receiving audio
    /// buffers but they are discarded unless a recording file is open.
    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var receivedInputBuffer = false
    private var receivedRecordingBuffer = false
    private var servicePrepared = false

    private var standbyGeneration: UInt64 = 0
    private var standbyTask: Task<Void, Never>?

    var onStandbyExpired: (() -> Void)?

    var isActive: Bool {
        isRecording && isWarmReady
    }

    var isWarmReady: Bool {
        servicePrepared && engine?.isRunning == true && tapInstalled
    }

    var isStandbyReady: Bool {
        isWarmReady && !isRecording
    }

    var isEngineRunning: Bool {
        engine?.isRunning == true
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

    /// Creates microphone IO while TypeVoice is foreground-active.
    ///
    /// This intentionally keeps the microphone engine running after a recording
    /// finishes, but only until the configured 0/10/30/60/300-second standby
    /// timer expires. That matches the efficient VoiceKing-style short warm
    /// window without reintroducing a permanent background audio service.
    func warmUp(
        firstBufferTimeout: Duration = .milliseconds(900)
    ) async throws {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        if isWarmReady {
            return
        }

        teardownInputEngine()
        servicePrepared = false

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneCaptureError.inputUnavailable
        }

        lock.lock()
        receivedInputBuffer = false
        receivedRecordingBuffer = false
        lock.unlock()

        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: format
        ) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true

        newEngine.prepare()

        do {
            try newEngine.start()
            engine = newEngine
            servicePrepared = true
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            engine = nil
            servicePrepared = false
            throw error
        }

        let startedAt = ContinuousClock.now
        while !hasReceivedInputBuffer {
            if ContinuousClock.now - startedAt >= firstBufferTimeout {
                shutdown()
                throw MicrophoneCaptureError.noAudioFlow
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func setStandbyExpiry(after seconds: TimeInterval) {
        clearStandbyExpiry()

        guard isWarmReady,
              !isRecording,
              seconds > 0 else {
            return
        }

        standbyGeneration &+= 1
        let generation = standbyGeneration
        let nanoseconds = UInt64(seconds * 1_000_000_000)

        standbyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard let self,
                  self.standbyGeneration == generation,
                  self.isWarmReady,
                  !self.isRecording else {
                return
            }

            self.onStandbyExpired?()
        }
    }

    func clearStandbyExpiry() {
        standbyGeneration &+= 1
        standbyTask?.cancel()
        standbyTask = nil
    }

    /// Opens only the recording-file gate. The microphone engine and input tap
    /// are already running from the foreground warm-up.
    func startRecording(
        firstBufferTimeout: Duration = .milliseconds(650)
    ) async throws -> URL {
        guard isWarmReady, let engine else {
            throw MicrophoneCaptureError.warmStandbyUnavailable
        }

        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        clearStandbyExpiry()

        let format = engine.inputNode.inputFormat(forBus: 0)
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

    /// Closes only the recording file. Microphone IO remains warm until the
    /// selected standby timeout expires or shutdown() is called.
    func finishRecording() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()
        return url
    }

    /// Cancels the current file capture but preserves the warm microphone engine.
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

    func shutdown(removeRecording: Bool = true) {
        clearStandbyExpiry()

        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedInputBuffer = false
        receivedRecordingBuffer = false
        lock.unlock()

        teardownInputEngine()
        servicePrepared = false

        if removeRecording, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var hasReceivedInputBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedInputBuffer
    }

    private var hasReceivedRecordingBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedRecordingBuffer
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        receivedInputBuffer = true

        if let file = recordingFile {
            receivedRecordingBuffer = true
            try? file.write(from: buffer)
        }

        lock.unlock()
    }

    private func teardownInputEngine() {
        guard let engine else {
            tapInstalled = false
            return
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }

        if engine.isRunning {
            engine.stop()
        }

        engine.reset()
        tapInstalled = false
        self.engine = nil
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
            return "The microphone standby window has ended. TypeVoice needs to reactivate in the foreground."
        case .noAudioFlow:
            return "The microphone started but no audio arrived."
        }
    }
}
