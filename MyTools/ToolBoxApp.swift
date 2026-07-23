import SwiftUI

@main
struct ToolBoxApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var auth = AuthManager()
    @StateObject private var moduleSettings = ToolModuleSettings()
    @StateObject private var stockAppearanceSettings = StockAppearanceSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(auth)
                .environmentObject(moduleSettings)
                .environmentObject(stockAppearanceSettings)
        }
    }
}
