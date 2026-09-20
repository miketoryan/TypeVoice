import Foundation

enum DarwinEvent: String {
    // Keyboard -> containing app. These notifications are intentionally
    // payload-free wake signals. Request data still travels through LocalBridge,
    // because TypeVoice's AltServer/free-signing path cannot rely on App Groups.
    case heartbeat = "com.miketoryan.typevoice.heartbeat"
    case keyboardVisible = "com.miketoryan.typevoice.keyboardVisible"
    case keyboardHidden = "com.miketoryan.typevoice.keyboardHidden"
    case startRecording = "com.miketoryan.typevoice.startRecording"
    case stopRecording = "com.miketoryan.typevoice.stopRecording"
    case cancelRecording = "com.miketoryan.typevoice.cancelRecording"
    case retryProcessing = "com.miketoryan.typevoice.retryProcessing"
    case acknowledgeResult = "com.miketoryan.typevoice.acknowledgeResult"

    // Containing app -> keyboard. The keyboard still reads the authoritative
    // BridgeState from LocalBridge after receiving one of these lightweight
    // cross-process nudges.
    case statusChanged = "com.miketoryan.typevoice.statusChanged"
    case resultReady = "com.miketoryan.typevoice.resultReady"
    case serviceChanged = "com.miketoryan.typevoice.serviceChanged"
}

final class DarwinObservation {
    private let event: DarwinEvent
    fileprivate let handler: () -> Void

    init(event: DarwinEvent, handler: @escaping () -> Void) {
        self.event = event
        self.handler = handler

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            typeVoiceDarwinCallback,
            event.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(event.rawValue as CFString),
            nil
        )
    }
}

private let typeVoiceDarwinCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let observation = Unmanaged<DarwinObservation>.fromOpaque(observer).takeUnretainedValue()
    observation.handler()
}

enum DarwinBus {
    static func post(_ event: DarwinEvent) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(event.rawValue as CFString),
            nil,
            nil,
            true
        )
    }

    static func observe(
        _ event: DarwinEvent,
        handler: @escaping () -> Void
    ) -> DarwinObservation {
        DarwinObservation(event: event, handler: handler)
    }
}
