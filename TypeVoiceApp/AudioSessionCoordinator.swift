import AVFoundation
import Foundation

@MainActor
final class AudioSessionCoordinator {
    enum Intent: Int, Hashable {
        case backgroundKeepAlive = 0
        case capture = 1
    }

    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    var onRouteChanged: (() -> Void)?

    private var activeIntents = Set<Intent>()
    private var sessionIsActive = false
    private var observers: [NSObjectProtocol] = []

    private static let sessionQueue = DispatchQueue(
        label: "com.miketoryan.TypeVoice.AudioSession"
    )

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else {
                    return
                }

                Task { @MainActor in
                    guard let self else { return }

                    switch type {
                    case .began:
                        self.sessionIsActive = false
                        self.onInterruptionBegan?()

                    case .ended:
                        self.sessionIsActive = false
                        self.onInterruptionEnded?()

                    @unknown default:
                        break
                    }
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.sessionIsActive = false
                    self.onMediaServicesReset?()
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onRouteChanged?()
                }
            }
        )
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func beginAndWait(_ intent: Intent) async throws {
        activeIntents.insert(intent)
        try await applyHighestIntent()
    }

    func endAndWait(_ intent: Intent) async throws {
        activeIntents.remove(intent)
        try await applyHighestIntent()
    }

    func reassertCurrentProfile() async throws {
        sessionIsActive = false
        try await applyHighestIntent(force: true)
    }

    func reset() {
        activeIntents.removeAll()
        sessionIsActive = false

        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    var hasBackgroundIntent: Bool {
        activeIntents.contains(.backgroundKeepAlive)
    }

    var hasCaptureIntent: Bool {
        activeIntents.contains(.capture)
    }

    private var highestIntent: Intent? {
        activeIntents.max(by: { $0.rawValue < $1.rawValue })
    }

    private func profile(
        for intent: Intent
    ) -> (
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) {
        switch intent {
        case .backgroundKeepAlive:
            return (
                .playback,
                .default,
                [.mixWithOthers]
            )

        case .capture:
            return (
                .playAndRecord,
                .default,
                [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
            )
        }
    }

    private func applyHighestIntent(force: Bool = false) async throws {
        guard let intent = highestIntent else {
            if sessionIsActive || force {
                try await performSessionMutation {
                    try AVAudioSession.sharedInstance().setActive(
                        false,
                        options: .notifyOthersOnDeactivation
                    )
                }
            }
            sessionIsActive = false
            return
        }

        let target = profile(for: intent)
        let session = AVAudioSession.sharedInstance()

        let needsReconfiguration =
            session.category != target.category
            || session.mode != target.mode
            || session.categoryOptions != target.options

        if !force, sessionIsActive, !needsReconfiguration {
            return
        }

        try await performSessionMutation {
            if needsReconfiguration || force {
                try session.setCategory(
                    target.category,
                    mode: target.mode,
                    options: target.options
                )
            }

            if intent == .capture {
                try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            }

            try session.setActive(true)
        }

        sessionIsActive = true
    }

    private func performSessionMutation(
        _ mutation: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.sessionQueue.async {
                do {
                    try mutation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
