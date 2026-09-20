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
    private var backgroundRestoreTask: Task<Bool, Never>?
    private var darwinObservations: [DarwinObservation] = []

    init() {
        audioSessionCoordinator.onInterruptionBegan = { [weak self] in
            self?.audioInterruptionBegan()
        }

        audioSessionCoordinator.onInterruptionEnded = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                _ = await self.restoreBackgroundExecution()
            }
        }

        audioSessionCoordinator.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let interruptedRequestID = self.activeRequestID
                self.microphoneCapture.shutdown()
                try? await self.audioSessionCoordinator.endAndWait(.capture)
                _ = await self.restoreBackgroundExecution(forceReassert: true)
                self.bridgeAudioStage = .failed
                self.markBridgeChanged()

                if let interruptedRequestID {
                    self.publishBridgeError(
                        "The iPhone audio service restarted. Tap the microphone to try again.",
                        requestID: interruptedRequestID,
                        kind: .interrupted,
                        retryAvailable: false,
                        claimed: true
                    )
                    self.status = .failed
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
        backgroundRestoreTask?.cancel()
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

    /// Arms background execution only. The microphone stays completely off
    /// until a keyboard request is actually claimed and capture starts.
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

            // Build and validate the input graph in foreground, then PAUSE it.
            // Silent playback keeps the app executing while microphone hardware
            // is expected to be idle.
            try await microphoneCapture.preparePausedStandby()
            try backgroundAnchor.start()

            isServiceReady = true
            status = .ready
            resetBridgeToIdle(clearRequest: true)
            bridgeAudioStage = .standbySessionReady
            lastError = nil
            markBridgeChanged()
            DarwinBus.post(.serviceChanged)
        } catch {
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
        backgroundRestoreTask?.cancel()
        backgroundRestoreTask = nil

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
            } else if !microphoneCapture.isPreparedForResume
                        || !backgroundAnchor.isRunning {
                do {
                    try await audioSessionCoordinator.reassertCurrentProfile()
                    try await microphoneCapture.preparePausedStandby()
                    try backgroundAnchor.start()
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

        guard isServiceReady, !microphoneCapture.isActive else { return }

        Task {
            do {
                try await audioSessionCoordinator.reassertCurrentProfile()
                try await microphoneCapture.preparePausedStandby()
                try backgroundAnchor.start()
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

    private var backgroundWakeReady: Bool {
        guard isServiceReady else { return false }

        if microphoneCapture.isActive {
            return true
        }

        return microphoneCapture.isPreparedForResume
            && backgroundAnchor.isRunning
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

        // Paused-engine experiment: Darwin may wake the process, but it must
        // never rebuild the graph. Warm readiness requires both the prepared
        // paused graph and the playback anchor that keeps background execution.
        if !microphoneCapture.isPreparedForResume
            || (!microphoneCapture.isActive && !backgroundAnchor.isRunning) {
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
            // Readiness is the prepared paused graph + background anchor. A
            // heartbeat may report that state but never rebuilds the graph.
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
            guard microphoneCapture.isPreparedForResume,
                  backgroundAnchor.isRunning else {
                throw MicrophoneCaptureError.warmStandbyUnavailable
            }

            try await audioSessionCoordinator.beginAndWait(.capture)
            bridgeAudioStage = .captureSessionReady
            markBridgeChanged()

            // Resume the SAME prepared graph from pause. No graph rebuild,
            // no tap install and no AudioSession category change happens here.
            bridgeAudioStage = .startingInput
            markBridgeChanged()
            _ = try await microphoneCapture.startRecording()
            bridgeAudioStage = .firstBuffer
            markBridgeChanged()

            guard activeRequestID == requestID,
                  !Task.isCancelled else {
                microphoneCapture.discardRecordingAndPause()
                try? await audioSessionCoordinator.endAndWait(.capture)
                try? backgroundAnchor.start()
                return false
            }

            // Once real input buffers are flowing, capture itself keeps the app
            // active; the silent playback anchor is no longer needed.
            backgroundAnchor.stop()

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
            microphoneCapture.discardRecordingAndPause()
            try? await audioSessionCoordinator.endAndWait(.capture)
            try? backgroundAnchor.start()

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

    private func restoreBackgroundExecution(
        forceReassert: Bool = false
    ) async -> Bool {
        guard isServiceReady else { return false }

        if !forceReassert, backgroundAnchor.isRunning {
            return true
        }

        if let backgroundRestoreTask {
            return await backgroundRestoreTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }

            do {
                if forceReassert {
                    try await self.audioSessionCoordinator.reassertCurrentProfile()
                } else {
                    try await self.audioSessionCoordinator.beginAndWait(.backgroundKeepAlive)
                }

                try self.backgroundAnchor.start()
                self.lastError = nil
                self.markBridgeChanged()
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                self.lastError = error.localizedDescription
                self.markBridgeChanged()
                return false
            }
        }

        backgroundRestoreTask = task
        let restored = await task.value
        backgroundRestoreTask = nil
        return restored
    }

    private func stopRecordingFromKeyboard(expectedRequestID: String?) async {
        guard bridgeStatus == .recording else { return }

        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else {
            return
        }

        // Start silent playback before pausing input so background execution
        // has no gap. Then close the file gate and pause the prepared engine.
        bridgeAudioStage = .returningToStandby
        markBridgeChanged()
        try? backgroundAnchor.start()

        guard let fileURL = microphoneCapture.finishRecordingAndPause() else {
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
            try? backgroundAnchor.start()
            microphoneCapture.discardRecordingAndPause()
            try? await audioSessionCoordinator.endAndWait(.capture)
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

        guard microphoneCapture.isActive
                || bridgeStatus == .recording
                || bridgeStatus == .starting else {
            markBridgeChanged()
            return
        }

        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartRequestID = nil

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.microphoneCapture.shutdown()
            try? await self.audioSessionCoordinator.endAndWait(.capture)
            self.bridgeAudioStage = .failed

            if let interruptedRequestID,
               self.activeRequestID == interruptedRequestID {
                self.publishBridgeError(
                    "Microphone session was interrupted.",
                    requestID: interruptedRequestID,
                    kind: .interrupted,
                    retryAvailable: false,
                    claimed: true
                )
                self.status = .failed
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
            microphoneReady: microphoneCapture.isActive,
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
