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
                    model.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        model.appBecameActive()
                    }
                }
        }
    }
}
