import SwiftUI

struct ColdStartMicLink: View {
    enum Mode {
        case speak
        case recover
        case enable
    }

    let isEnglish: Bool
    let hostBundleID: String?
    let requestID: String
    var mode: Mode = .speak
    var onActivate: (() -> Void)? = nil

    private var destination: URL {
        var components = URLComponents()
        components.scheme = "typevoice"
        components.host = "prepare"

        let autostart = mode == .enable ? "0" : "1"

        var items = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "autostart", value: autostart),
            URLQueryItem(name: "request", value: requestID)
        ]

        if let hostBundleID, !hostBundleID.isEmpty {
            items.append(URLQueryItem(name: "host", value: hostBundleID))
        }

        components.queryItems = items
        return components.url!
    }

    private var title: String {
        switch mode {
        case .speak:
            return isEnglish ? "Speak" : "开始语音"
        case .recover:
            return isEnglish ? "Open TypeVoice to Recover" : "打开 TypeVoice 恢复"
        case .enable:
            return isEnglish ? "Open TypeVoice to Enable" : "打开 TypeVoice 开启快速语音"
        }
    }

    private var symbol: String {
        switch mode {
        case .speak:
            return "mic"
        case .recover:
            return "arrow.up.forward.app"
        case .enable:
            return "app.badge.checkmark"
        }
    }

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                Text(title)
                    .font(.system(size: mode == .speak ? 18 : 17, weight: .semibold))
            }
            .foregroundStyle(mode == .speak ? Color.blue : Color.orange)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        (mode == .speak ? Color.blue : Color.orange)
                            .opacity(0.14)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture().onEnded {
                onActivate?()
            }
        )
        .accessibilityLabel(
            mode == .recover
                ? (isEnglish ? "Open TypeVoice and restore microphone standby" : "打开 TypeVoice 恢复麦克风待机")
                : mode == .enable
                    ? (isEnglish ? "Open TypeVoice and enable Quick Dictation" : "打开 TypeVoice 并开启快速语音")
                    : (isEnglish ? "Open TypeVoice briefly and start recording" : "短暂打开 TypeVoice 并立即开始录音")
        )
    }
}
