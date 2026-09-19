import SwiftUI

struct ColdStartMicLink: View {
    let isEnglish: Bool

    private var destination: URL {
        URL(string: "typevoice://prepare?source=keyboard")!
    }

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
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
                ? "Open TypeVoice and prepare voice dictation"
                : "打开 TypeVoice 并准备语音输入"
        )
    }
}
