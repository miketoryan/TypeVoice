import SwiftUI
import UIKit

@MainActor
private final class TypeVoiceURLLauncher: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let url: URL
    }

    @Published var request: Request?

    func open(_ url: URL) {
        request = Request(url: url)
    }
}

private struct TypeVoiceURLLauncherView: View {
    @ObservedObject var launcher: TypeVoiceURLLauncher
    @Environment(\.openURL) private var openURL

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onChange(of: launcher.request) { request in
                guard let request else { return }
                openURL(request.url)
                launcher.request = nil
            }
    }
}

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micContainer = UIView()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    private let bridge = LocalBridgeClient()
    private let urlLauncher = TypeVoiceURLLauncher()
    private var urlLauncherHost: UIHostingController<TypeVoiceURLLauncherView>?

    private var latestState = BridgeState.unavailable()
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var insertionScheduledForRequestID: String?
    private var hostBundleID: String?
    private var foregroundHandoffPending = false
    private var pendingForegroundRecordingRequestID: String?
    private var lastBridgeSuccessAt: Date?
    private var darwinObservations: [DarwinObservation] = []

    private let readinessLeaseSeconds: TimeInterval = 3

    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var hostResolveTask: Task<Void, Never>?
    private var foregroundFallbackRequestID: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        foregroundHandoffPending = false
        hostBundleID = hostBundleID ?? HostApplicationResolver.lastCaptured

        DarwinBus.post(.keyboardVisible)
        resolveHostApplicationInAdvance()
        startDarwinStateObservers()
        startBridgeTasks()
        refreshUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        if keyboardVisible && !foregroundHandoffPending {
            DarwinBus.post(.keyboardHidden)
        }
        keyboardVisible = false
        mayAutoInsert = false
        insertionScheduledForRequestID = nil
        stopBridgeTasks()
        darwinObservations.removeAll()
        hostResolveTask?.cancel()
        hostResolveTask = nil
        if !foregroundHandoffPending {
            HostApplicationResolver.invalidate()
            hostBundleID = nil
        }
        super.viewWillDisappear(animated)
    }

    deinit {
        if keyboardVisible && !foregroundHandoffPending {
            DarwinBus.post(.keyboardHidden)
        }
        pollingTask?.cancel()
        commandTask?.cancel()
        hostResolveTask?.cancel()
        darwinObservations.removeAll()
    }

    @objc private func microphoneTapped() {
        guard hasFullAccess else {
            statusLabel.text = localized(
                "请在系统设置里开启“允许完全访问”",
                "Enable Allow Full Access in Settings"
            )
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID) {
            insertLatestTranscription(automatically: false)
            return
        }

        if pendingForegroundRecordingRequestID != nil {
            return
        }

        switch latestState.status {
        case .recording:
            mayAutoInsert = true
            sendCommand(
                .stopRecording,
                requestID: latestState.requestID ?? currentRequestID
            )

        case .transcribing, .polishing:
            sendCommand(
                .cancelRecording,
                requestID: latestState.requestID ?? currentRequestID
            )

        case .starting:
            // A hot-path start can still be cancelled. A cold foreground handoff
            // is tracked separately by pendingForegroundRecordingRequestID.
            sendCommand(
                .cancelRecording,
                requestID: latestState.requestID ?? currentRequestID
            )

        case .error:
            if latestState.failureKind == .transcriptionRecoverable,
               latestState.retryAvailable {
                sendCommand(
                    .retryProcessing,
                    requestID: latestState.requestID ?? currentRequestID
                )
            } else if latestState.failureKind == .authRequired {
                openTypeVoiceForAccountRecovery()
            } else {
                launchTypeVoiceAndResumeRecording()
            }

        default:
            // Stable jump-first rule: starting a new dictation always foregrounds
            // TypeVoice once, starts microphone IO there, then returns to the host.
            // Do not spend time probing a background service that is not relied on.
            launchTypeVoiceAndResumeRecording()
        }
    }

    @objc private func globeTapped() {
        if keyboardVisible {
            DarwinBus.post(.keyboardHidden)
        }
        keyboardVisible = false
        mayAutoInsert = false
        insertionScheduledForRequestID = nil
        stopBridgeTasks()
        advanceToNextInputMode()
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    private func configureUI() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel

        micContainer.translatesAutoresizingMaskIntoConstraints = false

        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        micButton.layer.cornerRadius = 24
        micButton.addTarget(self, action: #selector(microphoneTapped), for: .touchUpInside)
        micContainer.addSubview(micButton)
        NSLayoutConstraint.activate([
            micButton.leadingAnchor.constraint(equalTo: micContainer.leadingAnchor),
            micButton.trailingAnchor.constraint(equalTo: micContainer.trailingAnchor),
            micButton.topAnchor.constraint(equalTo: micContainer.topAnchor),
            micButton.bottomAnchor.constraint(equalTo: micContainer.bottomAnchor)
        ])

        configureUtilityButton(globeButton, title: "🌐", action: #selector(globeTapped))
        configureUtilityButton(deleteButton, title: "⌫", action: #selector(deleteTapped))
        configureUtilityButton(returnButton, title: "↵", action: #selector(returnTapped))
        configureUtilityButton(spaceButton, title: localized("空格", "Space"), action: #selector(spaceTapped))

        let utilityRow = UIStackView(
            arrangedSubviews: [globeButton, spaceButton, returnButton, deleteButton]
        )
        utilityRow.axis = .horizontal
        utilityRow.spacing = 8
        utilityRow.distribution = .fillProportionally

        let root = UIStackView(arrangedSubviews: [statusLabel, micContainer, utilityRow])
        root.axis = .vertical
        root.alignment = .fill
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            micContainer.heightAnchor.constraint(equalToConstant: 54),
            utilityRow.heightAnchor.constraint(equalToConstant: 44),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])

        // VoiceKing v0.3.9-style handoff: keep one normal microphone button
        // and use SwiftUI openURL only as the transport that foregrounds TypeVoice.
        let launcherHost = UIHostingController(
            rootView: TypeVoiceURLLauncherView(launcher: urlLauncher)
        )
        launcherHost.view.translatesAutoresizingMaskIntoConstraints = false
        launcherHost.view.backgroundColor = .clear
        launcherHost.view.isUserInteractionEnabled = false
        addChild(launcherHost)
        view.addSubview(launcherHost.view)
        NSLayoutConstraint.activate([
            launcherHost.view.widthAnchor.constraint(equalToConstant: 1),
            launcherHost.view.heightAnchor.constraint(equalToConstant: 1),
            launcherHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launcherHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        launcherHost.didMove(toParent: self)
        urlLauncherHost = launcherHost
    }

    private func resolveHostApplicationInAdvance() {
        guard hostBundleID == nil else { return }

        hostResolveTask?.cancel()
        hostResolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let bundleID = await self.resolveHostBundleIdentifier()
            guard !Task.isCancelled else { return }

            if let bundleID {
                self.hostBundleID = bundleID
                self.refreshUI()
            }
        }
    }

    private func resolveHostBundleIdentifier() async -> String? {
        if let cached = HostApplicationResolver.lastCaptured {
            return cached
        }

        // Match VoiceKing's "resolve in advance, retry briefly on tap" model.
        // The TypeVoice resolver itself is newer and is retained because it is
        // more accurate on current iOS keyboard-host processes.
        for _ in 0..<15 {
            guard keyboardVisible else { return nil }

            if let bundleID = HostApplicationResolver.resolve(from: self) {
                return bundleID
            }

            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return nil
            }
        }

        return HostApplicationResolver.lastCaptured
    }

    private func configureUtilityButton(
        _ button: UIButton,
        title: String,
        action: Selector
    ) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(
            top: 8,
            left: 14,
            bottom: 8,
            right: 14
        )
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private var bridgeLeaseIsFresh: Bool {
        guard let lastBridgeSuccessAt else { return false }
        return Date().timeIntervalSince(lastBridgeSuccessAt) <= readinessLeaseSeconds
    }

    private func startDarwinStateObservers() {
        darwinObservations.removeAll()

        darwinObservations = [
            DarwinBus.observe(.statusChanged) { [weak self] in
                Task { @MainActor in
                    await self?.fetchState()
                }
            },
            DarwinBus.observe(.resultReady) { [weak self] in
                Task { @MainActor in
                    await self?.fetchState()
                }
            },
            DarwinBus.observe(.serviceChanged) { [weak self] in
                Task { @MainActor in
                    await self?.fetchState()
                }
            }
        ]
    }

    private func darwinEvent(for action: BridgeAction) -> DarwinEvent? {
        switch action {
        case .startRecording:
            return .startRecording
        case .stopRecording:
            return .stopRecording
        case .cancelRecording:
            return .cancelRecording
        case .retryProcessing:
            return .retryProcessing
        case .acknowledgeResult:
            return .acknowledgeResult
        case .state:
            return nil
        }
    }

    private func postDarwinWake(for action: BridgeAction) {
        guard let event = darwinEvent(for: action) else { return }
        DarwinBus.post(event)
    }

    private func startBridgeTasks() {
        stopBridgeTasks()

        // State polling is only for UI/result delivery while the keyboard is
        // visible. It is not a keep-alive or a background wake mechanism.
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.fetchState(timeoutInterval: 0.8)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(600))
                } catch {
                    return
                }
                await self.fetchState(timeoutInterval: 0.8)
            }
        }
    }

    private func stopBridgeTasks() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func fetchState(
        timeoutInterval: TimeInterval = 0.8
    ) async {
        guard keyboardVisible else { return }

        do {
            let state = try await bridge.fetchState(
                timeoutInterval: timeoutInterval
            )
            apply(state)
        } catch {
            applyConnectionFailure()
        }
    }

    private func sendCommand(_ action: BridgeAction, requestID: String?) {
        commandTask?.cancel()

        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 0..<2 {
                self.postDarwinWake(for: action)
                try? await Task.sleep(
                    for: attempt == 0 ? .milliseconds(35) : .milliseconds(90)
                )

                do {
                    let state = try await self.bridge.send(
                        action,
                        requestID: requestID,
                        timeoutInterval: 0.9
                    )
                    self.apply(state)
                    return
                } catch {
                    guard attempt == 0 else {
                        if action == .startRecording,
                           let requestID {
                            self.launchTypeVoiceAndResumeRecording(
                                requestID: requestID
                            )
                        } else {
                            self.applyConnectionFailure()
                        }
                        return
                    }
                }
            }
        }
    }

    private func apply(_ state: BridgeState) {
        lastBridgeSuccessAt = Date()

        if state.serverID == latestState.serverID,
           state.revision < latestState.revision {
            return
        }

        latestState = state

        // If the ACTIVE service answered the probe but iOS rejected opening
        // microphone input from background, recover automatically with the same
        // request ID. The containing app can then start input while foregrounded
        // and jump back without requiring a second user tap.
        if state.status == .error,
           state.failureKind == .audioStartFailed,
           let requestID = state.requestID,
           requestID == currentRequestID,
           pendingForegroundRecordingRequestID == nil,
           foregroundFallbackRequestID != requestID {
            foregroundFallbackRequestID = requestID
            launchTypeVoiceAndResumeRecording(requestID: requestID)
            return
        }

        if let pendingRequestID = pendingForegroundRecordingRequestID {
            if state.status == .recording,
               state.requestID == pendingRequestID {
                pendingForegroundRecordingRequestID = nil
                mayAutoInsert = true
            } else if state.status == .error,
                      state.requestID == pendingRequestID {
                pendingForegroundRecordingRequestID = nil
            }
        }

        if let requestID = state.requestID,
           state.status == .starting
            || state.status == .recording
            || state.status == .transcribing
            || state.status == .polishing
            || state.status == .completed {
            if currentRequestID == nil {
                currentRequestID = requestID
            }
            mayAutoInsert = true
        }

        refreshUI()

        if state.status == .idle,
           state.requestID == nil {
            currentRequestID = nil
            mayAutoInsert = false
            insertionScheduledForRequestID = nil
            foregroundFallbackRequestID = nil
        }

        if state.status == .completed,
           let requestID = state.requestID,
           insertionScheduledForRequestID != requestID {
            insertionScheduledForRequestID = requestID

            // Give the host text field one short turn to settle before the
            // single physical insertText call. We do not auto-retry insertion.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                guard self.insertionScheduledForRequestID == requestID else { return }
                self.insertionScheduledForRequestID = nil
                self.insertLatestTranscription()
            }
        }
    }

    private func applyConnectionFailure() {
        // UI polling is only for state/result delivery. New recordings use the
        // deterministic foreground handoff, so one missed poll must not disturb UI.
        if bridgeLeaseIsFresh {
            return
        }

        guard latestState.status != .recording,
              latestState.status != .transcribing,
              latestState.status != .polishing else {
            return
        }

        pendingForegroundRecordingRequestID = nil
        currentRequestID = nil
        mayAutoInsert = false
        insertionScheduledForRequestID = nil

        latestState = .unavailable(
            localized(
                "热麦克风已结束 · 点击会打开 TypeVoice 重新激活",
                "Warm microphone ended · tap to open TypeVoice and reactivate"
            ),
            interfaceLanguage: latestState.interfaceLanguage
        )

        if hostBundleID == nil {
            resolveHostApplicationInAdvance()
        }
        refreshUI()
    }

    private func refreshUI() {
        micButton.isHidden = false

        guard hasFullAccess else {
            micButton.isUserInteractionEnabled = true
            statusLabel.text = localized(
                "TypeVoice 需要“允许完全访问”",
                "TypeVoice needs Full Access"
            )
            micButton.setTitle(
                localized("开启完全访问", "Enable Full Access"),
                for: .normal
            )
            micButton.backgroundColor = .systemGray.withAlphaComponent(0.18)
            return
        }

        if pendingForegroundRecordingRequestID != nil {
            statusLabel.text = localized(
                "正在启动 TypeVoice 并打开麦克风…",
                "Opening TypeVoice and starting the microphone…"
            )
            micButton.setTitle(
                localized("正在打开…", "Opening…"),
                for: .normal
            )
            micButton.backgroundColor = .systemGray.withAlphaComponent(0.18)
            micButton.isUserInteractionEnabled = false
            return
        }

        micButton.isUserInteractionEnabled = true

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID),
           latestState.transcribedText != nil {
            statusLabel.text = localized(
                "识别完成，正在自动插入",
                "Transcription ready · inserting"
            )
            micButton.setTitle(
                localized("插入结果", "Insert Result"),
                for: .normal
            )
            micButton.backgroundColor = .systemGreen.withAlphaComponent(0.18)
            return
        }

        switch latestState.status {
        case .idle:
            if latestState.quickDictationEnabled == false {
                statusLabel.text = localized(
                    "快速语音未开启 · 点击会打开 TypeVoice",
                    "Quick Dictation is off · tap to open TypeVoice"
                )
            } else {
                statusLabel.text = localized(
                    "点击后短暂打开 TypeVoice 并自动返回",
                    "Tap to briefly open TypeVoice and return automatically"
                )
            }
            micButton.setTitle(
                localized("🎙 开始语音", "🎙 Speak"),
                for: .normal
            )
            micButton.backgroundColor = .systemBlue.withAlphaComponent(0.14)

        case .starting:
            statusLabel.text = latestState.requestClaimed
                ? localized(
                    "TypeVoice 已接单 · 正在启动麦克风",
                    "TypeVoice claimed the request · starting microphone"
                )
                : localized(
                    "正在联系后台 TypeVoice…",
                    "Contacting TypeVoice in the background…"
                )
            micButton.setTitle(
                localized("■ 取消启动", "■ Cancel"),
                for: .normal
            )
            micButton.backgroundColor = .systemOrange.withAlphaComponent(0.18)

        case .recording:
            statusLabel.text = localized(
                "正在录音 · 再点一次结束",
                "Recording · tap again to stop"
            )
            micButton.setTitle(
                localized("■ 结束语音", "■ Stop"),
                for: .normal
            )
            micButton.backgroundColor = .systemRed.withAlphaComponent(0.18)

        case .transcribing:
            statusLabel.text = localized(
                "正在识别 · 点击可立即终止",
                "Transcribing · tap to cancel immediately"
            )
            micButton.setTitle(
                localized("■ 终止识别", "■ Cancel Transcription"),
                for: .normal
            )
            micButton.backgroundColor = .systemOrange.withAlphaComponent(0.18)

        case .polishing:
            statusLabel.text = localized(
                "正在整理表达 · 点击可立即终止",
                "Cleaning up · tap to cancel immediately"
            )
            micButton.setTitle(
                localized("■ 终止处理", "■ Cancel Processing"),
                for: .normal
            )
            micButton.backgroundColor = .systemOrange.withAlphaComponent(0.18)

        case .completed:
            break

        case .error:
            statusLabel.text = latestState.lastError ?? localized(
                "语音处理失败",
                "Dictation failed"
            )

            switch latestState.failureKind {
            case .transcriptionRecoverable where latestState.retryAvailable:
                micButton.setTitle(
                    localized("↻ 重试识别", "↻ Retry Transcription"),
                    for: .normal
                )

            case .authRequired:
                micButton.setTitle(
                    localized("打开 TypeVoice 登录", "Open TypeVoice to Sign In"),
                    for: .normal
                )

            case .audioStartFailed, .bridgeUnavailable, .interrupted:
                micButton.setTitle(
                    localized("🎙 打开 TypeVoice 恢复", "🎙 Open TypeVoice to Recover"),
                    for: .normal
                )

            default:
                micButton.setTitle(
                    localized("🎙 重新输入", "🎙 Record Again"),
                    for: .normal
                )
            }

            micButton.backgroundColor = .systemOrange.withAlphaComponent(0.18)
        }

        spaceButton.setTitle(localized("空格", "Space"), for: .normal)
    }

    private func launchTypeVoiceAndResumeRecording(
        requestID suppliedRequestID: String? = nil
    ) {
        guard pendingForegroundRecordingRequestID == nil else { return }

        let requestID = suppliedRequestID ?? UUID().uuidString
        foregroundFallbackRequestID = requestID
        currentRequestID = requestID
        mayAutoInsert = true
        insertionScheduledForRequestID = nil
        pendingForegroundRecordingRequestID = requestID

        statusLabel.text = localized(
            "正在启动 TypeVoice…",
            "Opening TypeVoice…"
        )
        micButton.setTitle(
            localized("正在打开…", "Opening…"),
            for: .normal
        )
        micButton.backgroundColor = .systemGray.withAlphaComponent(0.18)
        micButton.isUserInteractionEnabled = false

        if let hostBundleID {
            openTypeVoice(
                returningTo: hostBundleID,
                requestID: requestID
            )
            return
        }

        hostResolveTask?.cancel()
        hostResolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await self.resolveHostBundleIdentifier()
            guard !Task.isCancelled,
                  self.pendingForegroundRecordingRequestID == requestID else {
                return
            }

            guard let resolved else {
                self.pendingForegroundRecordingRequestID = nil
                self.currentRequestID = nil
                self.mayAutoInsert = false
                self.statusLabel.text = self.localized(
                    "无法识别当前输入 App，请切换一次键盘后重试",
                    "Could not identify the current app. Switch keyboards once and try again."
                )
                self.refreshUI()
                return
            }

            self.hostBundleID = resolved
            self.openTypeVoice(
                returningTo: resolved,
                requestID: requestID
            )
        }
    }

    private func openTypeVoice(
        returningTo hostBundleID: String,
        requestID: String
    ) {
        var components = URLComponents()
        components.scheme = "typevoice"
        components.host = "prepare"
        components.queryItems = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "autostart", value: "1"),
            URLQueryItem(name: "request", value: requestID),
            URLQueryItem(name: "host", value: hostBundleID)
        ]

        guard let url = components.url else {
            pendingForegroundRecordingRequestID = nil
            refreshUI()
            return
        }

        // VoiceKing v0.3.9 rule: one normal keyboard button initiates the
        // foreground handoff. SwiftUI openURL performs the primary launch.
        foregroundHandoffPending = true
        urlLauncher.open(url)

        // Keep VoiceKing's sideload fallback. If SwiftUI already foregrounded
        // TypeVoice, viewWillDisappear makes keyboardVisible false and this is skipped.
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }

            guard let self,
                  self.keyboardVisible,
                  self.pendingForegroundRecordingRequestID == requestID else {
                return
            }

            if !self.openURLViaResponderChain(url) {
                self.foregroundHandoffPending = false
                self.pendingForegroundRecordingRequestID = nil
                self.currentRequestID = nil
                self.mayAutoInsert = false
                self.statusLabel.text = self.localized(
                    "无法自动打开 TypeVoice，请再点一次语音",
                    "Could not open TypeVoice automatically. Tap the microphone again."
                )
                self.refreshUI()
            }
        }
    }

    @discardableResult
    private func openURLViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }

        return false
    }

    private func openTypeVoiceForAccountRecovery() {
        var components = URLComponents()
        components.scheme = "typevoice"
        components.host = "prepare"
        components.queryItems = [
            URLQueryItem(name: "source", value: "auth")
        ]

        guard let url = components.url else { return }

        statusLabel.text = localized(
            "正在打开 TypeVoice 重新登录…",
            "Opening TypeVoice to sign in again…"
        )
        foregroundHandoffPending = true
        urlLauncher.open(url)
    }

    private func insertLatestTranscription(automatically: Bool = true) {
        guard viewIfLoaded?.window != nil else { return }

        guard let requestID = latestState.requestID,
              latestState.isFreshResponse(for: requestID) else {
            refreshUI()
            return
        }

        if automatically {
            guard keyboardVisible,
                  mayAutoInsert,
                  currentRequestID == requestID else {
                refreshUI()
                return
            }
        }

        guard let text = latestState.transcribedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refreshUI()
            return
        }

        let beforeContextCount = textDocumentProxy.documentContextBeforeInput?.utf16.count
        let beforeHasText = textDocumentProxy.hasText

        // Exactly one physical insertion call for this result.
        textDocumentProxy.insertText(text)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let afterContextCount = self.textDocumentProxy.documentContextBeforeInput?.utf16.count
            let afterHasText = self.textDocumentProxy.hasText

            let changedCount: Bool
            if let beforeContextCount, let afterContextCount {
                changedCount = beforeContextCount != afterContextCount
            } else {
                changedCount = true
            }

            let likelySucceeded =
                (!beforeHasText && afterHasText)
                || changedCount
                || beforeContextCount == nil
                || afterContextCount == nil

            if likelySucceeded {
                self.currentRequestID = nil
                self.mayAutoInsert = false
                self.insertionScheduledForRequestID = nil

                self.latestState = BridgeState(
                    serverID: self.latestState.serverID,
                    revision: self.latestState.revision &+ 1,
                    serviceReady: self.latestState.serviceReady,
                    quickDictationEnabled: self.latestState.quickDictationEnabled,
                    backgroundWakeReady: self.latestState.backgroundWakeReady,
                    microphoneReady: self.latestState.microphoneReady,
                    requestClaimed: false,
                    status: .idle,
                    failureKind: nil,
                    retryAvailable: false,
                    requestID: nil,
                    transcribedText: nil,
                    resultCreatedAt: nil,
                    lastError: nil,
                    interfaceLanguage: self.latestState.interfaceLanguage
                )

                self.statusLabel.text = self.localized("已插入", "Inserted")
                self.sendCommand(.acknowledgeResult, requestID: requestID)
            } else {
                self.statusLabel.text = self.localized(
                    "自动插入失败 · 点“插入结果”可再试",
                    "Auto-insert failed · tap Insert Result to retry"
                )
            }
        }
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        latestState.interfaceLanguage == "en" ? english : chinese
    }
}
