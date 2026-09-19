import AVFoundation
import Foundation

final class AudioStandbyService {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var lastHeartbeat: TimeInterval = 0
    private var expiryTimestamp: TimeInterval = 0
    private var interruptionObserver: NSObjectProtocol?

    var onExpired: (() -> Void)?
    var onInterrupted: (() -> Void)?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw),
                type == .began
            else { return }
            self?.onInterrupted?()
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    var isRunning: Bool {
        engine.isRunning
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordingFile != nil
    }

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func arm(until expiry: Date) throws {
        expiryTimestamp = expiry.timeIntervalSince1970

        if engine.isRunning {
            SharedStore.touchServiceHeartbeat()
            return
        }

        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]
        options.insert(.allowBluetooth)
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioServiceError.noInput
        }

        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                self?.handleAudio(buffer)
            }
            tapInstalled = true
        }

        engine.prepare()
        try engine.start()
        SharedStore.touchServiceHeartbeat()
    }

    func beginRecording() throws -> URL {
        guard engine.isRunning else { throw AudioServiceError.notArmed }
        guard !isRecording else { throw AudioServiceError.alreadyRecording }

        let format = engine.inputNode.outputFormat(forBus: 0)
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
        lock.unlock()

        return url
    }

    func finishRecording(keepWarm: Bool = true) -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        if !keepWarm {
            disarm()
        }
        return url
    }

    func cancelRecording(keepWarm: Bool = true) {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        if !keepWarm {
            disarm()
        }
    }

    func disarm() {
        lock.lock()
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        if engine.isRunning {
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        SharedStore.clearServiceReady()
    }

    private func handleAudio(_ buffer: AVAudioPCMBuffer) {
        let now = Date().timeIntervalSince1970

        if now - lastHeartbeat >= 1 {
            lastHeartbeat = now
            SharedStore.touchServiceHeartbeat(Date(timeIntervalSince1970: now))
        }

        lock.lock()
        let file = recordingFile
        let currentlyRecording = recordingFile != nil
        lock.unlock()

        if let file {
            do {
                try file.write(from: buffer)
            } catch {
                // The coordinator will surface an error if the resulting file is unusable.
            }
        }

        if !currentlyRecording, expiryTimestamp > 0, now >= expiryTimestamp {
            expiryTimestamp = 0
            DispatchQueue.main.async { [weak self] in
                self?.onExpired?()
            }
        }
    }
}

enum AudioServiceError: LocalizedError {
    case noInput
    case notArmed
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "No microphone input is available."
        case .notArmed:
            return "The background recording service is not ready."
        case .alreadyRecording:
            return "A recording is already in progress."
        }
    }
}
