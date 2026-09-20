import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var tapInstalled = false
    private var receivedFirstBuffer = false

    var isActive: Bool {
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

    func startRecording(firstBufferTimeout: Duration = .milliseconds(650)) async throws -> URL {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        stopAndDiscard()

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
        receivedFirstBuffer = false
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
            clearRecording(removeFile: true)
            throw error
        }

        let startedAt = ContinuousClock.now
        while !hasReceivedFirstBuffer {
            if ContinuousClock.now - startedAt >= firstBufferTimeout {
                stopAndDiscard()
                throw MicrophoneCaptureError.noAudioFlow
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        return url
    }

    func finishRecording() -> URL? {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        stopEngine()
        return url
    }

    func stopAndDiscard() {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedFirstBuffer = false
        lock.unlock()

        stopEngine()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var hasReceivedFirstBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedFirstBuffer
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        receivedFirstBuffer = true
        let file = recordingFile

        if let file {
            try? file.write(from: buffer)
        }
        lock.unlock()
    }

    private func stopEngine() {
        guard let engine else { return }

        if engine.isRunning {
            engine.stop()
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        engine.reset()
        self.engine = nil
    }

    private func clearRecording(removeFile: Bool) {
        lock.lock()
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        receivedFirstBuffer = false
        lock.unlock()

        if removeFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case alreadyRecording
    case inputUnavailable
    case noAudioFlow

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .inputUnavailable:
            return "The microphone input is unavailable."
        case .noAudioFlow:
            return "The microphone started but no audio arrived."
        }
    }
}
