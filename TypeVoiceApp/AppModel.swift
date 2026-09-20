import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: TypeVoiceStatus = .idle
    @Published private(set) var isServiceReady = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String?

    @Published private(set) var isChatGPTLoggedIn = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var chatGPTAccountSummary: String?

    private let audioSessionCoordinator = AudioSessionCoordinator()
    private let backgroundAnchor = BackgroundExecutionAnchor()
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
    private var standbyExpiryTask: Task<Void, Never>?
    private var darwinObservations: [DarwinObservation] = []

    init() {
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
                self.standbyExpiryTask?.cancel()
                self.standbyExpiryTask = nil
                self.microphoneCapture.shutdown()
                self.backgroundAnchor.stop()
                self.audioSessionCoordinator.reset()
                self.isServiceReady = false
                self.bridgeAudioStage = .failed
                self.markBridgeChanged()
                DarwinBus.post(.serviceChanged)

                if let interruptedRequestID,
                   self.bridgeStatus == .recording || self.bridgeStatus == .starting {
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
        standbyExpiryTask?.cancel()
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

    /// Arms a time-limited warm microphone session.
    ///
    /// The input AVAudioEngine and its tap are started once while TypeVoice is
    /// foregrounded. During standby the tap keeps receiving buffers and discards
    /// them. A separate silent output anchor protects background residency.
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

        do {
            try await audioSessionCoordinator.beginAndWait(.backgroundKeepAlive)
            try await microphoneCapture.warmUp()
            try backgroundAnchor.start()

            isServiceReady = true
            status = .ready
            resetBridgeToIdle(clearRequest: true)
            bridgeAudioStage = .standbySessionReady
            lastError = nil
            scheduleStandbyExpiry()
            markBridgeChanged()
            DarwinBus.post(.serviceChanged)
        } catch {
            standbyExpiryTask?.cancel()
            standbyExpiryTask = nil
            microphoneCapture.shutdown()
            backgroundAnchor.stop()
            audioSessionCoordinator.reset()
            publishBridgeError(
                error.localizedDescription,
                kind: .bridgeUnavailable,
                retryAvailable: false,
                claimed: false
            )
            status = .failed
        }
    }

    func disarm() {
        processingTask?.cancel()
        processingTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartRequestID = nil
        standbyExpiryTask?.cancel()
        standbyExpiryTask = nil

        microphoneCapture.shutdown()
        backgroundAnchor.stop()
        audioSessionCoordinator.reset()
        discardPreservedAudio()

        isServiceReady = false
        status = .idle
        resetBridgeToIdle(clearRequest: true)
        markBridgeChanged()
        DarwinBus.post(.serviceChanged)
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "typevoice" else { return }
        guard url.host?.lowercased() == "prepare" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let source = components?.queryItems?
            .first(where: { $0.name == "source" })?.value
        let requestedHostBundleID = components?.queryItems?
            .first(where: { $0.name == "host" })?.value
        let requestedRecordingID = components?.queryItems?
            .first(where: { $0.name == "request" })?.value
        let shouldAutoStart = components?.queryItems?
            .first(where: { $0.name == "autostart" })?.value == "1"
        let cameFromKeyboard = source == "keyboard"

        Task {
            if !isServiceReady {
                await arm()
            } else if !backgroundWakeReady {
                do {
                    // This path runs because the keyboard has foregrounded
                    // TypeVoice. Rebuilding microphone input is therefore legal.
                    try await audioSessionCoordinator.reassertCurrentProfile()
                    try await microphoneCapture.warmUp()
                    try backgroundAnchor.start()
                    scheduleStandbyExpiry()
                    bridgeAudioStage = .standbySessionReady
                    lastError = nil
                    markBridgeChanged()
                } catch {
                    publishBridgeError(
                        error.localizedDescription,
                        requestID: requestedRecordingID,
                        kind: .audioStartFailed,
                        retryAvailable: false,
                        claimed: true
                    )
                    status = .failed
                    return
                }
            }

            guard cameFromKeyboard, isServiceReady else { return }

            if shouldAutoStart,
               let requestedRecordingID,
               !requestedRecordingID.isEmpty {
                claimRecordingRequest(
                    requestedRecordingID,
                    forceAudioRetry: true
                )

                let started: Bool
                if bridgeStatus == .recording,
                   activeRequestID == requestedRecordingID {
                    started = true
                } else if recordingStartRequestID == requestedRecordingID,
                          let recordingStartTask {
                    started = await recordingStartTask.value
                } else {
                    started = false
                }

                guard started,
                      bridgeStatus == .recording,
                      activeRequestID == requestedRecordingID else {
                    return
                }
            }

            try? await Task.sleep(for: .milliseconds(220))

            guard let requestedHostBundleID,
                  !requestedHostBundleID.isEmpty else {
                return
            }

            _ = PreviousAppReturner.open(bundleID: requestedHostBundleID)
        }
    }

    func appBecameActive() {
        refreshAuthState()

        guard isServiceReady, !backgroundWakeReady else { return }

        Task {
            do {
                try await audioSessionCoordinator.reassertCurrentProfile()
                try await microphoneCapture.warmUp()
                try backgroundAnchor.start()
                scheduleStandbyExpiry()
                bridgeAudioStage = .standbySessionReady
                lastError = nil
                markBridgeChanged()
            } catch {
                bridgeAudioStage = .failed
                lastError = error.localizedDescription
                markBridgeChanged()
            }
        }
    }

    /// Called when the user changes 10 s / 30 s / 1 min / 5 min in Settings.
    /// An already-warm idle session adopts the new duration starting now.
    func updateStandbyDuration() {
        guard isServiceReady,
              bridgeStatus != .recording,
              bridgeStatus != .starting else {
            return
        }
        scheduleStandbyExpiry()
    }

    private var backgroundWakeReady: Bool {
        guard isServiceReady else { return false }
        return microphoneCapture.isWarmReady && backgroundAnchor.isRunning
    }

    private func scheduleStandbyExpiry() {
        standbyExpiryTask?.cancel()
        standbyExpiryTask = nil

        guard isServiceReady,
              bridgeStatus != .recording,
              bridgeStatus != .starting else {
            return
        }

        let seconds = max(10, SharedStore.quickStandbySeconds)
        standbyExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }

            guard let self,
                  self.isServiceReady,
                  self.bridgeStatus != .recording,
                  self.bridgeStatus != .starting else {
                return
            }

            self.expireWarmStandby()
        }
    }

    /// Releases only the warm audio resources. Ongoing transcription/result
    /// delivery is left intact, so a short standby choice never loses text.
    private func expireWarmStandby() {
        standbyExpiryTask?.cancel()
        standbyExpiryTask = nil

        microphoneCapture.shutdown(removeRecording: false)
        backgroundAnchor.stop()
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
            .heartbeat,
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
        guard isServiceReady else { return }

        // The warm path is valid only while BOTH the foreground-started input
        // engine and the separate silent output anchor are still alive. Darwin
        // never attempts to restart microphone input from the background.
        if !backgroundWakeReady {
            bridgeAudioStage = .failed
            markBridgeChanged()
        }

        if event == .heartbeat {
            DarwinBus.post(.serviceChanged)
        }
    }

    private func handleBridgeRequest(_ request: BridgeRequest) async -> BridgeState {
        switch request.action {
        case .state:
            break

        case .heartbeat:
            // Heartbeat reports the already-warm input graph. It never rebuilds
            // microphone input from the background.
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

            standbyExpiryTask?.cancel()
            standbyExpiryTask = nil

            try await audioSessionCoordinator.beginAndWait(.capture)
            bridgeAudioStage = .captureSessionReady
            markBridgeChanged()

            // Hot path: the input tap and engine are already running. Starting a
            // dictation only opens the file gate; no audio IO is started here.
            bridgeAudioStage = .startingInput
            markBridgeChanged()
            _ = try await microphoneCapture.startRecording()
            bridgeAudioStage = .firstBuffer
            markBridgeChanged()

            guard activeRequestID == requestID,
                  !Task.isCancelled else {
                microphoneCapture.discardRecording()
                try? await audioSessionCoordinator.endAndWait(.capture)
                scheduleStandbyExpiry()
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
                scheduleStandbyExpiry()
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

        // Close only the recording file gate. The persistent input tap stays
        // alive and idle buffers are discarded during the configured ready window.
        bridgeAudioStage = .returningToStandby
        markBridgeChanged()

        guard let fileURL = microphoneCapture.finishRecording() else {
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
        scheduleStandbyExpiry()

        discardPreservedAudio()
        preservedAudioURL = fileURL
        preservedAudioRequestID = requestID

        bridgeAudioStage = .transcribing
        beginProcessing(fileURL: fileURL, requestID: requestID)
    }

    private func beginProcessing(fileURL: URL, requestID: String) {
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

        if backgroundWakeReady {
            scheduleStandbyExpiry()
        }

        discardPreservedAudio()

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
        standbyExpiryTask?.cancel()
        standbyExpiryTask = nil

        // Once iOS tears down microphone IO we deliberately do not restart it
        // from the background. Mark the warm service cold; the next keyboard
        // activation may foreground TypeVoice and warm it again.
        microphoneCapture.shutdown()
        backgroundAnchor.stop()
        audioSessionCoordinator.reset()
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
            bridgeStatus = .polishing
            bridgeAudioStage = .polishing
            bridgeFailureKind = nil
            bridgeRetryAvailable = false
            status = .polishing
            markBridgeChanged()

            let finalText: String
            do {
                finalText = try await client.cleanup(raw)
            } catch {
                guard !Task.isCancelled,
                      activeRequestID == requestID else {
                    return
                }

                // Cleanup is optional. Recognition already succeeded, so do not
                // strand the user in an error state if style cleanup fails.
                finalText = raw
                lastError = "Cleanup failed; raw transcript will be inserted. \(error.localizedDescription)"
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
        } catch is CancellationError {
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
        resetBridgeToIdle(clearRequest: true)
        status = isServiceReady ? .ready : .idle
        markBridgeChanged()
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
