import SwiftUI

struct ColdStartMicLink: View {
    let isEnglish: Bool
    let hostBundleID: String?
    let requestID: String

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

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 21, weight: .semibold))
                Text(isEnglish ? "Speak" : "开始语音")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(Color.blue)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.blue.opacity(0.14))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isEnglish
                ? "Open TypeVoice briefly and start recording"
                : "短暂打开 TypeVoice 并立即开始录音"
        )
    }
}
