import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    /// One long-lived AVAudioEngine for both ACTIVE standby and RECORDING.
    ///
    /// ACTIVE:
    /// - engine is running
    /// - output graph is alive
    /// - no microphone tap is installed
    ///
    /// RECORDING:
    /// - the SAME engine stays running
    /// - an input tap is temporarily installed
    ///
    /// This is the key Typeless-style experiment: release microphone input
    /// without stopping the audio engine that owns the background audio service.
    private var engine: AVAudioEngine?
    private var servicePrepared = false

    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var inputTapInstalled = false
    private var receivedRecordingBuffer = false

    private var standbyGeneration: UInt64 = 0
    private var standbyTask: Task<Void, Never>?

    var onStandbyExpired: (() -> Void)?

    var isActive: Bool {
        isRecording && isEngineRunning && inputTapInstalled
    }

    /// "Warm" now means the long-lived output-side engine is still running.
    /// It does NOT mean microphone input is open.
    var isWarmReady: Bool {
        servicePrepared && engine?.isRunning == true
    }

    var isStandbyReady: Bool {
        isWarmReady && !isRecording && !inputTapInstalled
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

    /// Build and start the long-lived output-side engine while TypeVoice is
    /// foreground-active. Deliberately do NOT touch engine.inputNode here.
    ///
    /// Accessing mainMixerNode creates the default mixer -> outputNode path.
    /// With no source/input connected the graph renders silence, but the engine
    /// itself remains running under the app's audio background mode.
    func warmUp(
        firstBufferTimeout: Duration = .milliseconds(900)
    ) async throws {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        if isWarmReady {
            return
        }

        shutdown(removeRecording: true)

        let newEngine = AVAudioEngine()

        // Instantiate the output graph without accessing inputNode. Keeping the
        // mixer at zero is explicit: ACTIVE standby must not emit audible sound.
        let mixer = newEngine.mainMixerNode
        mixer.outputVolume = 0
        _ = newEngine.outputNode

        newEngine.prepare()
        try newEngine.start()

        guard newEngine.isRunning else {
            newEngine.stop()
            newEngine.reset()
            throw MicrophoneCaptureError.serviceUnavailable
        }

        engine = newEngine
        servicePrepared = true
    }

    /// Service-idle timeout. If the engine truly supplies background execution,
    /// this task continues to be serviced while ACTIVE. A generation token
    /// prevents an older expiry from tearing down a newer service session.
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

    /// Start microphone capture on the already-running service engine.
    ///
    /// No AVAudioEngine allocation, prepare(), start(), AudioSession activation,
    /// or category mutation happens on this hot/background path. We only install
    /// an input tap on the SAME engine that was started in foreground.
    func startRecording(
        firstBufferTimeout: Duration = .milliseconds(650)
    ) async throws -> URL {
        guard servicePrepared,
              let engine,
              engine.isRunning else {
            throw MicrophoneCaptureError.warmStandbyUnavailable
        }

        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        clearStandbyExpiry()
        removeInputTapKeepingService()

        // inputNode is intentionally first touched here, at the moment the user
        // explicitly asks to record.
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

        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: nil
        ) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        inputTapInstalled = true

        // The engine is intentionally NOT restarted here. If installing an input
        // tap on a foreground-started running engine is accepted by iOS, audio
        // should begin flowing immediately.
        let startedAt = ContinuousClock.now
        while !hasReceivedRecordingBuffer {
            if !engine.isRunning {
                discardRecording()
                throw MicrophoneCaptureError.serviceUnavailable
            }

            if ContinuousClock.now - startedAt >= firstBufferTimeout {
                discardRecording()
                throw MicrophoneCaptureError.noAudioFlow
            }

            try await Task.sleep(for: .milliseconds(20))
        }

        return url
    }

    /// Finish one dictation: close the file and remove only microphone input.
    /// The long-lived engine remains running and returns to ACTIVE standby.
    func finishRecording() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        removeInputTapKeepingService()
        return url
    }

    /// Cancel one dictation: remove microphone input but keep the service engine.
    func discardRecording() {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        removeInputTapKeepingService()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Fully release the ACTIVE service. This is the only normal lifecycle path
    /// that stops and destroys the long-lived AVAudioEngine.
    func shutdown(removeRecording: Bool = true) {
        clearStandbyExpiry()

        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()

        removeInputTapKeepingService()

        if let engine {
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
        }

        self.engine = nil
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

    /// Remove microphone capture without touching engine.start()/stop().
    private func removeInputTapKeepingService() {
        guard inputTapInstalled else { return }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
        }

        inputTapInstalled = false
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
            return "The existing audio service stayed active, but microphone input produced no audio."
        case .serviceUnavailable:
            return "The ACTIVE AVAudioEngine service stopped unexpectedly."
        }
    }
}
