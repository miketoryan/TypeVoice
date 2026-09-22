import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {


    @Published private(set) var status: TypeVoiceStatus = .idle
    @Published private(set) var isQuickDictationEnabled = SharedStore.quickDictationEnabled
    @Published private(set) var isServiceReady = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String?

    @Published private(set) var isChatGPTLoggedIn = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var chatGPTAccountSummary: String?

    private let audioSessionCoordinator = AudioSessionCoordinator()
    private let microphoneCapture = MicrophoneCapture()
    private let authManager = ChatGPTAuthManager()
    private let localBridge = LocalBridgeServer()
    private let serverID = UUID().uuidString

    private var bridgeRevision: UInt64 = 0
    private var bridgeStatus: BridgeStatus = .idle
    private var bridgeRequestClaimed = false
    private var bridgeFailureKind: BridgeFailureKind?
    private var bridgeRetryAvailable = false
    private var bridgeAudioStage: BridgeAudioStage = .idle
    private var activeRequestID: String?
    private var responseText: String?
    private var resultCreatedAt: Date?
    private var bridgeError: String?

    private var preservedAudioURL: URL?
    private var preservedAudioRequestID: String?

    private var processingTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var recordingStartTask: Task<Bool, Never>?
    private var recordingStartRequestID: String?
    private var foregroundWarmupTask: Task<Bool, Never>?
    private var keyboardIsVisible = false
    private var keyboardHasBeenSeen = false
    private var keyboardExitedAt: Date?
    private var processingBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var darwinObservations: [DarwinObservation] = []

    init() {
        microphoneCapture.onStandbyExpired = { [weak self] in
            self?.expireWarmStandby()
        }

        audioSessionCoordinator.onInterruptionBegan = { [weak self] in
            self?.audioInterruptionBegan()
        }

        audioSessionCoordinator.onInterruptionEnded = { [weak self] in
            guard let self else { return }
            // Microphone input is never restarted from the background. Once an
            // interruption has torn down the warm input graph, the next keyboard
            // activation may foreground TypeVoice and rebuild it there.
            self.markBridgeChanged()
            DarwinBus.post(.serviceChanged)
        }

        audioSessionCoordinator.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let interruptedRequestID = self.activeRequestID
                self.microphoneCapture.shutdown()
                self.audioSessionCoordinator.reset()
                self.endProcessingBackgroundTask()
                self.isServiceReady = false
                self.bridgeAudioStage = .failed
                self.markBridgeChanged()
                DarwinBus.post(.serviceChanged)

                if let interruptedRequestID,
                   (self.bridgeStatus == .recording || self.bridgeStatus == .starting) {
                    self.publishBridgeError(
                        "The iPhone audio service restarted. Tap the microphone to try again.",
                        requestID: interruptedRequestID,
                        kind: .interrupted,
                        retryAvailable: false,
                        claimed: true
                    )
                    self.status = .failed
                } else if self.status == .ready {
                    self.status = .idle
                }
            }
        }

        audioSessionCoordinator.onRouteChanged = { [weak self] in
            self?.markBridgeChanged()
        }

        do {
            try localBridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("TypeVoice is not running.")
                }
                return await self.handleBridgeRequest(request)
            }
        } catch {
            lastError = error.localizedDescription
        }

        configureDarwinCommandObservers()
        refreshAuthState()
    }

    deinit {
        processingTask?.cancel()
        loginTask?.cancel()
        recordingStartTask?.cancel()
        foregroundWarmupTask?.cancel()
        darwinObservations.removeAll()
        localBridge.stop()
    }

    func startChatGPTLogin() {
        guard !isLoggingIn else { return }

        loginTask?.cancel()
        isLoggingIn = true
        lastError = nil

        loginTask = Task { [weak self] in
            guard let self else { return }

            do {
                let tokens = try await authManager.signIn()
                guard !Task.isCancelled else { return }

                isLoggingIn = false
                isChatGPTLoggedIn = true
                chatGPTAccountSummary = Self.accountSummary(tokens)
                lastError = nil

                if bridgeStatus == .error,
                   bridgeFailureKind == .authRequired,
                   let requestID = activeRequestID,
                   preservedAudioRequestID == requestID,
                   let preservedAudioURL,
                   FileManager.default.fileExists(atPath: preservedAudioURL.path) {
                    bridgeFailureKind = .transcriptionRecoverable
                    bridgeRetryAvailable = true
                    bridgeError = "Signed in. Return to the keyboard and retry transcription."
                    markBridgeChanged()
                }
            } catch is CancellationError {
                isLoggingIn = false
            } catch {
                isLoggingIn = false
                lastError = error.localizedDescription
                status = .failed
            }
        }
    }

    func cancelChatGPTLogin() {
        authManager.cancelLogin()
        loginTask?.cancel()
        loginTask = nil
        isLoggingIn = false
    }

    func logoutChatGPT() {
        cancelChatGPTLogin()
        disarm()
        authManager.logout()
        isChatGPTLoggedIn = false
        chatGPTAccountSummary = nil
        lastError = nil
    }

    /// Enables keyboard dictation. Audio resources are still created only when
    /// the keyboard foregrounds TypeVoice for a recording.
    func arm() async {
        guard authManager.isLoggedIn else {
            refreshAuthState()
            lastError = "Sign in with ChatGPT first."
            status = .failed
            return
        }

        do {
            _ = try await authManager.validTokens()
            refreshAuthState()
        } catch {
            lastError = error.localizedDescription
            status = .failed
            return
        }

        let granted = await microphoneCapture.requestPermission()
        guard granted else {
            lastError = "Microphone permission is required."
            status = .failed
            return
        }

        // Jump-first mode keeps no idle AVAudioSession or AVAudioEngine alive.
        // Each new dictation foregrounds TypeVoice once and starts capture there.
        microphoneCapture.shutdown()
        await audioSessionCoordinator.resetAndWait()
        endProcessingBackgroundTask()

        isQuickDictationEnabled = true
        SharedStore.quickDictationEnabled = true
        isServiceReady = false
        keyboardExitedAt = nil
        status = .idle
        resetBridgeToIdle(clearRequest: true)
        bridgeAudioStage = .idle
        lastError = nil
        markBridgeChanged()
        DarwinBus.post(.serviceChanged)
    }

    func disarm() {
        processingTask?.cancel()
        processingTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartRequestID = nil
        foregroundWarmupTask?.cancel()
        foregroundWarmupTask = nil

        microphoneCapture.shutdown()
        audioSessionCoordinator.reset()
        endProcessingBackgroundTask()
        discardPreservedAudio()

        isQuickDictationEnabled = false
        SharedStore.quickDictationEnabled = false
        isServiceReady = false
        keyboardExitedAt = nil
        status = .idle
        resetBridgeToIdle(clearRequest: true)
        markBridgeChanged()
        DarwinBus.post(.serviceChanged)
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "typevoice",
              url.host?.lowercased() == "start-recording" else {
            refreshAuthState()
            return
        }

        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        let queryItems = components?.queryItems ?? []
        let requestID = queryItems.first(where: {
            $0.name == "requestID"
        })?.value
        let returnBundleIdentifier = queryItems.first(where: {
            $0.name == "returnBundleIdentifier"
        })?.value

        guard isQuickDictationEnabled else {
            lastError = "Quick Dictation is disabled. Enable it in TypeVoice first."
            status = .idle
            markBridgeChanged()
            DarwinBus.post(.serviceChanged)
            return
        }

        guard let requestID, !requestID.isEmpty else {
            publishBridgeError(
                "TypeVoice received an invalid keyboard activation request.",
                kind: .bridgeUnavailable,
                retryAvailable: false,
                claimed: false
            )
            return
        }

        // VoiceKing-style foreground fallback: prepare microphone IO in the app,
        // start the actual recording file while still foregrounded, then return.
        // TypeVoice adds one stricter condition: startRecording() must have seen a
        // real microphone buffer before the host app is reopened.
        let audioReady = await ensureForegroundWarmSession(
            requestID: requestID
        )
        guard audioReady else {
            return
        }

        claimRecordingRequest(
            requestID,
            forceAudioRetry: true
        )

        var recordingConfirmed = false
        if recordingStartRequestID == requestID,
           let recordingStartTask {
            let started = await recordingStartTask.value
            recordingConfirmed =
                started
                && bridgeStatus == .recording
                && activeRequestID == requestID
                && microphoneCapture.isRecording
        } else {
            recordingConfirmed =
                bridgeStatus == .recording
                && activeRequestID == requestID
                && microphoneCapture.isRecording
        }

        guard recordingConfirmed else {
            if bridgeStatus != .error {
                publishBridgeError(
                    "TypeVoice could not confirm microphone recording.",
                    requestID: requestID,
                    kind: .audioStartFailed,
                    retryAvailable: false,
                    claimed: true
                )
                status = .failed
            }
            return
        }

        // Same short return delay used by VoiceKing 0.4.1. At this point the
        // recording file is already open and has received a real audio buffer.
        try? await Task.sleep(for: .milliseconds(120))

        if let returnBundleIdentifier,
           !returnBundleIdentifier.isEmpty {
            if !PreviousAppReturner.open(
                bundleID: returnBundleIdentifier
            ) {
                lastError = "iOS blocked automatic return. Return manually."
                markBridgeChanged()
            }
        } else {
            lastError = "Could not identify the previous app. Return manually."
            markBridgeChanged()
        }
    }

    private func ensureForegroundWarmSession(
        requestID: String?
    ) async -> Bool {
        if let foregroundWarmupTask {
            return await foregroundWarmupTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performForegroundWarmSession(
                requestID: requestID
            )
        }

        foregroundWarmupTask = task
        let result = await task.value

        if foregroundWarmupTask != nil {
            foregroundWarmupTask = nil
        }

        return result
    }

    private func performForegroundWarmSession(
        requestID: String?
    ) async -> Bool {
        guard authManager.isLoggedIn else {
            refreshAuthState()
            publishBridgeError(
                "Sign in with ChatGPT first.",
                requestID: requestID,
                kind: .authRequired,
                retryAvailable: false,
                claimed: true
            )
            status = .failed
            return false
        }

        // onOpenURL can arrive during the final inactive -> active transition.
        // Give the same handoff a short chance to settle rather than creating a
        // second pending state machine.
        for _ in 0..<12 {
            if UIApplication.shared.applicationState == .active {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard UIApplication.shared.applicationState == .active else {
            publishBridgeError(
                "TypeVoice is not foreground-active yet.",
                requestID: requestID,
                kind: .audioStartFailed,
                retryAvailable: false,
                claimed: true
            )
            status = .failed
            return false
        }

        let granted = await microphoneCapture.requestPermission()
        guard granted else {
            publishBridgeError(
                "Microphone permission is required.",
                requestID: requestID,
                kind: .audioStartFailed,
                retryAvailable: false,
                claimed: true
            )
            status = .failed
            return false
        }

        microphoneCapture.clearStandbyExpiry()
        microphoneCapture.shutdown()
        isServiceReady = false
        await audioSessionCoordinator.resetAndWait()

        var retry = 0
        var finalError: Error?

        while true {
            guard !Task.isCancelled,
                  UIApplication.shared.applicationState == .active else {
                return false
            }

            do {
                try await audioSessionCoordinator.beginAndReassert(
                    .backgroundKeepAlive
                )
                try await microphoneCapture.warmUp(
                    firstBufferTimeout: .milliseconds(1_800)
                )

                isServiceReady = true
                status = .ready
                bridgeAudioStage = .standbySessionReady
                lastError = nil
                bridgeError = nil
                bridgeFailureKind = nil
                bridgeRetryAvailable = false
                microphoneCapture.clearStandbyExpiry()
                markBridgeChanged()
                DarwinBus.post(.serviceChanged)
                return true
            } catch {
                finalError = error
                microphoneCapture.shutdown()
                isServiceReady = false

                guard Self.isTransientAudioSessionError(error),
                      retry < 4 else {
                    break
                }

                retry += 1
                try? await Task.sleep(
                    for: .milliseconds(150 * retry)
                )
            }
        }

        await audioSessionCoordinator.resetAndWait()

        let message = finalError?.localizedDescription
            ?? "Microphone activation failed."
        publishBridgeError(
            "Foreground microphone recovery failed: \(message)",
            requestID: requestID,
            kind: .audioStartFailed,
            retryAvailable: false,
            claimed: true
        )
        status = .failed
        return false
    }

    private static func isTransientAudioSessionError(
        _ error: Error
    ) -> Bool {
        let code = (error as NSError).code
        return code == 560_557_684 || code == 2_003_329_396
    }

    func appBecameActive() {
        refreshAuthState()
    }

    /// Called when the user changes 10 s / 30 s / 1 min / 5 min in Settings.
    /// The duration is always measured from the actual keyboard-exit timestamp,
    /// not from when this setting changes.
    func updateStandbyDuration() {
        guard isServiceReady,
              !microphoneCapture.isRecording else {
            return
        }
        scheduleMicrophoneStandby()
    }

    private var backgroundWakeReady: Bool {
        guard isServiceReady else { return false }
        return microphoneCapture.isWarmReady
    }

    /// Starts the short microphone warm window after a recording finishes.
    /// 0 seconds means release immediately; otherwise the live input engine keeps
    /// the app responsive for a direct second dictation until this timer expires.
    private func scheduleMicrophoneStandby() {
        guard isServiceReady,
              microphoneCapture.isWarmReady,
              !microphoneCapture.isRecording else {
            return
        }

        let seconds = SharedStore.serviceStandbySeconds
        guard seconds > 0 else {
            expireWarmStandby()
            return
        }

        microphoneCapture.setStandbyExpiry(after: TimeInterval(seconds))
        bridgeAudioStage = .standbySessionReady

        if bridgeStatus == .idle || bridgeStatus == .completed {
            status = .ready
        }

        markBridgeChanged()
        DarwinBus.post(.serviceChanged)
    }

    func appEnteredBackground() {
        // Recording or the explicit short standby input engine owns background
        // execution. Do not create or extend a standby window merely because the
        // app moved to the background.
    }

    private func expireWarmStandby() {
        guard isServiceReady,
              !microphoneCapture.isRecording else {
            return
        }

        microphoneCapture.clearStandbyExpiry()
        microphoneCapture.shutdown(removeRecording: false)
        audioSessionCoordinator.reset()
        isServiceReady = false

        if status == .ready {
            status = .idle
        }

        if bridgeStatus == .idle || bridgeStatus == .completed {
            bridgeAudioStage = .idle
        }

        markBridgeChanged()
        DarwinBus.post(.serviceChanged)
    }

    private func refreshAuthState() {
        isChatGPTLoggedIn = authManager.isLoggedIn
        chatGPTAccountSummary = authManager.storedTokens.map(Self.accountSummary)
    }

    private static func accountSummary(_ tokens: ChatGPTTokens) -> String {
        let email = tokens.email ?? "ChatGPT"
        if let plan = tokens.plan, !plan.isEmpty {
            return "\(email) · \(plan.capitalized)"
        }
        return email
    }

    private func configureDarwinCommandObservers() {
        darwinObservations.removeAll()

        let events: [DarwinEvent] = [
            .pingMainApp,
            .keyboardVisible,
            .keyboardHidden,
            .startRecording,
            .stopRecording,
            .cancelRecording,
            .retryProcessing,
            .acknowledgeResult
        ]

        darwinObservations = events.map { event in
            DarwinBus.observe(event) { [weak self] in
                Task { @MainActor in
                    self?.handleDarwinWake(event)
                }
            }
        }
    }

    /// Darwin is the wake signal; LocalBridge carries the command payload.
    /// Receiving this callback is intentionally cheap so the listener can accept
    /// the HTTP command immediately afterwards.
    private func handleDarwinWake(_ event: DarwinEvent) {
        // Typeless-style liveness probe. Reply before consulting cached service
        // state so the keyboard can distinguish "main app process is alive" from
        // "voice service is ready".
        if event == .pingMainApp {
            DarwinBus.post(.mainAppPong)
            return
        }

        guard isServiceReady else { return }

        // Only current service state decides whether the ACTIVE path is usable.
        // usable. The silent output anchor is a residency aid and can be
        // restarted independently without touching microphone IO.
        if !backgroundWakeReady {
            bridgeAudioStage = .failed
            markBridgeChanged()
        }

        switch event {
        case .keyboardVisible:
            keyboardIsVisible = true
            keyboardHasBeenSeen = true
            keyboardExitedAt = nil

        case .keyboardHidden:
            keyboardIsVisible = false
            keyboardHasBeenSeen = true
            keyboardExitedAt = Date()
            DarwinBus.post(.serviceChanged)

        default:
            break
        }
    }

    private func handleBridgeRequest(_ request: BridgeRequest) async -> BridgeState {
        switch request.action {
        case .state:
            break

        case .startRecording:
            if let requestID = request.requestID {
                claimRecordingRequest(requestID)
            } else {
                publishBridgeError(
                    "TypeVoice received an invalid recording request.",
                    kind: .audioStartFailed,
                    retryAvailable: false,
                    claimed: true
                )
            }

        case .stopRecording:
            await stopRecordingFromKeyboard(expectedRequestID: request.requestID)

        case .cancelRecording:
            await cancelCurrentRequest(expectedRequestID: request.requestID)

        case .retryProcessing:
            retryProcessing(expectedRequestID: request.requestID)

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)
        }

        return currentBridgeState()
    }

    /// Claims immediately so the keyboard knows the containing app is alive
    /// before any AudioSession or AVAudioEngine work begins.
    private func claimRecordingRequest(
        _ requestID: String,
        forceAudioRetry: Bool = false
    ) {
        guard !requestID.isEmpty else { return }

        if activeRequestID == requestID {
            if bridgeStatus == .recording || bridgeStatus == .starting {
                bridgeRequestClaimed = true
                markBridgeChanged()
                return
            }

            if bridgeStatus == .error,
               bridgeFailureKind == .audioStartFailed,
               forceAudioRetry {
                // Reuse the same request ID when foreground fallback retries.
            } else if bridgeStatus == .transcribing
                        || bridgeStatus == .polishing
                        || bridgeStatus == .completed {
                return
            }
        } else {
            processingTask?.cancel()
            processingTask = nil
            recordingStartTask?.cancel()
            recordingStartTask = nil
            recordingStartRequestID = nil
            discardPreservedAudio()
        }

        guard isServiceReady else {
            publishBridgeError(
                "Open TypeVoice and enable Quick Dictation first.",
                requestID: requestID,
                kind: .bridgeUnavailable,
                retryAvailable: false,
                claimed: false
            )
            return
        }

        activeRequestID = requestID
        bridgeStatus = .starting
        bridgeRequestClaimed = true
        bridgeAudioStage = .claimed
        bridgeFailureKind = nil
        bridgeRetryAvailable = false
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        status = .starting
        lastError = nil
        markBridgeChanged()

        recordingStartTask?.cancel()
        recordingStartRequestID = requestID
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            let started = await self.performRecordingStart(requestID: requestID)
            if self.recordingStartRequestID == requestID {
                self.recordingStartRequestID = nil
                self.recordingStartTask = nil
            }
            return started
        }
    }

    private func performRecordingStart(requestID: String) async -> Bool {
        guard activeRequestID == requestID,
              bridgeRequestClaimed else {
            return false
        }

        do {
            guard backgroundWakeReady,
                  microphoneCapture.isWarmReady else {
                throw MicrophoneCaptureError.warmStandbyUnavailable
            }

            microphoneCapture.clearStandbyExpiry()

            try await audioSessionCoordinator.beginAndWait(.capture)
            bridgeAudioStage = .captureSessionReady
            markBridgeChanged()

            // The app is foreground-active here; create microphone IO now.
            bridgeAudioStage = .startingInput
            markBridgeChanged()
            _ = try await microphoneCapture.startRecording()
            bridgeAudioStage = .firstBuffer
            markBridgeChanged()

            guard activeRequestID == requestID,
                  !Task.isCancelled else {
                microphoneCapture.discardRecording()
                try? await audioSessionCoordinator.endAndWait(.capture)
                scheduleMicrophoneStandby()
                return false
            }

            bridgeStatus = .recording
            bridgeRequestClaimed = true
            bridgeAudioStage = .recording
            bridgeFailureKind = nil
            bridgeRetryAvailable = false
            status = .recording
            lastError = nil
            bridgeError = nil
            markBridgeChanged()
            return true
        } catch is CancellationError {
            return false
        } catch {
            microphoneCapture.discardRecording()
            try? await audioSessionCoordinator.endAndWait(.capture)
            if backgroundWakeReady {
                scheduleMicrophoneStandby()
            }

            guard activeRequestID == requestID else { return false }

            publishBridgeError(
                error.localizedDescription,
                requestID: requestID,
                kind: .audioStartFailed,
                retryAvailable: false,
                claimed: true
            )
            status = .failed
            return false
        }
    }

    private func stopRecordingFromKeyboard(expectedRequestID: String?) async {
        guard bridgeStatus == .recording else { return }

        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else {
            return
        }

        // Capture itself keeps the app alive while speaking. Once it ends, use
        // a finite UIKit background task only for transcription and cleanup.
        beginProcessingBackgroundTask()
        bridgeAudioStage = .returningToStandby
        markBridgeChanged()

        guard let fileURL = microphoneCapture.finishRecording() else {
            endProcessingBackgroundTask()
            publishBridgeError(
                "Recording file was not available.",
                requestID: requestID,
                kind: .transcriptionPermanent,
                retryAvailable: false,
                claimed: true
            )
            status = .failed
            return
        }

        try? await audioSessionCoordinator.endAndWait(.capture)
        scheduleMicrophoneStandby()

        discardPreservedAudio()
        preservedAudioURL = fileURL
        preservedAudioRequestID = requestID

        bridgeAudioStage = .transcribing
        beginProcessing(fileURL: fileURL, requestID: requestID)
    }

    private func beginProcessing(fileURL: URL, requestID: String) {
        beginProcessingBackgroundTask()
        bridgeStatus = .transcribing
        bridgeRequestClaimed = true
        bridgeAudioStage = .transcribing
        bridgeFailureKind = nil
        bridgeRetryAvailable = false
        status = .transcribing
        bridgeError = nil
        resultCreatedAt = nil
        markBridgeChanged()

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.process(fileURL: fileURL, requestID: requestID)
        }
    }

    private func retryProcessing(expectedRequestID: String?) {
        guard bridgeStatus == .error,
              bridgeRetryAvailable,
              bridgeFailureKind == .transcriptionRecoverable,
              let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID,
              preservedAudioRequestID == requestID,
              let fileURL = preservedAudioURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return
        }

        beginProcessing(fileURL: fileURL, requestID: requestID)
    }

    private func cancelCurrentRequest(expectedRequestID: String?) async {
        guard expectedRequestID == nil || expectedRequestID == activeRequestID else {
            return
        }

        // Invalidate the request before awaiting anything. Any late network or
        // audio result for the old ID is ignored by the request-ID guards.
        activeRequestID = nil
        bridgeRequestClaimed = false

        processingTask?.cancel()
        processingTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartRequestID = nil

        let hadCapture =
            microphoneCapture.isActive
            || bridgeStatus == .recording
            || bridgeStatus == .starting

        if hadCapture {
            microphoneCapture.discardRecording()
            try? await audioSessionCoordinator.endAndWait(.capture)
        }

        discardPreservedAudio()
        endProcessingBackgroundTask()

        if backgroundWakeReady {
            scheduleMicrophoneStandby()
        } else {
            microphoneCapture.shutdown(removeRecording: false)
            audioSessionCoordinator.reset()
            isServiceReady = false
        }

        resetBridgeToIdle(clearRequest: false)
        bridgeAudioStage = isServiceReady ? .standbySessionReady : .idle
        status = isServiceReady ? .ready : .idle
        lastError = nil
        markBridgeChanged()
    }

    private func audioInterruptionBegan() {
        guard isServiceReady else { return }

        let interruptedRequestID = activeRequestID
        let hadCapture =
            microphoneCapture.isActive
            || bridgeStatus == .recording
            || bridgeStatus == .starting

        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartRequestID = nil
        microphoneCapture.clearStandbyExpiry()

        // Once iOS tears down microphone IO we deliberately do not restart it
        // from the background. Mark the warm service cold; the next keyboard
        // activation may foreground TypeVoice and warm it again.
        microphoneCapture.shutdown()
        audioSessionCoordinator.reset()
        endProcessingBackgroundTask()
        isServiceReady = false

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.bridgeAudioStage = .failed
            DarwinBus.post(.serviceChanged)

            if hadCapture,
               let interruptedRequestID,
               self.activeRequestID == interruptedRequestID {
                self.publishBridgeError(
                    "Microphone session was interrupted.",
                    requestID: interruptedRequestID,
                    kind: .interrupted,
                    retryAvailable: false,
                    claimed: true
                )
                self.status = .failed
            } else {
                if self.status == .ready {
                    self.status = .idle
                }
                self.markBridgeChanged()
            }
        }
    }

    private func process(fileURL: URL, requestID: String) async {
        do {
            var tokens = try await authManager.validTokens()
            var client = makeClient(tokens)

            let raw: String
            do {
                raw = try await client.transcribe(fileURL: fileURL)
            } catch let error as ChatGPTClientError where error.isUnauthorized {
                tokens = try await authManager.validTokens(forceRefresh: true)
                client = makeClient(tokens)
                raw = try await client.transcribe(fileURL: fileURL)
            }

            guard !Task.isCancelled,
                  activeRequestID == requestID else {
                return
            }

            lastTranscript = raw

            let finalText: String
            if SharedStore.cleanupEnabled {
                bridgeStatus = .polishing
                bridgeAudioStage = .polishing
                bridgeFailureKind = nil
                bridgeRetryAvailable = false
                status = .polishing
                markBridgeChanged()

                do {
                    finalText = try await client.cleanup(raw)
                } catch {
                    guard !Task.isCancelled,
                          activeRequestID == requestID else {
                        return
                    }

                    // Cleanup is optional. Recognition already succeeded, so do not
                    // strand the user if the cleanup request itself fails.
                    finalText = raw
                    lastError = "Cleanup failed; raw transcript will be inserted. \(error.localizedDescription)"
                }
            } else {
                // VoiceKing-style raw transcription path: no second model call.
                finalText = raw
            }

            guard !Task.isCancelled,
                  activeRequestID == requestID else {
                return
            }

            responseText = finalText
            resultCreatedAt = Date()
            bridgeError = nil
            bridgeFailureKind = nil
            bridgeRetryAvailable = false
            bridgeRequestClaimed = true
            bridgeStatus = .completed
            bridgeAudioStage = isServiceReady ? .standbySessionReady : .idle
            status = isServiceReady ? .ready : .idle
            lastTranscript = finalText
            refreshAuthState()
            deletePreservedAudio(ifMatches: requestID)
            markBridgeChanged()
            endProcessingBackgroundTask()
        } catch is CancellationError {
            endProcessingBackgroundTask()
            return
        } catch {
            guard !Task.isCancelled,
                  activeRequestID == requestID else {
                return
            }

            if error is ChatGPTAuthError {
                isChatGPTLoggedIn = false
                chatGPTAccountSummary = nil
                publishBridgeError(
                    error.localizedDescription,
                    requestID: requestID,
                    kind: .authRequired,
                    retryAvailable: false,
                    claimed: true
                )
                status = .failed
                endProcessingBackgroundTask()
                return
            }

            let classification = classifyTranscriptionError(error)

            if classification.kind == .transcriptionPermanent {
                deletePreservedAudio(ifMatches: requestID)
            }

            publishBridgeError(
                error.localizedDescription,
                requestID: requestID,
                kind: classification.kind,
                retryAvailable: classification.retryAvailable,
                claimed: true
            )
            status = .failed
            endProcessingBackgroundTask()
        }
    }

    private func classifyTranscriptionError(
        _ error: Error
    ) -> (kind: BridgeFailureKind, retryAvailable: Bool) {
        if let clientError = error as? ChatGPTClientError {
            switch clientError {
            case .emptyTranscription, .invalidURL:
                return (.transcriptionPermanent, false)

            case .server(let statusCode, _):
                if statusCode == 401 {
                    return (.authRequired, false)
                }

                if statusCode == 408
                    || statusCode == 409
                    || statusCode == 425
                    || statusCode == 429
                    || statusCode >= 500 {
                    return (.transcriptionRecoverable, true)
                }

                return (.transcriptionPermanent, false)

            case .invalidResponse, .missingOutputText:
                return (.transcriptionRecoverable, true)
            }
        }

        if error is URLError {
            return (.transcriptionRecoverable, true)
        }

        return (.transcriptionRecoverable, true)
    }

    private func makeClient(_ tokens: ChatGPTTokens) -> ChatGPTClient {
        ChatGPTClient(
            accessToken: tokens.accessToken,
            accountID: tokens.accountID,
            cleanupModel: SharedStore.cleanupModel
        )
    }

    private func acknowledgeResult(requestID: String?) {
        guard requestID == nil || requestID == activeRequestID else { return }

        deletePreservedAudio(ifMatches: activeRequestID)
        endProcessingBackgroundTask()
        resetBridgeToIdle(clearRequest: true)
        bridgeAudioStage = isServiceReady ? .standbySessionReady : .idle
        status = isServiceReady ? .ready : .idle
        markBridgeChanged()
    }

    private func beginProcessingBackgroundTask() {
        guard processingBackgroundTask == .invalid else { return }

        processingBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "TypeVoice.Transcription"
        ) { [weak self] in
            Task { @MainActor in
                self?.endProcessingBackgroundTask()
            }
        }
    }

    private func endProcessingBackgroundTask() {
        guard processingBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(processingBackgroundTask)
        processingBackgroundTask = .invalid
    }

    private func publishBridgeError(
        _ message: String,
        requestID: String? = nil,
        kind: BridgeFailureKind,
        retryAvailable: Bool,
        claimed: Bool
    ) {
        if let requestID {
            activeRequestID = requestID
        }

        let stageAtFailure = bridgeAudioStage
        let surfacedMessage: String
        if kind == .audioStartFailed || kind == .bridgeUnavailable {
            surfacedMessage = "\(message) [audio: \(stageAtFailure.rawValue)]"
        } else {
            surfacedMessage = message
        }

        responseText = nil
        resultCreatedAt = Date()
        bridgeError = surfacedMessage
        bridgeStatus = .error
        bridgeFailureKind = kind
        bridgeRetryAvailable = retryAvailable
        bridgeRequestClaimed = claimed
        bridgeAudioStage = .failed
        lastError = surfacedMessage
        markBridgeChanged()
    }

    private func resetBridgeToIdle(clearRequest: Bool) {
        bridgeStatus = .idle
        bridgeRequestClaimed = false
        bridgeAudioStage = .idle
        bridgeFailureKind = nil
        bridgeRetryAvailable = false
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil

        if clearRequest {
            activeRequestID = nil
        }
    }

    private func discardPreservedAudio() {
        if let preservedAudioURL {
            try? FileManager.default.removeItem(at: preservedAudioURL)
        }
        preservedAudioURL = nil
        preservedAudioRequestID = nil
    }

    private func deletePreservedAudio(ifMatches requestID: String?) {
        guard let requestID,
              preservedAudioRequestID == requestID else {
            return
        }
        discardPreservedAudio()
    }

    private func currentBridgeState() -> BridgeState {
        BridgeState(
            serverID: serverID,
            revision: bridgeRevision,
            serviceReady: isServiceReady,
            quickDictationEnabled: isQuickDictationEnabled,
            backgroundWakeReady: backgroundWakeReady,
            microphoneReady: microphoneCapture.isWarmReady,
            requestClaimed: bridgeRequestClaimed,
            audioStage: bridgeAudioStage,
            status: bridgeStatus,
            failureKind: bridgeFailureKind,
            retryAvailable: bridgeRetryAvailable,
            requestID: activeRequestID,
            transcribedText: responseText,
            resultCreatedAt: resultCreatedAt,
            lastError: bridgeError,
            interfaceLanguage: SharedStore.interfaceLanguage.rawValue
        )
    }

    private func markBridgeChanged() {
        bridgeRevision &+= 1
        DarwinBus.post(.statusChanged)

        if bridgeStatus == .completed {
            DarwinBus.post(.resultReady)
        }
    }
}
