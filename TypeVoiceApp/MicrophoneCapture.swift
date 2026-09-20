import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var receivedWarmBuffer = false
    private var receivedRecordingBuffer = false
    private var lastAudioBufferTimestamp: TimeInterval = 0
    private var standbyExpiryTimestamp: TimeInterval = 0
    private var standbyGeneration: UInt64 = 0

    /// Fired on the main queue when the CURRENT warm-idle window expires.
    /// A generation token prevents a delayed timeout callback from an older
    /// session from tearing down a microphone that has already been re-warmed.
    var onStandbyExpired: (() -> Void)?

    /// True only while one dictation is being written to disk.
    var isActive: Bool {
        isRecording && isWarmReady
    }

    /// Warm-microphone invariant:
    /// - the input AVAudioEngine was started while TypeVoice was foregrounded;
    /// - one persistent input tap stays installed for the whole ready window;
    /// - idle buffers are discarded unless recordingFile is non-nil.
    ///
    /// This avoids every background attempt to restart microphone input.
    var isWarmReady: Bool {
        engine?.isRunning == true
            && tapInstalled
            && hasRecentAudioFlow
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

    /// Starts the microphone input graph once while TypeVoice is foregrounded.
    /// The tap remains installed until the configured standby window expires,
    /// Quick Dictation is disabled, or iOS interrupts/resets the audio service.
    func warmUp(
        firstBufferTimeout: Duration = .milliseconds(900)
    ) async throws {
        if isWarmReady {
            return
        }

        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        shutdown(removeRecording: true)

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneCaptureError.inputUnavailable
        }

        lock.lock()
        receivedWarmBuffer = false
        receivedRecordingBuffer = false
        lastAudioBufferTimestamp = 0
        lock.unlock()

        // Use the input bus's live format. Passing nil is more resilient across
        // route changes than pinning a format read just before installTap().
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
            throw error
        }

        let startedAt = ContinuousClock.now
        while !hasReceivedWarmBuffer {
            if ContinuousClock.now - startedAt >= firstBufferTimeout {
                shutdown(removeRecording: true)
                throw MicrophoneCaptureError.noAudioFlow
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Arms or refreshes the idle warm-microphone deadline. The deadline is
    /// checked from the audio render callback itself rather than a background
    /// Timer/Task, so the 10 s / 30 s / 1 min / 5 min window remains reliable
    /// while the app is backgrounded.
    func setStandbyExpiry(after seconds: TimeInterval) {
        lock.lock()
        standbyGeneration &+= 1
        if recordingFile == nil, seconds > 0 {
            standbyExpiryTimestamp = Date().timeIntervalSince1970 + seconds
        } else {
            standbyExpiryTimestamp = 0
        }
        lock.unlock()
    }

    func clearStandbyExpiry() {
        lock.lock()
        standbyGeneration &+= 1
        standbyExpiryTimestamp = 0
        lock.unlock()
    }

    /// Opens only the file gate on the already-running input engine.
    /// No AudioSession activation, tap install, graph rebuild or engine.start()
    /// occurs on the warm/background path.
    func startRecording(
        firstBufferTimeout: Duration = .milliseconds(650)
    ) async throws -> URL {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        guard isWarmReady,
              let engine,
              engine.isRunning else {
            throw MicrophoneCaptureError.warmStandbyUnavailable
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
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
        standbyGeneration &+= 1
        standbyExpiryTimestamp = 0
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

    /// Ends one capture window but intentionally leaves microphone input hot.
    func finishRecording() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedRecordingBuffer = false
        lock.unlock()
        return url
    }

    /// Cancels one capture window but intentionally leaves microphone input hot.
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

    /// Fully releases microphone input and turns off the privacy indicator.
    func shutdown(removeRecording: Bool = true) {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedWarmBuffer = false
        receivedRecordingBuffer = false
        lastAudioBufferTimestamp = 0
        standbyGeneration &+= 1
        standbyExpiryTimestamp = 0
        lock.unlock()

        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }

            if engine.isRunning {
                engine.stop()
            }

            engine.reset()
        }

        tapInstalled = false
        engine = nil

        if removeRecording, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var hasReceivedWarmBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedWarmBuffer
    }

    /// AVAudioEngine.isRunning can stay true for a zombie input graph after a
    /// route/interruption/suspension event. Treat the warm path as healthy only
    /// if the tap has delivered a real buffer recently.
    private var hasRecentAudioFlow: Bool {
        lock.lock()
        defer { lock.unlock() }

        guard receivedWarmBuffer,
              lastAudioBufferTimestamp > 0 else {
            return false
        }

        return Date().timeIntervalSince1970 - lastAudioBufferTimestamp < 2.5
    }

    private var hasReceivedRecordingBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedRecordingBuffer
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        let now = Date().timeIntervalSince1970
        var expiredGeneration: UInt64?

        lock.lock()
        receivedWarmBuffer = true
        lastAudioBufferTimestamp = now

        if let file = recordingFile {
            receivedRecordingBuffer = true
            try? file.write(from: buffer)
        } else if standbyExpiryTimestamp > 0,
                  now >= standbyExpiryTimestamp {
            standbyExpiryTimestamp = 0
            expiredGeneration = standbyGeneration
        }
        // When recordingFile == nil, the warm tap deliberately discards the
        // buffer. Keeping the tap alive is what preserves background mic IO.
        lock.unlock()

        if let expiredGeneration {
            DispatchQueue.main.async { [weak self] in
                self?.deliverStandbyExpiryIfCurrent(expiredGeneration)
            }
        }
    }

    private func deliverStandbyExpiryIfCurrent(_ generation: UInt64) {
        lock.lock()
        let isCurrent =
            standbyGeneration == generation
            && standbyExpiryTimestamp == 0
            && recordingFile == nil
        lock.unlock()

        guard isCurrent else {
            // A newer keyboard-visible lease, recording, warm-up, or shutdown
            // superseded this callback before the main queue delivered it.
            return
        }

        onStandbyExpired?()
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
            return "The warm microphone session has ended. Open TypeVoice to reactivate it."
        case .noAudioFlow:
            return "The microphone is active but no audio arrived."
        }
    }
}
