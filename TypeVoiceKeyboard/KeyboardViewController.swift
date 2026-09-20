import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micContainer = UIView()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private var coldStartHost: UIHostingController<ColdStartMicLink>?

    private let bridge = LocalBridgeClient()

    private var latestState = BridgeState.unavailable()
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var insertionScheduledForRequestID: String?
    private var hostBundleID: String?
    private var coldStartRequestID: String?
    private var foregroundHandoffPending = false
    private var lastBridgeSuccessAt: Date?
    private var darwinObservations: [DarwinObservation] = []

    private let readinessLeaseSeconds: TimeInterval = 3

    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var hostResolveTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        foregroundHandoffPending = false
        DarwinBus.post(.keyboardVisible)
        hostBundleID = HostApplicationResolver.lastCaptured
        coldStartRequestID = hostBundleID == nil ? nil : UUID().uuidString
        startDarwinStateObservers()
        startBridgeTasks()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resolveHostApplicationWithRetries()
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
        HostApplicationResolver.invalidate()
        hostBundleID = nil
        coldStartRequestID = nil
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
                if hostBundleID == nil {
                    resolveHostApplicationWithRetries()
                    statusLabel.text = localized(
                        "正在识别当前输入应用…",
                        "Identifying the current app…"
                    )
                } else {
                    // The visible control is a real SwiftUI Link in refreshUI().
                    refreshUI()
                }

            case .authRequired:
                openTypeVoiceForAccountRecovery()

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

        // Cold start is intentionally a real SwiftUI Link, not a programmatic
        // extensionContext.open call. Dictus/Open Voice Typer use this pattern
        // because a user-tapped Link can launch the containing app even when
        // the keyboard's process cannot reliably do so from a button callback.
        let coldHost = UIHostingController(
            rootView: ColdStartMicLink(
                isEnglish: latestState.interfaceLanguage == "en",
                hostBundleID: hostBundleID,
                requestID: coldStartRequestID ?? UUID().uuidString,
                mode: .speak,
                onActivate: { [weak self] in
                    self?.beginForegroundHandoff()
                }
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

            await self.fetchState()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(600))
                } catch {
                    return
                }
                await self.fetchState()
            }
        }
    }

    private func stopBridgeTasks() {
        pollingTask?.cancel()
        pollingTask = nil
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
                        self.applyConnectionFailure()
                        return
                    }
                }
            }
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
        sendCommand(.startRecording, requestID: requestID)
    }

    private func apply(_ state: BridgeState) {
        lastBridgeSuccessAt = Date()

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
        // Like VocaPhone's readiness lease: one missed local request is not
        // enough to declare a warm background service dead.
        if bridgeLeaseIsFresh {
            return
        }

        guard latestState.status != .recording,
              latestState.status != .transcribing,
              latestState.status != .polishing,
              latestState.status != .starting else {
            return
        }

        latestState = .unavailable(
            localized(
                "热麦克风已结束 · 点击会打开 TypeVoice 重新激活",
                "Warm microphone ended · tap to open TypeVoice and reactivate"
            ),
            interfaceLanguage: latestState.interfaceLanguage
        )

        if hostBundleID == nil {
            resolveHostApplicationWithRetries()
        }
        refreshUI()
    }

    private func refreshUI() {
        if hostBundleID != nil, coldStartRequestID == nil {
            coldStartRequestID = UUID().uuidString
        }

        let launchRequestID =
            latestState.requestID
            ?? currentRequestID
            ?? coldStartRequestID

        let hasRecoverableAudioError =
            latestState.status == .error
            && (
                latestState.failureKind == .audioStartFailed
                || latestState.failureKind == .bridgeUnavailable
                || latestState.failureKind == .interrupted
            )

        let isColdState =
            !latestState.serviceReady
            || !latestState.backgroundWakeReady

        let shouldShowForegroundLink =
            hostBundleID != nil
            && launchRequestID != nil
            && (isColdState || hasRecoverableAudioError)

        // If the warm microphone is no longer available, use a real user-tapped
        // SwiftUI Link immediately. We no longer spend 1.5 seconds attempting a
        // background start that iOS cannot complete after the warm input closed.
        // Warm-ready dictation still uses the normal no-switch button.
        coldStartHost?.rootView = ColdStartMicLink(
            isEnglish: latestState.interfaceLanguage == "en",
            hostBundleID: hostBundleID,
            requestID: launchRequestID ?? "pending",
            mode: hasRecoverableAudioError ? .recover : .speak,
            onActivate: { [weak self] in
                self?.beginForegroundHandoff()
            }
        )
        coldStartHost?.view.isHidden = !shouldShowForegroundLink
        micButton.isHidden = shouldShowForegroundLink
        micButton.isUserInteractionEnabled = !shouldShowForegroundLink

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

        switch latestState.status {
        case .idle:
            if latestState.serviceReady && bridgeLeaseIsFresh {
                statusLabel.text = latestState.backgroundWakeReady
                    ? localized(
                        "麦克风热待命 · 可直接语音",
                        "Microphone warm · ready to dictate"
                    )
                    : localized(
                        "TypeVoice 在线 · 麦克风需要重新激活",
                        "TypeVoice is online · microphone needs reactivation"
                    )
            } else {
                statusLabel.text = localized(
                    "麦克风未热启动 · 点击会打开 TypeVoice 激活",
                    "Microphone is cold · tap to open TypeVoice and activate"
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
                    hostBundleID == nil
                        ? localized("正在准备恢复…", "Preparing recovery…")
                        : localized("打开 TypeVoice 恢复", "Open TypeVoice to Recover"),
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

    private func beginForegroundHandoff() {
        foregroundHandoffPending = true
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

        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, !success else { return }
                self.statusLabel.text = self.localized(
                    "请手动打开 TypeVoice 重新登录",
                    "Open TypeVoice manually to sign in again"
                )
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
