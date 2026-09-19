import UIKit

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    private var observations: [DarwinObservation] = []
    private var pollTimer: Timer?
    private var launchFallback: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        installObservers()
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        startPolling()
        DispatchQueue.main.async { [weak self] in
            self?.insertPendingResultIfNeeded()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPolling()
        launchFallback?.cancel()
        launchFallback = nil
    }

    deinit {
        stopPolling()
        launchFallback?.cancel()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refresh()
    }

    @objc private func microphoneTapped() {
        guard hasFullAccess else {
            setStatus(localized("请开启“允许完全访问”", "Enable Full Access"))
            return
        }

        let status = SharedStore.status

        if status == .recording {
            launchFallback?.cancel()
            launchFallback = nil
            setStatus(localized("正在结束…", "Finishing…"))
            DarwinBus.post(.stopRecording)
            return
        }

        if status == .transcribing || status == .polishing || status == .starting {
            setStatus(statusText(for: status))
            return
        }

        let requestID = SharedStore.createStartRequest()
        SharedStore.setError(nil)

        if SharedStore.isServiceReady() {
            SharedStore.status = .starting
            setStatus(localized("正在启动…", "Starting…"))
            DarwinBus.post(.startRecording)
            DarwinBus.post(.statusChanged)
            scheduleColdStartFallback(requestID: requestID)
        } else {
            openContainingApp(requestID: requestID)
        }
    }

    @objc private func globeTapped() {
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
        view.backgroundColor = UIColor.secondarySystemBackground

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        micButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        micButton.layer.cornerRadius = 24
        micButton.addTarget(self, action: #selector(microphoneTapped), for: .touchUpInside)

        configureUtilityButton(globeButton, title: "🌐", action: #selector(globeTapped))
        configureUtilityButton(deleteButton, title: "⌫", action: #selector(deleteTapped))
        configureUtilityButton(returnButton, title: "↵", action: #selector(returnTapped))
        configureUtilityButton(spaceButton, title: localized("空格", "Space"), action: #selector(spaceTapped))

        let utilityRow = UIStackView(arrangedSubviews: [globeButton, spaceButton, deleteButton, returnButton])
        utilityRow.axis = .horizontal
        utilityRow.spacing = 8
        utilityRow.distribution = .fillProportionally

        let root = UIStackView(arrangedSubviews: [statusLabel, micButton, utilityRow])
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
            micButton.heightAnchor.constraint(equalToConstant: 54),
            utilityRow.heightAnchor.constraint(equalToConstant: 44),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])

        updateMicAppearance()
    }

    private func configureUtilityButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = UIColor.tertiarySystemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func installObservers() {
        observations = [
            DarwinBus.observe(.statusChanged) { [weak self] in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            },
            DarwinBus.observe(.serviceChanged) { [weak self] in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            },
            DarwinBus.observe(.resultReady) { [weak self] in
                DispatchQueue.main.async {
                    self?.refresh()
                    self?.insertPendingResultIfNeeded()
                }
            }
        ]
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.insertPendingResultIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        let status = SharedStore.status
        setStatus(statusText(for: status))
        updateMicAppearance()

        if status == .recording {
            launchFallback?.cancel()
            launchFallback = nil
        }

        spaceButton.setTitle(localized("空格", "Space"), for: .normal)
    }

    private func updateMicAppearance() {
        let recording = SharedStore.status == .recording
        micButton.setTitle(
            recording ? localized("■ 结束语音", "■ Stop") : localized("🎙 开始语音", "🎙 Speak"),
            for: .normal
        )
        micButton.backgroundColor = recording
            ? UIColor.systemRed.withAlphaComponent(0.16)
            : UIColor.systemBlue.withAlphaComponent(0.14)
        micButton.tintColor = recording ? .systemRed : .systemBlue
    }

    private func statusText(for status: TypeVoiceStatus) -> String {
        if !hasFullAccess {
            return localized("TypeVoice 需要“允许完全访问”", "TypeVoice needs Full Access")
        }

        switch status {
        case .idle:
            return SharedStore.isServiceReady()
                ? localized("已待命", "Ready")
                : localized("未待命：首次点击可能打开 TypeVoice", "Not ready: first tap may open TypeVoice")
        case .ready:
            return localized("已待命 · 点击麦克风直接说", "Ready · tap the microphone")
        case .starting:
            return localized("正在连接录音服务…", "Connecting to recorder…")
        case .recording:
            return localized("正在录音 · 再点一次结束", "Recording · tap again to stop")
        case .transcribing:
            return localized("正在识别…", "Transcribing…")
        case .polishing:
            return localized("正在整理表达…", "Cleaning up…")
        case .failed:
            return SharedStore.lastError ?? localized("出现问题，请打开 TypeVoice 查看", "Something went wrong. Open TypeVoice.")
        }
    }

    private func scheduleColdStartFallback(requestID: UUID) {
        launchFallback?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard SharedStore.pendingStartRequestID == requestID else { return }
            guard SharedStore.status != .recording else { return }
            self.openContainingApp(requestID: requestID)
        }

        launchFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func openContainingApp(requestID: UUID) {
        launchFallback?.cancel()
        launchFallback = nil

        guard let url = URL(string: "typevoice://prepare?source=keyboard&request=\(requestID.uuidString)") else {
            setStatus(localized("无法打开 TypeVoice", "Could not open TypeVoice"))
            return
        }

        setStatus(localized("正在准备麦克风…", "Preparing microphone…"))
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                if !success {
                    self?.setStatus(self?.localized(
                        "请手动打开 TypeVoice 开启快速语音",
                        "Open TypeVoice manually and enable Quick Dictation"
                    ) ?? "Open TypeVoice")
                }
            }
        }
    }

    private func insertPendingResultIfNeeded() {
        guard viewIfLoaded?.window != nil else { return }
        guard let result = SharedStore.pendingResult() else { return }
        guard !SharedStore.wasResultAttempted(result.id) else { return }

        SharedStore.markResultAttempted(result.id)

        let beforeContextCount = textDocumentProxy.documentContextBeforeInput?.utf16.count
        let beforeHasText = textDocumentProxy.hasText

        // One physical insertion attempt only. Automatic retries can duplicate text
        // when iOS reports a stale or truncated context window.
        textDocumentProxy.insertText(result.text)

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
                SharedStore.markResultInserted(result.id)
                self.setStatus(self.localized("已插入", "Inserted"))
            } else {
                SharedStore.setError(self.localized(
                    "识别完成，但当前输入框拒绝了自动插入。",
                    "Transcription finished, but the current text field rejected insertion."
                ))
                self.setStatus(self.localized("自动插入失败", "Auto-insert failed"))
            }
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.text = text
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        SharedStore.interfaceLanguage == .english ? english : chinese
    }
}
