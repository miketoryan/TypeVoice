import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    @AppStorage(SharedKeys.interfaceLanguage, store: SharedStore.defaults)
    private var languageRaw = TypeVoiceLanguage.chinese.rawValue

    @AppStorage(SharedKeys.quickMinutes, store: SharedStore.defaults)
    private var quickMinutes = 10

    private var isChinese: Bool {
        languageRaw != TypeVoiceLanguage.english.rawValue
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    if model.isChatGPTLoggedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(text("已登录 ChatGPT", "Signed in to ChatGPT"))
                                    .font(.headline)
                                if let summary = model.chatGPTAccountSummary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Button(role: .destructive) {
                            model.logoutChatGPT()
                        } label: {
                            Text(text("退出 ChatGPT", "Sign out of ChatGPT"))
                        }
                    } else if model.isLoggingIn {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(text("使用下面的验证码完成 ChatGPT 登录", "Use this code to finish ChatGPT sign-in"))
                                .font(.subheadline)

                            if let code = model.loginCode {
                                Text(code)
                                    .font(.system(.title2, design: .monospaced).weight(.bold))
                                    .textSelection(.enabled)

                                Button {
                                    UIPasteboard.general.string = code
                                } label: {
                                    Label(text("复制验证码", "Copy code"), systemImage: "doc.on.doc")
                                }
                            }

                            if let url = model.loginURL {
                                Button {
                                    openURL(url)
                                } label: {
                                    Label(text("打开 ChatGPT 登录页", "Open ChatGPT sign-in"), systemImage: "safari")
                                }
                            }

                            HStack {
                                ProgressView()
                                Text(text("正在等待授权…", "Waiting for authorization…"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Button(role: .cancel) {
                                model.cancelChatGPTLogin()
                            } label: {
                                Text(text("取消登录", "Cancel sign-in"))
                            }
                        }
                    } else {
                        Button {
                            model.startChatGPTLogin()
                        } label: {
                            Label(text("登录 ChatGPT", "Sign in with ChatGPT"), systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                } header: {
                    Text(text("ChatGPT 账号", "ChatGPT account"))
                } footer: {
                    Text(text(
                        "TypeVoice 不需要 OpenAI API Key。登录使用 Codex 的 ChatGPT 设备授权流程，登录凭据保存在本机 Keychain，并自动刷新。",
                        "TypeVoice does not require an OpenAI API key. It uses Codex ChatGPT device authorization, stores credentials in the device Keychain, and refreshes them automatically."
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

                    Button(model.isServiceReady ? text("关闭快速语音", "Disable Quick Dictation") : text("开启快速语音", "Enable Quick Dictation")) {
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
                        "快速语音开启后，TypeVoice 会保持麦克风待命。后台服务就绪时，从键盘点击麦克风不会跳离当前 App。",
                        "When Quick Dictation is enabled, TypeVoice keeps the microphone service warm. A keyboard mic tap stays in the current app while the service is ready."
                    ))
                }

                Section {
                    Picker(text("界面语言", "Interface language"), selection: $languageRaw) {
                        Text("中文").tag(TypeVoiceLanguage.chinese.rawValue)
                        Text("English").tag(TypeVoiceLanguage.english.rawValue)
                    }

                    Picker(text("待命时长", "Ready window"), selection: $quickMinutes) {
                        Text(text("10 分钟", "10 minutes")).tag(10)
                        Text(text("20 分钟", "20 minutes")).tag(20)
                        Text(text("60 分钟", "60 minutes")).tag(60)
                    }
                } header: {
                    Text(text("使用设置", "Usage"))
                } footer: {
                    Text(text(
                        "这里的中文/English 只控制界面显示，不控制语音识别语言。识别会自动判断中文、英文或中英混说。",
                        "This Chinese/English option changes only the interface. Speech language is detected automatically, including mixed Chinese and English."
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
                        Text(text("键盘使用方式", "Keyboard flow"))
                            .font(.headline)
                        Text(text(
                            "1. 登录 ChatGPT。\n2. 在系统设置中添加 TypeVoice 键盘并开启“允许完全访问”。\n3. 在这里开启快速语音。\n4. 回到任意输入框，切换到 TypeVoice。\n5. 点击麦克风开始，再点一次结束。\n6. ChatGPT 识别和整理完成后，文字自动插入当前光标。",
                            "1. Sign in with ChatGPT.\n2. Add the TypeVoice keyboard in iOS Settings and enable Full Access.\n3. Enable Quick Dictation here.\n4. Return to any text field and switch to TypeVoice.\n5. Tap the microphone to start and tap again to stop.\n6. After ChatGPT transcribes and cleans the speech, the text is inserted automatically at the cursor."
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
            return text("如果这是冷启动，请滑回刚才的 App 继续说话。", "If this was a cold start, swipe back to the previous app and keep speaking.")
        case .transcribing, .polishing:
            return text("完成后会自动插入当前输入框。", "The result will be inserted automatically.")
        case .ready:
            return text("从键盘启动时无需跳转 TypeVoice。", "Keyboard dictation can start without switching apps.")
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
