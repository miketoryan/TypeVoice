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

    private let audioService = AudioStandbyService()
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
    private var audioActivationTask: Task<Bool, Never>?

    init() {
        audioService.onExpired = { [weak self] in
            Task { @MainActor in
                self?.disarm()
            }
        }

        audioService.onInterrupted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.audioActivationTask?.cancel()
                self.audioActivationTask = nil
                self.audioService.cancelRecording(keepWarm: false)

                // Keep the local service logically available. The keyboard can
                // now distinguish "service alive" from "microphone unavailable"
                // and attempt a background microphone recovery before falling
                // back to the existing foreground cold-start path.
                self.publishBridgeError("Microphone session was interrupted.")
                self.status = .failed
            }
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
        audioActivationTask?.cancel()
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

        let granted = await audioService.requestMicrophonePermission()
        guard granted else {
            lastError = "Microphone permission is required."
            status = .failed
            return
        }

        do {
            try await activateMicrophoneWithRetry()

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
            publishBridgeError(error.localizedDescription)
            status = .failed
        }
    }

    func disarm() {
        processingTask?.cancel()
        processingTask = nil
        audioActivationTask?.cancel()
        audioActivationTask = nil

        audioService.cancelRecording(keepWarm: false)

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
            if !isServiceReady || !audioService.isRunning {
                await arm()
            }

            guard cameFromKeyboard, isServiceReady, audioService.isRunning else {
                return
            }

            if shouldAutoStart,
               let requestedRecordingID,
               !requestedRecordingID.isEmpty {
                startRecordingFromKeyboard(requestID: requestedRecordingID)

                guard bridgeStatus == .recording,
                      activeRequestID == requestedRecordingID else {
                    return
                }
            }

            // Give the microphone graph a brief moment to settle before moving
            // TypeVoice back to the background. In the auto-start path this
            // means the user arrives back at the original text field with audio
            // capture already active.
            try? await Task.sleep(for: .milliseconds(280))

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

        // A stopped AVAudioEngine no longer means the whole local service is
        // gone. Keep serviceReady intact so the keyboard can first attempt a
        // background microphone recovery.
        if isServiceReady && !audioService.isRunning {
            markBridgeChanged()
        }
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
            break

        case .startRecording:
            if await ensureMicrophoneReadyForRecording(requestID: request.requestID) {
                startRecordingFromKeyboard(requestID: request.requestID)
            }

        case .stopRecording:
            stopRecordingFromKeyboard(expectedRequestID: request.requestID)

        case .cancelRecording:
            cancelRecordingFromKeyboard(expectedRequestID: request.requestID)

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)
        }

        return currentBridgeState()
    }

    private func ensureMicrophoneReadyForRecording(requestID: String?) async -> Bool {
        guard isServiceReady else { return false }

        if audioService.isRunning {
            return true
        }

        if let audioActivationTask {
            return await audioActivationTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }

            do {
                try await self.activateMicrophoneWithRetry()
                guard self.isServiceReady else {
                    self.audioService.cancelRecording(keepWarm: false)
                    return false
                }

                self.lastError = nil
                self.bridgeError = nil
                self.status = .ready
                self.markBridgeChanged()
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                self.publishBridgeError(
                    error.localizedDescription,
                    requestID: requestID
                )
                self.status = .failed
                return false
            }
        }

        audioActivationTask = task
        let activated = await task.value
        audioActivationTask = nil
        return activated
    }

    private func activateMicrophoneWithRetry() async throws {
        var retry = 0

        while true {
            do {
                let expiry = Date().addingTimeInterval(
                    TimeInterval(SharedStore.quickStandbySeconds)
                )
                try audioService.arm(until: expiry)
                return
            } catch {
                guard Self.isTransientAudioSessionError(error), retry < 4 else {
                    throw error
                }

                retry += 1
                try await Task.sleep(for: .milliseconds(150 * retry))
            }
        }
    }

    private static func isTransientAudioSessionError(_ error: Error) -> Bool {
        let code = (error as NSError).code

        // These are the same short-lived audio transition errors observed on
        // real devices in VoiceKing while moving between a host app, keyboard
        // extension, and the containing app.
        return code == 560_557_684 || code == 2_003_329_396
    }

    private func startRecordingFromKeyboard(requestID: String?) {
        guard isServiceReady, audioService.isRunning else {
            publishBridgeError(
                "Open TypeVoice and enable Quick Dictation first.",
                requestID: requestID
            )
            return
        }

        guard let requestID, !requestID.isEmpty else {
            publishBridgeError("TypeVoice received an invalid recording request.")
            return
        }

        guard bridgeStatus != .starting,
              bridgeStatus != .recording,
              bridgeStatus != .transcribing,
              bridgeStatus != .polishing else {
            return
        }

        bridgeStatus = .starting
        status = .starting
        activeRequestID = requestID
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        markBridgeChanged()

        do {
            _ = try audioService.beginRecording()
            bridgeStatus = .recording
            status = .recording
            lastError = nil
            markBridgeChanged()
        } catch {
            publishBridgeError(error.localizedDescription, requestID: requestID)
            status = .failed
        }
    }

    private func stopRecordingFromKeyboard(expectedRequestID: String?) {
        guard bridgeStatus == .recording else { return }

        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else {
            return
        }

        guard let fileURL = audioService.finishRecording(keepWarm: true) else {
            publishBridgeError("Recording file was not available.", requestID: requestID)
            status = .failed
            return
        }

        bridgeStatus = .transcribing
        status = .transcribing
        bridgeError = nil
        markBridgeChanged()

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.process(fileURL: fileURL, requestID: requestID)
        }
    }

    private func cancelRecordingFromKeyboard(expectedRequestID: String?) {
        guard expectedRequestID == nil || expectedRequestID == activeRequestID else {
            return
        }

        processingTask?.cancel()
        processingTask = nil
        audioService.cancelRecording(keepWarm: true)

        activeRequestID = nil
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        bridgeStatus = .idle
        status = isServiceReady ? .ready : .idle
        markBridgeChanged()
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
            microphoneReady: audioService.isRunning,
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
