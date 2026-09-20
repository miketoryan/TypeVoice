import SwiftUI

struct ColdStartMicLink: View {
    enum Mode {
        case speak
        case recover
    }

    let isEnglish: Bool
    let hostBundleID: String?
    let requestID: String
    var mode: Mode = .speak

    private var destination: URL {
        var components = URLComponents()
        components.scheme = "typevoice"
        components.host = "prepare"

        var items = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "autostart", value: "1"),
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
        }
    }

    private var symbol: String {
        switch mode {
        case .speak:
            return "mic"
        case .recover:
            return "arrow.up.forward.app"
        }
    }

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                Text(title)
                    .font(.system(size: mode == .recover ? 17 : 18, weight: .semibold))
            }
            .foregroundStyle(mode == .recover ? Color.orange : Color.blue)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        (mode == .recover ? Color.orange : Color.blue)
                            .opacity(0.14)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            mode == .recover
                ? (isEnglish ? "Open TypeVoice and restore microphone standby" : "打开 TypeVoice 恢复麦克风待机")
                : (isEnglish ? "Open TypeVoice briefly and start recording" : "短暂打开 TypeVoice 并立即开始录音")
        )
    }
}
