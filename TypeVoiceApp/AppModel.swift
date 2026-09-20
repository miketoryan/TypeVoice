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
    private var activeRequestID: String?
    private var responseText: String?
    private var resultCreatedAt: Date?
    private var bridgeError: String?

    private var processingTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var recordingStartTask: Task<Bool, Never>?
    private var backgroundRestoreTask: Task<Bool, Never>?

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
                self.microphoneCapture.stopAndDiscard()
                _ = await self.restoreBackgroundExecution(forceReassert: true)
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

        refreshAuthState()
    }

    deinit {
        processingTask?.cancel()
        loginTask?.cancel()
        recordingStartTask?.cancel()
        backgroundRestoreTask?.cancel()
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

    /// Arms Typeless-style background readiness.
    ///
    /// The microphone remains fully off here. The silent playback anchor is what
    /// keeps the containing app executable so a later keyboard command can start
    /// the microphone on demand without opening TypeVoice.
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
            try backgroundAnchor.start()

            isServiceReady = true
            status = .ready
            bridgeStatus = .idle
            bridgeError = nil
            activeRequestID = nil
            responseText = nil
            resultCreatedAt = nil
            lastError = nil
            markBridgeChanged()
        } catch {
            backgroundAnchor.stop()
            audioSessionCoordinator.reset()
            publishBridgeError(error.localizedDescription)
            status = .failed
        }
    }

    func disarm() {
        processingTask?.cancel()
        processingTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        backgroundRestoreTask?.cancel()
        backgroundRestoreTask = nil

        microphoneCapture.stopAndDiscard()
        backgroundAnchor.stop()
        audioSessionCoordinator.reset()

        isServiceReady = false
        status = .idle
        bridgeStatus = .idle
        activeRequestID = nil
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        markBridgeChanged()
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "typevoice" else { return }
        guard url.host?.lowercased() == "prepare" else { return }

        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        let source = components?.queryItems?
            .first(where: { $0.name == "source" })?
            .value
        let requestedHostBundleID = components?.queryItems?
            .first(where: { $0.name == "host" })?
            .value
        let requestedRecordingID = components?.queryItems?
            .first(where: { $0.name == "request" })?
            .value
        let shouldAutoStart = components?.queryItems?
            .first(where: { $0.name == "autostart" })?
            .value == "1"
        let cameFromKeyboard = source == "keyboard"

        Task {
            if !isServiceReady {
                await arm()
            } else if !backgroundWakeReady {
                _ = await restoreBackgroundExecution(forceReassert: true)
            }

            guard cameFromKeyboard, isServiceReady else {
                return
            }

            if shouldAutoStart,
               let requestedRecordingID,
               !requestedRecordingID.isEmpty {
                let started = await startRecordingFromKeyboard(
                    requestID: requestedRecordingID
                )

                guard started,
                      bridgeStatus == .recording,
                      activeRequestID == requestedRecordingID else {
                    return
                }
            }

            // The foreground fallback still starts real capture before returning.
            // By the time this delay ends the first microphone buffer has already
            // arrived, so the user lands back in the text field while recording.
            try? await Task.sleep(for: .milliseconds(220))

            guard let requestedHostBundleID,
                  !requestedHostBundleID.isEmpty
            else {
                return
            }

            _ = PreviousAppReturner.open(bundleID: requestedHostBundleID)
        }
    }

    func appBecameActive() {
        refreshAuthState()

        guard isServiceReady else { return }

        Task {
            _ = await restoreBackgroundExecution(forceReassert: false)
        }
    }

    private var backgroundWakeReady: Bool {
        guard isServiceReady else { return false }

        // During recording the capture engine itself keeps execution alive.
        // At idle, the playback anchor is the readiness source.
        return backgroundAnchor.isRunning || microphoneCapture.isActive
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

    private func handleBridgeRequest(_ request: BridgeRequest) async -> BridgeState {
        switch request.action {
        case .state:
            break

        case .heartbeat:
            if isServiceReady,
               !backgroundWakeReady,
               !microphoneCapture.isActive {
                _ = await restoreBackgroundExecution()
            }

        case .startRecording:
            _ = await startRecordingFromKeyboard(requestID: request.requestID)

        case .stopRecording:
            await stopRecordingFromKeyboard(expectedRequestID: request.requestID)

        case .cancelRecording:
            await cancelRecordingFromKeyboard(expectedRequestID: request.requestID)

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)
        }

        return currentBridgeState()
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

    private func startRecordingFromKeyboard(requestID: String?) async -> Bool {
        guard let requestID, !requestID.isEmpty else {
            publishBridgeError("TypeVoice received an invalid recording request.")
            return false
        }

        guard isServiceReady else {
            publishBridgeError(
                "Open TypeVoice and enable Quick Dictation first.",
                requestID: requestID
            )
            return false
        }

        guard bridgeStatus != .starting,
              bridgeStatus != .recording,
              bridgeStatus != .transcribing,
              bridgeStatus != .polishing else {
            return bridgeStatus == .recording && activeRequestID == requestID
        }

        if let recordingStartTask {
            return await recordingStartTask.value
        }

        bridgeStatus = .starting
        status = .starting
        activeRequestID = requestID
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        markBridgeChanged()

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }

            do {
                if !self.backgroundWakeReady {
                    guard await self.restoreBackgroundExecution() else {
                        throw BackgroundAnchorError.couldNotStart
                    }
                }

                try await self.audioSessionCoordinator.beginAndWait(.capture)

                // The keep-alive player is deliberately left running across the
                // profile switch. If iOS paused it during the category change,
                // restart it before starting input so there is no execution gap.
                try? self.backgroundAnchor.start()

                _ = try await self.startMicrophoneWithRecovery()

                self.bridgeStatus = .recording
                self.status = .recording
                self.lastError = nil
                self.bridgeError = nil
                self.markBridgeChanged()
                return true
            } catch {
                self.microphoneCapture.stopAndDiscard()
                try? await self.audioSessionCoordinator.endAndWait(.capture)
                try? self.backgroundAnchor.start()

                self.publishBridgeError(
                    error.localizedDescription,
                    requestID: requestID
                )
                self.status = .failed
                return false
            }
        }

        recordingStartTask = task
        let started = await task.value
        recordingStartTask = nil
        return started
    }

    private func startMicrophoneWithRecovery() async throws -> URL {
        var lastError: Error = MicrophoneCaptureError.inputUnavailable

        for attempt in 0..<3 {
            do {
                return try await microphoneCapture.startRecording()
            } catch {
                lastError = error
                microphoneCapture.stopAndDiscard()

                guard attempt < 2 else { break }

                try? await audioSessionCoordinator.reassertCurrentProfile()
                try? backgroundAnchor.start()
                try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            }
        }

        throw lastError
    }

    private func stopRecordingFromKeyboard(expectedRequestID: String?) async {
        guard bridgeStatus == .recording else { return }

        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else {
            return
        }

        // Preserve background execution first, then shut the input engine down.
        // The privacy indicator can turn off immediately; transcription happens
        // afterwards with only the playback anchor alive.
        try? backgroundAnchor.start()

        guard let fileURL = microphoneCapture.finishRecording() else {
            publishBridgeError("Recording file was not available.", requestID: requestID)
            status = .failed
            return
        }

        try? await audioSessionCoordinator.endAndWait(.capture)
        try? backgroundAnchor.start()

        bridgeStatus = .transcribing
        status = .transcribing
        bridgeError = nil
        markBridgeChanged()

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.process(fileURL: fileURL, requestID: requestID)
        }
    }

    private func cancelRecordingFromKeyboard(expectedRequestID: String?) async {
        guard expectedRequestID == nil || expectedRequestID == activeRequestID else {
            return
        }

        processingTask?.cancel()
        processingTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil

        try? backgroundAnchor.start()
        microphoneCapture.stopAndDiscard()
        try? await audioSessionCoordinator.endAndWait(.capture)
        try? backgroundAnchor.start()

        activeRequestID = nil
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        bridgeStatus = .idle
        status = isServiceReady ? .ready : .idle
        markBridgeChanged()
    }

    private func audioInterruptionBegan() {
        guard isServiceReady else { return }

        markBridgeChanged()

        guard microphoneCapture.isActive || bridgeStatus == .recording else {
            return
        }

        let interruptedRequestID = activeRequestID

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.microphoneCapture.stopAndDiscard()
            try? await self.audioSessionCoordinator.endAndWait(.capture)

            if let interruptedRequestID {
                self.publishBridgeError(
                    "Microphone session was interrupted.",
                    requestID: interruptedRequestID
                )
                self.status = .failed
            }
        }
    }

    private func process(fileURL: URL, requestID: String) async {
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

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

            guard !Task.isCancelled, activeRequestID == requestID else { return }

            lastTranscript = raw
            bridgeStatus = .polishing
            status = .polishing
            markBridgeChanged()

            let finalText: String
            do {
                finalText = try await client.cleanup(raw)
            } catch let error as ChatGPTClientError where error.isUnauthorized {
                tokens = try await authManager.validTokens(forceRefresh: true)
                client = makeClient(tokens)
                finalText = try await client.cleanup(raw)
            } catch {
                finalText = raw
                lastError = "Cleanup failed; raw transcript will be inserted. \(error.localizedDescription)"
            }

            guard !Task.isCancelled, activeRequestID == requestID else { return }

            responseText = finalText
            resultCreatedAt = Date()
            bridgeError = nil
            bridgeStatus = .completed
            status = isServiceReady ? .ready : .idle
            lastTranscript = finalText
            refreshAuthState()
            markBridgeChanged()
        } catch {
            if error is ChatGPTAuthError {
                isChatGPTLoggedIn = false
                chatGPTAccountSummary = nil
            }

            publishBridgeError(error.localizedDescription, requestID: requestID)
            status = .failed
        }
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

        activeRequestID = nil
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil

        if bridgeStatus == .completed || bridgeStatus == .error {
            bridgeStatus = .idle
        }

        status = isServiceReady ? .ready : .idle
        markBridgeChanged()
    }

    private func publishBridgeError(_ message: String, requestID: String? = nil) {
        if let requestID {
            activeRequestID = requestID
        }

        responseText = nil
        resultCreatedAt = Date()
        bridgeError = message
        bridgeStatus = .error
        lastError = message
        markBridgeChanged()
    }

    private func currentBridgeState() -> BridgeState {
        BridgeState(
            serverID: serverID,
            revision: bridgeRevision,
            serviceReady: isServiceReady,
            backgroundWakeReady: backgroundWakeReady,
            microphoneReady: microphoneCapture.isActive,
            status: bridgeStatus,
            requestID: activeRequestID,
            transcribedText: responseText,
            resultCreatedAt: resultCreatedAt,
            lastError: bridgeError,
            interfaceLanguage: SharedStore.interfaceLanguage.rawValue
        )
    }

    private func markBridgeChanged() {
        bridgeRevision &+= 1
    }
}
