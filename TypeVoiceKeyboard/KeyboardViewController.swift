import SwiftUI
import UIKit

@MainActor
private final class RecoveryURLLauncher: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let url: URL
    }

    @Published var request: Request?

    func open(_ url: URL) {
        request = Request(url: url)
    }
}

private struct RecoveryURLLauncherView: View {
    @ObservedObject var launcher: RecoveryURLLauncher
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
    private var coldStartHost: UIHostingController<ColdStartMicLink>?
    private let recoveryURLLauncher = RecoveryURLLauncher()
    private var recoveryURLLauncherHost: UIHostingController<RecoveryURLLauncherView>?

    private let bridge = LocalBridgeClient()

    private var latestState = BridgeState.unavailable()
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var insertionScheduledForRequestID: String?
    private var hostBundleID: String?
    private var coldStartRequestID: String?
    private var foregroundRecoveryRequestID: String?

    private var heartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var startFallbackTask: Task<Void, Never>?
    private var hostResolveTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        hostBundleID = HostApplicationResolver.lastCaptured
        coldStartRequestID = hostBundleID == nil ? nil : UUID().uuidString
        startBridgeTasks()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resolveHostApplicationWithRetries()
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboardVisible = false
        mayAutoInsert = false
        insertionScheduledForRequestID = nil
        stopBridgeTasks()
        startFallbackTask?.cancel()
        startFallbackTask = nil
        hostResolveTask?.cancel()
        hostResolveTask = nil
        HostApplicationResolver.invalidate()
        hostBundleID = nil
        coldStartRequestID = nil
        super.viewWillDisappear(animated)
    }

    deinit {
        heartbeatTask?.cancel()
        pollingTask?.cancel()
        commandTask?.cancel()
        startFallbackTask?.cancel()
        hostResolveTask?.cancel()
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

        switch latestState.status {
        case .recording:
            mayAutoInsert = true
            sendCommand(
                .stopRecording,
                requestID: latestState.requestID ?? currentRequestID
            )

        case .starting, .transcribing, .polishing:
            // A second tap is always an escape hatch. This makes a stuck
            // recognition request immediately cancelable from the keyboard.
            sendCommand(
                .cancelRecording,
                requestID: latestState.requestID ?? currentRequestID
            )

        case .error:
            switch latestState.failureKind {
            case .transcriptionRecoverable
                where latestState.retryAvailable:
                sendCommand(
                    .retryProcessing,
                    requestID: latestState.requestID ?? currentRequestID
                )

            case .audioStartFailed, .bridgeUnavailable:
                if let requestID = latestState.requestID ?? currentRequestID {
                    launchForegroundRecovery(requestID: requestID)
                } else {
                    startRecordingRequest()
                }

            case .authRequired:
                if let requestID = latestState.requestID ?? currentRequestID {
                    launchForegroundRecovery(requestID: requestID)
                }

            default:
                startRecordingRequest()
            }

        default:
            // Do not gate this on backgroundWakeReady. The app gets the first
            // chance to claim the request; foreground launch is a fallback only.
            startRecordingRequest()
        }
    }

    @objc private func globeTapped() {
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

        // Cold start is intentionally a real SwiftUI Link, not a programmatic
        // extensionContext.open call. Dictus/Open Voice Typer use this pattern
        // because a user-tapped Link can launch the containing app even when
        // the keyboard's process cannot reliably do so from a button callback.
        let coldHost = UIHostingController(
            rootView: ColdStartMicLink(
                isEnglish: latestState.interfaceLanguage == "en",
                hostBundleID: hostBundleID,
                requestID: coldStartRequestID ?? UUID().uuidString
            )
        )
        coldHost.view.translatesAutoresizingMaskIntoConstraints = false
        coldHost.view.backgroundColor = .clear
        coldHost.view.isHidden = true
        addChild(coldHost)
        micContainer.addSubview(coldHost.view)
        NSLayoutConstraint.activate([
            coldHost.view.leadingAnchor.constraint(equalTo: micContainer.leadingAnchor),
            coldHost.view.trailingAnchor.constraint(equalTo: micContainer.trailingAnchor),
            coldHost.view.topAnchor.constraint(equalTo: micContainer.topAnchor),
            coldHost.view.bottomAnchor.constraint(equalTo: micContainer.bottomAnchor)
        ])
        coldHost.didMove(toParent: self)
        coldStartHost = coldHost

        // Invisible SwiftUI openURL bridge used only when a warm background
        // microphone recovery fails. The normal cold-start button remains the
        // existing user-tapped ColdStartMicLink above.
        let recoveryHost = UIHostingController(
            rootView: RecoveryURLLauncherView(launcher: recoveryURLLauncher)
        )
        recoveryHost.view.translatesAutoresizingMaskIntoConstraints = false
        recoveryHost.view.backgroundColor = .clear
        recoveryHost.view.isUserInteractionEnabled = false
        addChild(recoveryHost)
        view.addSubview(recoveryHost.view)
        NSLayoutConstraint.activate([
            recoveryHost.view.widthAnchor.constraint(equalToConstant: 1),
            recoveryHost.view.heightAnchor.constraint(equalToConstant: 1),
            recoveryHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            recoveryHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        recoveryHost.didMove(toParent: self)
        recoveryURLLauncherHost = recoveryHost
    }

    private func resolveHostApplicationWithRetries() {
        hostResolveTask?.cancel()

        hostResolveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // The arbiter hook may already have observed the current host before
            // viewDidAppear. Use it immediately, then confirm with fresh checks.
            if let cached = HostApplicationResolver.lastCaptured {
                self.hostBundleID = cached
                if self.coldStartRequestID == nil {
                    self.coldStartRequestID = UUID().uuidString
                }
                self.refreshUI()
            }

            for _ in 0..<20 {
                guard !Task.isCancelled,
                      self.keyboardVisible,
                      self.viewIfLoaded?.window != nil
                else {
                    return
                }

                if let bundleID = HostApplicationResolver.resolve(from: self) {
                    self.hostBundleID = bundleID
                    if self.coldStartRequestID == nil {
                        self.coldStartRequestID = UUID().uuidString
                    }
                    self.refreshUI()
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            }

            // Do not send a host-less cold-start URL. That is exactly the v0.7
            // failure mode: TypeVoice starts successfully but has nowhere to
            // return. Leave the mic disabled and explain the state instead.
            self.hostBundleID = nil
            self.coldStartRequestID = nil
            self.refreshUI()
        }
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

    private func startBridgeTasks() {
        stopBridgeTasks()

        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.sendHeartbeat()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: LocalBridge.keyboardHeartbeatInterval)
                } catch {
                    return
                }
                await self.sendHeartbeat()
            }
        }

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.fetchState()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    return
                }
                await self.fetchState()
            }
        }
    }

    private func stopBridgeTasks() {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        pollingTask?.cancel()
        pollingTask = nil
    }

    private func sendHeartbeat() async {
        guard keyboardVisible else { return }

        do {
            let state = try await bridge.send(.heartbeat)
            apply(state)
        } catch {
            applyConnectionFailure()
        }
    }

    private func fetchState() async {
        guard keyboardVisible else { return }

        do {
            let state = try await bridge.fetchState()
            apply(state)
        } catch {
            applyConnectionFailure()
        }
    }

    private func sendCommand(_ action: BridgeAction, requestID: String?) {
        commandTask?.cancel()

        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let state = try await self.bridge.send(
                    action,
                    requestID: requestID
                )
                self.apply(state)
            } catch {
                self.latestState = .unavailable(
                    self.localized(
                        "TypeVoice 后台服务没有响应。",
                        "TypeVoice background service did not respond."
                    ),
                    interfaceLanguage: self.latestState.interfaceLanguage
                )
                self.refreshUI()
            }
        }
    }

    private func sendStartRecordingWithClaimFallback(requestID: String) {
        commandTask?.cancel()
        startFallbackTask?.cancel()

        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let state = try await self.bridge.send(
                    .startRecording,
                    requestID: requestID,
                    timeoutInterval: 1.0
                )
                self.apply(state)

                if state.requestID == requestID,
                   state.requestClaimed {
                    return
                }
            } catch {
                // Do not foreground immediately. The containing app may have
                // received and claimed the request even if this HTTP response
                // was lost or delayed.
            }

            self.startClaimFallbackWindow(requestID: requestID)
        }
    }

    private func startClaimFallbackWindow(requestID: String) {
        startFallbackTask?.cancel()

        startFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let deadline = Date().addingTimeInterval(1.5)

            while !Task.isCancelled,
                  Date() < deadline,
                  self.keyboardVisible,
                  self.currentRequestID == requestID {
                if self.latestState.requestID == requestID,
                   self.latestState.requestClaimed {
                    return
                }

                do {
                    let state = try await self.bridge.fetchState(
                        timeoutInterval: 0.25
                    )
                    self.apply(state)

                    if state.requestID == requestID,
                       state.requestClaimed {
                        return
                    }
                } catch {
                    // Keep the short claim window open. A single missed local
                    // request is not enough evidence to disrupt the user.
                }

                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  self.keyboardVisible,
                  self.currentRequestID == requestID else {
                return
            }

            if self.latestState.requestID == requestID,
               self.latestState.requestClaimed {
                return
            }

            self.launchForegroundRecovery(requestID: requestID)
        }
    }

    private func startRecordingRequest() {
        let requestID = UUID().uuidString
        currentRequestID = requestID
        mayAutoInsert = true
        insertionScheduledForRequestID = nil

        latestState = BridgeState(
            serverID: latestState.serverID,
            revision: latestState.revision &+ 1,
            serviceReady: true,
            backgroundWakeReady: latestState.backgroundWakeReady,
            microphoneReady: latestState.microphoneReady,
            requestClaimed: false,
            status: .starting,
            failureKind: nil,
            retryAvailable: false,
            requestID: requestID,
            transcribedText: nil,
            resultCreatedAt: nil,
            lastError: nil,
            interfaceLanguage: latestState.interfaceLanguage
        )

        refreshUI()
        sendStartRecordingWithClaimFallback(requestID: requestID)
    }

    private func apply(_ state: BridgeState) {
        if state.serverID == latestState.serverID,
           state.revision < latestState.revision {
            return
        }

        latestState = state

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

        if state.requestClaimed,
           let requestID = state.requestID,
           requestID == currentRequestID {
            startFallbackTask?.cancel()
            startFallbackTask = nil
        }

        if state.status == .recording,
           let requestID = state.requestID,
           requestID == foregroundRecoveryRequestID {
            foregroundRecoveryRequestID = nil
        }

        if state.status == .error,
           let requestID = state.requestID,
           requestID == currentRequestID,
           state.failureKind == .audioStartFailed
            || state.failureKind == .bridgeUnavailable {
            launchForegroundRecovery(requestID: requestID)
            return
        }

        if state.status == .idle,
           state.requestID == nil {
            currentRequestID = nil
            mayAutoInsert = false
            insertionScheduledForRequestID = nil
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
        guard latestState.status != .recording,
              latestState.status != .transcribing,
              latestState.status != .polishing else {
            return
        }

        latestState = .unavailable(
            localized(
                "未连接 TypeVoice：正在准备冷启动。",
                "TypeVoice is not connected. Preparing cold launch."
            ),
            interfaceLanguage: latestState.interfaceLanguage
        )

        if hostBundleID == nil {
            resolveHostApplicationWithRetries()
        }
        refreshUI()
    }

    private func refreshUI() {
        let isColdState = hasFullAccess && !latestState.serviceReady
        let hasReturnTarget = hostBundleID != nil
        let shouldUseColdStartLink = isColdState && hasReturnTarget

        if hostBundleID != nil, coldStartRequestID == nil {
            coldStartRequestID = UUID().uuidString
        }

        coldStartHost?.rootView = ColdStartMicLink(
            isEnglish: latestState.interfaceLanguage == "en",
            hostBundleID: hostBundleID,
            requestID: coldStartRequestID ?? "pending"
        )
        coldStartHost?.view.isHidden = !shouldUseColdStartLink
        micButton.isHidden = shouldUseColdStartLink
        micButton.isUserInteractionEnabled = !isColdState

        guard hasFullAccess else {
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

        guard latestState.serviceReady else {
            if hostBundleID == nil {
                statusLabel.text = localized(
                    "正在识别当前输入应用…",
                    "Identifying the current app…"
                )
                micButton.setTitle(
                    localized("正在准备…", "Preparing…"),
                    for: .normal
                )
                micButton.backgroundColor = .systemGray.withAlphaComponent(0.18)

                if hostResolveTask == nil || hostResolveTask?.isCancelled == true {
                    resolveHostApplicationWithRetries()
                }
            } else {
                statusLabel.text = latestState.lastError ?? localized(
                    "未待命 · 点击麦克风短暂打开 TypeVoice",
                    "Not ready · tap the microphone to briefly open TypeVoice"
                )
                micButton.setTitle(
                    localized("🎙 开始语音", "🎙 Speak"),
                    for: .normal
                )
                micButton.backgroundColor = .systemBlue.withAlphaComponent(0.14)
            }
            return
        }

        switch latestState.status {
        case .idle:
            statusLabel.text = latestState.backgroundWakeReady
                ? localized(
                    "后台已待命 · 点击后启动麦克风",
                    "Ready in background · tap to start the microphone"
                )
                : localized(
                    "后台服务在线 · 点击后直接尝试启动麦克风",
                    "Background service online · tap to start the microphone"
                )
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

            case .audioStartFailed, .bridgeUnavailable:
                micButton.setTitle(
                    localized("打开 TypeVoice 恢复", "Open TypeVoice to Recover"),
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

    private func launchForegroundRecovery(requestID: String) {
        guard foregroundRecoveryRequestID != requestID else { return }
        foregroundRecoveryRequestID = requestID

        Task { @MainActor [weak self] in
            guard let self else { return }

            for _ in 0..<10 {
                if let bundleID = self.hostBundleID
                    ?? HostApplicationResolver.resolve(from: self) {
                    self.hostBundleID = bundleID
                    self.openContainingApp(requestID: requestID)
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
            }

            self.foregroundRecoveryRequestID = nil
            self.statusLabel.text = self.localized(
                "无法确认原输入应用，请再点一次麦克风",
                "Could not identify the original app. Tap the microphone again."
            )
            self.resolveHostApplicationWithRetries()
        }
    }

    private func openContainingApp(requestID: String) {
        guard let hostBundleID, !hostBundleID.isEmpty else {
            foregroundRecoveryRequestID = nil
            statusLabel.text = localized(
                "正在识别当前输入应用…",
                "Identifying the current app…"
            )
            resolveHostApplicationWithRetries()
            return
        }

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
            foregroundRecoveryRequestID = nil
            statusLabel.text = localized(
                "无法打开 TypeVoice",
                "Could not open TypeVoice"
            )
            return
        }

        statusLabel.text = localized(
            "后台恢复失败，正在打开 TypeVoice 激活麦克风…",
            "Background recovery failed. Opening TypeVoice to activate the microphone…"
        )

        // Prefer the same SwiftUI openURL handoff pattern already proven in
        // VoiceKing. This is only a recovery fallback; the normal TypeVoice
        // cold-start button remains the existing user-tapped SwiftUI Link.
        recoveryURLLauncher.open(url)

        // Keep the old extensionContext path as a secondary fallback.
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }

            guard let self,
                  self.keyboardVisible,
                  self.foregroundRecoveryRequestID == requestID else {
                return
            }

            self.extensionContext?.open(url) { [weak self] success in
                DispatchQueue.main.async {
                    guard let self, !success else { return }
                    self.foregroundRecoveryRequestID = nil
                    self.statusLabel.text = self.localized(
                        "请手动打开 TypeVoice 并开启快速语音",
                        "Open TypeVoice manually and enable Quick Dictation"
                    )
                }
            }
        }
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
