import AVFoundation
import Foundation

final class AudioStandbyService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var keepAlivePlayer: AVAudioPlayer?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private(set) var isArmed = false

    var onInterrupted: (() -> Void)?

    private var interruptionObserver: NSObjectProtocol?

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
        stopCaptureEngine()
        stopKeepAlive()
    }

    var isRunning: Bool {
        isArmed && engine.isRunning
    }

    var isKeepingAlive: Bool {
        keepAlivePlayer?.isPlaying == true
    }

    var isServiceAlive: Bool {
        isRunning || isKeepingAlive
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

    /// Background standby mode: keep the containing app alive without holding
    /// the microphone open. This mirrors the proven VoiceKey strategy.
    func enterStandby() throws {
        stopCaptureEngine()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try session.setActive(true)

        if keepAlivePlayer == nil {
            let player = try AVAudioPlayer(data: Self.silentWAVData)
            player.numberOfLoops = -1
            player.volume = 1
            player.prepareToPlay()
            keepAlivePlayer = player
        }

        guard keepAlivePlayer?.play() == true else {
            throw AudioServiceError.keepAliveFailed
        }
    }

    /// Activate the microphone when the TypeVoice keyboard is actually visible.
    func armMicrophone() throws {
        if isRunning { return }

        stopKeepAlive()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioServiceError.noInput
        }

        if !tapInstalled {
            input.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: format
            ) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            tapInstalled = true
        }

        engine.prepare()
        try engine.start()
        isArmed = true
    }

    func beginRecording() throws -> URL {
        guard isRunning else {
            throw AudioServiceError.notArmed
        }
        guard !isRecording else {
            throw AudioServiceError.alreadyRecording
        }

        let format = engine.inputNode.inputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typevoice-\(UUID().uuidString.lowercased())")
            .appendingPathExtension("wav")

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )

        lock.lock()
        recordingURL = url
        recordingFile = file
        lock.unlock()

        return url
    }

    func finishRecording(keepMicrophoneActive: Bool = true) -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        if !keepMicrophoneActive {
            try? enterStandby()
        }

        return url
    }

    func cancelRecording(keepMicrophoneActive: Bool = true) {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }

        if !keepMicrophoneActive {
            try? enterStandby()
        }
    }

    func disarm() {
        stopCaptureEngine()
        stopKeepAlive()

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func stopCaptureEngine() {
        lock.lock()
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        if engine.isRunning {
            engine.stop()
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        isArmed = false
    }

    private func stopKeepAlive() {
        keepAlivePlayer?.stop()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = recordingFile
        if let file {
            try? file.write(from: buffer)
        }
        lock.unlock()
    }

    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let seconds: UInt32 = 1
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = sampleRate * UInt32(channels) * bytesPerSample * seconds
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()

    enum AudioServiceError: LocalizedError {
        case noInput
        case notArmed
        case alreadyRecording
        case keepAliveFailed

        var errorDescription: String? {
            switch self {
            case .noInput:
                return "No microphone input is available."
            case .notArmed:
                return "TypeVoice microphone service is not ready."
            case .alreadyRecording:
                return "A recording is already in progress."
            case .keepAliveFailed:
                return "TypeVoice could not keep its background service active."
            }
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
