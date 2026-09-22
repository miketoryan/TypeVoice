import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    /// Long-lived output-side engine used only for the ACTIVE background service.
    /// It never touches inputNode, so standby does not intentionally hold the mic.
    private var serviceEngine: AVAudioEngine?
    private var servicePrepared = false

    /// Short-lived microphone engine used only during one dictation.
    /// This is deliberately separate from serviceEngine.
    private var captureEngine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var captureTapInstalled = false
    private var receivedRecordingBuffer = false

    private var standbyGeneration: UInt64 = 0
    private var standbyTask: Task<Void, Never>?

    var onStandbyExpired: (() -> Void)?

    var isActive: Bool {
        isRecording && captureEngine?.isRunning == true && captureTapInstalled
    }

    /// ACTIVE service readiness, independent of microphone capture.
    var isWarmReady: Bool {
        servicePrepared && serviceEngine?.isRunning == true
    }

    var isStandbyReady: Bool {
        isWarmReady && !isRecording
    }

    var isEngineRunning: Bool {
        captureEngine?.isRunning == true
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

    /// Start the long-lived ACTIVE service while the containing app is foreground.
    ///
    /// Important: do not touch serviceEngine.inputNode here. The graph is
    /// output-side only. The microphone engine is a separate object created by
    /// startRecording().
    func warmUp(
        firstBufferTimeout: Duration = .milliseconds(900)
    ) async throws {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        if isWarmReady {
            return
        }

        teardownServiceEngine()
        teardownCaptureEngine()

        let newServiceEngine = AVAudioEngine()

        // Instantiate the normal mixer -> output hardware graph. There is no
        // player/source node and no microphone input connected during standby.
        _ = newServiceEngine.mainMixerNode
        _ = newServiceEngine.outputNode

        newServiceEngine.prepare()
        try newServiceEngine.start()

        guard newServiceEngine.isRunning else {
            newServiceEngine.stop()
            newServiceEngine.reset()
            throw MicrophoneCaptureError.serviceUnavailable
        }

        serviceEngine = newServiceEngine
        servicePrepared = true
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

    /// Start one microphone capture without stopping the ACTIVE service engine.
    ///
    /// This deliberately creates a SECOND AVAudioEngine. If the foreground-
    /// created service engine keeps the app executing in background, the capture
    /// engine can be started on demand. If iOS rejects that hot background start,
    /// the caller's existing foreground fallback retries the same method after
    /// TypeVoice becomes active.
    func startRecording(
        firstBufferTimeout: Duration = .milliseconds(650)
    ) async throws -> URL {
        guard isWarmReady else {
            throw MicrophoneCaptureError.warmStandbyUnavailable
        }

        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        clearStandbyExpiry()
        teardownCaptureEngine()

        let newCaptureEngine = AVAudioEngine()
        let input = newCaptureEngine.inputNode
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
        captureTapInstalled = true

        newCaptureEngine.prepare()

        do {
            try newCaptureEngine.start()
            captureEngine = newCaptureEngine
        } catch {
            input.removeTap(onBus: 0)
            captureTapInstalled = false

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

    /// End microphone capture only. Keep the ACTIVE service engine running.
    func finishRecording() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        teardownCaptureEngine()
        return url
    }

    /// Cancel microphone capture only. Keep the ACTIVE service engine running.
    func discardRecording() {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        teardownCaptureEngine()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stop both layers. This is the equivalent of Typeless stopService().
    func shutdown(removeRecording: Bool = true) {
        clearStandbyExpiry()

        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        teardownCaptureEngine()
        teardownServiceEngine()
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

    private func teardownCaptureEngine() {
        guard let engine = captureEngine else {
            captureTapInstalled = false
            return
        }

        if captureTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }

        if engine.isRunning {
            engine.stop()
        }

        engine.reset()
        captureTapInstalled = false
        captureEngine = nil
    }

    private func teardownServiceEngine() {
        if let engine = serviceEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
        }

        serviceEngine = nil
        servicePrepared = false
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case alreadyRecording
    case inputUnavailable
    case warmStandbyUnavailable
    case noAudioFlow
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .inputUnavailable:
            return "The microphone input is unavailable."
        case .warmStandbyUnavailable:
            return "The ACTIVE voice service is no longer running. Open TypeVoice to reactivate it."
        case .noAudioFlow:
            return "The microphone engine started but no audio arrived."
        case .serviceUnavailable:
            return "The ACTIVE audio service engine stopped unexpectedly."
        }
    }
}
