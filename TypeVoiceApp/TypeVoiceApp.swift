import SwiftUI

@main
struct TypeVoiceApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    Task {
                        await model.handleIncomingURL(url)
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .active:
                        model.appBecameActive()
                    case .background:
                        model.appEnteredBackground()
                    default:
                        break
                    }
                }
        }
    }
}
