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

    private var heartbeatTask: Task<Void, Never>?
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

        guard latestState.serviceReady else {
            openContainingApp()
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
            break

        default:
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
            arrangedSubviews: [globeButton, spaceButton, deleteButton, returnButton]
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
                      self.viewIfLoaded?.window != nil,
                      !self.latestState.serviceReady
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

                if action == .startRecording {
                    self.openContainingApp()
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
            status: .starting,
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
            statusLabel.text = localized(
                "已待命 · 点击麦克风直接说",
                "Ready · tap the microphone"
            )
            micButton.setTitle(
                localized("🎙 开始语音", "🎙 Speak"),
                for: .normal
            )
            micButton.backgroundColor = .systemBlue.withAlphaComponent(0.14)

        case .starting:
            statusLabel.text = localized(
                "正在连接录音服务…",
                "Connecting to recorder…"
            )
            micButton.setTitle(
                localized("正在启动…", "Starting…"),
                for: .normal
            )
            micButton.backgroundColor = .systemGray.withAlphaComponent(0.18)

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
                "正在识别…",
                "Transcribing…"
            )
            micButton.setTitle(
                localized("识别中…", "Transcribing…"),
                for: .normal
            )
            micButton.backgroundColor = .systemGray.withAlphaComponent(0.18)

        case .polishing:
            statusLabel.text = localized(
                "正在整理表达…",
                "Cleaning up…"
            )
            micButton.setTitle(
                localized("整理中…", "Cleaning…"),
                for: .normal
            )
            micButton.backgroundColor = .systemGray.withAlphaComponent(0.18)

        case .completed:
            break

        case .error:
            statusLabel.text = latestState.lastError ?? localized(
                "语音处理失败",
                "Dictation failed"
            )
            micButton.setTitle(
                localized("🎙 再试一次", "🎙 Try Again"),
                for: .normal
            )
            micButton.backgroundColor = .systemOrange.withAlphaComponent(0.18)
        }

        spaceButton.setTitle(localized("空格", "Space"), for: .normal)
    }

    private func openContainingApp() {
        var components = URLComponents()
        components.scheme = "typevoice"
        components.host = "prepare"
        let requestID = coldStartRequestID ?? UUID().uuidString
        coldStartRequestID = requestID

        var items = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "autostart", value: "1"),
            URLQueryItem(name: "request", value: requestID)
        ]
        if let hostBundleID, !hostBundleID.isEmpty {
            items.append(URLQueryItem(name: "host", value: hostBundleID))
        }
        components.queryItems = items

        guard let url = components.url else {
            statusLabel.text = localized(
                "无法打开 TypeVoice",
                "Could not open TypeVoice"
            )
            return
        }

        statusLabel.text = localized(
            "正在打开 TypeVoice 准备麦克风…",
            "Opening TypeVoice to prepare the microphone…"
        )

        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }

                if !success {
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
                    status: .idle,
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
