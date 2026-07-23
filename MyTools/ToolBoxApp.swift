import SwiftUI

@main
struct ToolBoxApp: App {
    @StateObject private var store = CardStore()
    @StateObject private var auth = AuthManager()
    @StateObject private var moduleSettings = ToolModuleSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(auth)
                .environmentObject(moduleSettings)
        }
    }
}
