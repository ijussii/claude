import SwiftUI

@main
struct AnonApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.calls)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.appBecameActive() }
                }
        }
    }
}
