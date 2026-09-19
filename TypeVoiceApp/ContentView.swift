import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(SharedKeys.interfaceLanguage, store: SharedStore.defaults)
    private var languageRaw = TypeVoiceLanguage.chinese.rawValue

    @AppStorage(SharedKeys.quickStandbySeconds, store: SharedStore.defaults)
    private var quickStandbySeconds = 60

    private var isChinese: Bool {
        languageRaw != TypeVoiceLanguage.english.rawValue
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text(text("账号", "Account"))
                        Spacer()
                        Text(
                            model.isChatGPTLoggedIn
                                ? (model.chatGPTAccountSummary ?? text("已登录", "Signed in"))
                                : text("未登录", "Not signed in")
                        )
                        .foregroundColor(.secondary)
                    }

                    if model.isChatGPTLoggedIn {
                        Button(role: .destructive) {
                            model.logoutChatGPT()
                        } label: {
                            Text(text("退出登录", "Sign Out"))
                        }
                    } else {
                        Button {
                            model.startChatGPTLogin()
                        } label: {
                            HStack {
                                if model.isLoggingIn {
                                    ProgressView()
                                }
                                Text(
                                    model.isLoggingIn
                                        ? text("正在打开 ChatGPT 登录…", "Opening ChatGPT sign-in…")
                                        : text("使用 ChatGPT 登录", "Sign in with ChatGPT")
                                )
                            }
                        }
                        .disabled(model.isLoggingIn)
                    }
                } header: {
                    Text("ChatGPT")
                } footer: {
                    Text(text(
                        "点击后会直接打开 OpenAI 的 ChatGPT 登录页面。按你平时的方式输入账号密码，或选择 Apple / Google 等已有登录方式；授权成功后会自动返回 TypeVoice，不需要 API Key，也不需要验证码。",
                        "This opens OpenAI's ChatGPT sign-in page directly. Sign in with your normal account method; after authorization you return to TypeVoice automatically. No API key or device code is required."
                    ))
                }

                Section {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle)
                                .font(.headline)
                            Text(statusSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(
                        model.isServiceReady
                            ? text("关闭快速语音", "Disable Quick Dictation")
                            : text("开启快速语音", "Enable Quick Dictation")
                    ) {
                        if model.isServiceReady {
                            model.disarm()
                        } else {
                            Task { await model.arm() }
                        }
                    }
                    .disabled(
                        !model.isChatGPTLoggedIn
                        || model.status == .recording
                        || model.status == .transcribing
                        || model.status == .polishing
                    )
                } header: {
                    Text(text("语音服务", "Voice service"))
                } footer: {
                    Text(text(
                        "快速语音开启后，TypeVoice 会保持后台录音服务待命。服务已就绪时，从键盘点击麦克风不会离开当前 App。",
                        "When Quick Dictation is enabled, TypeVoice keeps its background recording service ready. If ready, tapping the keyboard microphone stays in the current app."
                    ))
                }

                Section {
                    Picker(text("界面语言", "Interface language"), selection: $languageRaw) {
                        Text("中文").tag(TypeVoiceLanguage.chinese.rawValue)
                        Text("English").tag(TypeVoiceLanguage.english.rawValue)
                    }

                    Picker(text("待命时长", "Ready window"), selection: $quickStandbySeconds) {
                        Text(text("10 秒", "10 seconds")).tag(10)
                        Text(text("30 秒", "30 seconds")).tag(30)
                        Text(text("1 分钟", "1 minute")).tag(60)
                        Text(text("5 分钟", "5 minutes")).tag(300)
                    }
                } header: {
                    Text(text("使用设置", "Usage"))
                } footer: {
                    Text(text(
                        "这里的中文/English 只控制界面显示，不控制识别语言。语音识别自动判断中文、英文或中英混说。",
                        "This Chinese/English option only changes the interface. Speech language is detected automatically, including mixed Chinese and English."
                    ))
                }

                if let transcript = model.lastTranscript, !transcript.isEmpty {
                    Section(text("最近一次结果", "Latest result")) {
                        Text(transcript)
                            .textSelection(.enabled)
                    }
                }

                if let error = model.lastError, !error.isEmpty {
                    Section(text("提示", "Message")) {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text("使用步骤", "Setup"))
                            .font(.headline)

                        Text(text(
                            "1. 点击“使用 ChatGPT 登录”，在打开的 OpenAI 页面直接登录并授权。\n2. 在系统设置中添加 TypeVoice 键盘，并开启“允许完全访问”。\n3. 回到 TypeVoice，开启快速语音。\n4. 在任意输入框切换到 TypeVoice。\n5. 点击麦克风开始，再点一次结束。\n6. 识别和整理完成后，文字自动插入当前光标。",
                            "1. Tap Sign in with ChatGPT and complete authorization on OpenAI's sign-in page.\n2. Add the TypeVoice keyboard in iOS Settings and enable Full Access.\n3. Return to TypeVoice and enable Quick Dictation.\n4. Switch to TypeVoice in any text field.\n5. Tap the microphone to start and again to stop.\n6. The cleaned transcript is inserted automatically at the cursor."
                        ))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("TypeVoice")
        }
    }

    private func text(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    private var statusTitle: String {
        switch model.status {
        case .idle:
            return text("未待命", "Not ready")
        case .ready:
            return text("已待命", "Ready")
        case .starting:
            return text("正在启动", "Starting")
        case .recording:
            return text("正在录音", "Recording")
        case .transcribing:
            return text("正在识别", "Transcribing")
        case .polishing:
            return text("正在整理", "Cleaning up")
        case .failed:
            return text("出现问题", "Needs attention")
        }
    }

    private var statusSubtitle: String {
        if !model.isChatGPTLoggedIn {
            return text("先登录 ChatGPT。", "Sign in with ChatGPT first.")
        }

        switch model.status {
        case .recording:
            return text("正在录音，再点一次麦克风结束。", "Recording; tap the microphone again to stop.")
        case .transcribing, .polishing:
            return text("完成后会自动插入当前输入框。", "The result will be inserted automatically.")
        case .ready:
            return text("可以直接从键盘开始语音。", "Ready for keyboard dictation.")
        default:
            return text("开启快速语音后即可使用。", "Enable Quick Dictation to begin.")
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .ready:
            return .green
        case .recording:
            return .red
        case .transcribing, .polishing, .starting:
            return .orange
        case .failed:
            return .red
        case .idle:
            return .gray
        }
    }
}
