import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var receivedRecordingBuffer = false

    /// ACTIVE service state. This deliberately does NOT mean that microphone
    /// input is running. TypeVoice prepares the service while foregrounded,
    /// keeps the background audio service alive, and only opens microphone IO
    /// for an actual dictation.
    private var servicePrepared = false

    private var standbyGeneration: UInt64 = 0
    private var standbyTask: Task<Void, Never>?

    var onStandbyExpired: (() -> Void)?

    /// True only while one dictation is actively capturing microphone buffers.
    var isActive: Bool {
        isRecording && isEngineRunning
    }

    /// Compatibility name used by the rest of the app. In the ACTIVE-service
    /// architecture this means "the foreground-prepared voice service is ready",
    /// not "the microphone is currently open".
    var isWarmReady: Bool {
        servicePrepared
    }

    var isStandbyReady: Bool {
        servicePrepared && !isRecording
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

    /// Prepare the ACTIVE service without touching microphone input.
    ///
    /// The containing app has already activated AVAudioSession and started its
    /// background audio anchor before calling this method. No AVAudioEngine input
    /// node or tap is started here, so the microphone privacy indicator remains off.
    func warmUp(
        firstBufferTimeout: Duration = .milliseconds(900)
    ) async throws {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        teardownInputEngine()
        servicePrepared = true
    }

    /// Service-idle timeout. Unlike the previous implementation this timer is
    /// not driven by discarded microphone buffers. The background audio service
    /// keeps the process eligible to run while ACTIVE.
    func setStandbyExpiry(after seconds: TimeInterval) {
        clearStandbyExpiry()

        guard servicePrepared,
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
                  self.servicePrepared,
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

    /// Open microphone IO only for the actual dictation.
    ///
    /// The AVAudioSession is already active from the foreground-prepared service.
    /// If iOS still rejects starting input from the background, the caller reports
    /// audioStartFailed and the keyboard falls back to the foreground handoff.
    func startRecording(
        firstBufferTimeout: Duration = .milliseconds(650)
    ) async throws -> URL {
        guard servicePrepared else {
            throw MicrophoneCaptureError.warmStandbyUnavailable
        }

        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        clearStandbyExpiry()
        teardownInputEngine()

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
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

        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
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

            lock.lock()
            recordingFile = nil
            recordingURL = nil
            receivedRecordingBuffer = false
            lock.unlock()

            try? FileManager.default.removeItem(at: url)
            throw error
        }

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

    /// Finish this recording and immediately release microphone input while
    /// keeping the ACTIVE service prepared for the next keyboard activation.
    func finishRecording() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        teardownInputEngine()
        return url
    }

    /// Cancel this recording, release microphone input, but keep ACTIVE service.
    func discardRecording() {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        teardownInputEngine()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Fully release both microphone input and the prepared service state.
    func shutdown(removeRecording: Bool = true) {
        clearStandbyExpiry()

        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        teardownInputEngine()
        servicePrepared = false

        if removeRecording, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var hasReceivedRecordingBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedRecordingBuffer
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
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
            return "The voice service is no longer active. Open TypeVoice to reactivate it."
        case .noAudioFlow:
            return "The microphone started but no audio arrived."
        }
    }
}
