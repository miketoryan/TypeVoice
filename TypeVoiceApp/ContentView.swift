import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(SharedKeys.interfaceLanguage, store: SharedStore.defaults)
    private var languageRaw = TypeVoiceLanguage.chinese.rawValue

    @AppStorage(SharedKeys.quickMinutes, store: SharedStore.defaults)
    private var quickMinutes = 10

    @AppStorage(SharedKeys.apiBaseURL, store: SharedStore.defaults)
    private var apiBaseURL = "https://api.openai.com/v1"

    @AppStorage(SharedKeys.transcriptionModel, store: SharedStore.defaults)
    private var transcriptionModel = "gpt-transcribe"

    @AppStorage(SharedKeys.cleanupModel, store: SharedStore.defaults)
    private var cleanupModel = "gpt-5.6-luna"

    @State private var apiKeyDraft = ""
    @State private var showAdvanced = false

    private var isChinese: Bool {
        languageRaw != TypeVoiceLanguage.english.rawValue
    }

    var body: some View {
        NavigationView {
            Form {
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
                    .disabled(model.status == .recording || model.status == .transcribing || model.status == .polishing)
                } header: {
                    Text(text("状态", "Status"))
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

                Section {
                    SecureField(text("OpenAI API Key", "OpenAI API Key"), text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(model.apiKeyConfigured ? text("更新 API Key", "Update API Key") : text("保存 API Key", "Save API Key")) {
                        model.saveAPIKey(apiKeyDraft)
                        apiKeyDraft = ""
                    }
                } header: {
                    Text(text("AI 服务", "AI service"))
                } footer: {
                    Text(model.apiKeyConfigured
                         ? text("API Key 已保存在本机 Keychain。", "The API key is stored in the device Keychain.")
                         : text("ChatGPT Plus 不包含 API 调用额度，需要单独的 OpenAI API Key。", "ChatGPT Plus does not include API usage; an OpenAI API key is required."))
                }

                Section {
                    DisclosureGroup(text("高级设置", "Advanced"), isExpanded: $showAdvanced) {
                        TextField("API Base URL", text: $apiBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField(text("转录模型", "Transcription model"), text: $transcriptionModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField(text("整理模型", "Cleanup model"), text: $cleanupModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
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
                            "1. 在系统设置中添加 TypeVoice 键盘并开启“允许完全访问”。\n2. 在这里开启快速语音。\n3. 回到任意输入框，切换到 TypeVoice。\n4. 点击麦克风开始，再点一次结束。\n5. 识别和整理完成后文字自动插入当前光标。",
                            "1. Add the TypeVoice keyboard in iOS Settings and enable Full Access.\n2. Enable Quick Dictation here.\n3. Return to any text field and switch to TypeVoice.\n4. Tap the microphone to start and tap again to stop.\n5. The cleaned transcript is inserted automatically at the cursor."
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
        switch model.status {
        case .recording:
            return text("如果这是冷启动，请滑回刚才的 App 继续说话。", "If this was a cold start, swipe back to the previous app and keep speaking.")
        case .transcribing, .polishing:
            return text("完成后会自动插入当前输入框。", "The result will be inserted automatically.")
        case .ready:
            return text("从键盘启动时无需跳转 TypeVoice。", "Keyboard dictation can start without switching apps.")
        default:
            return text("先配置 API Key 并开启快速语音。", "Configure the API key and enable Quick Dictation.")
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
