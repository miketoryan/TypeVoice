import AVFoundation
import Foundation

@MainActor
final class BackgroundExecutionAnchor {
    private var player: AVAudioPlayer?

    var isRunning: Bool {
        player?.isPlaying == true
    }

    func start() throws {
        if player?.isPlaying == true {
            return
        }

        let newPlayer: AVAudioPlayer
        if let player {
            newPlayer = player
        } else {
            newPlayer = try AVAudioPlayer(data: Self.silentWAVData)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = 1
            newPlayer.prepareToPlay()
            player = newPlayer
        }

        guard newPlayer.play() else {
            throw BackgroundAnchorError.couldNotStart
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let seconds: UInt32 = 1

        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = sampleRate * seconds * UInt32(channels) * bytesPerSample
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = channels * UInt16(bytesPerSample)

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

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
        data.append(Data(repeating: 0, count: Int(dataSize)))

        return data
    }()
}

enum BackgroundAnchorError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        "TypeVoice could not keep its background service ready."
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
