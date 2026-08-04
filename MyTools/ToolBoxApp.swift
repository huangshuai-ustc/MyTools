import SwiftUI

@main
struct ToolBoxApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(StockRefreshAppDelegate.self)
    private var appDelegate
#endif
    @StateObject private var moduleSettings: ToolModuleSettings
    @StateObject private var store: AppStore
    @StateObject private var auth = AuthManager()
    @StateObject private var stockAppearanceSettings = StockAppearanceSettings()
    @AppStorage(AppStorageKey.appearanceMode) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppStorageKey.fontSize) private var fontSizeRawValue = AppFontSize.system.rawValue

    init() {
        let moduleSettings = ToolModuleSettings()
        _moduleSettings = StateObject(wrappedValue: moduleSettings)
        let store = AppStore(moduleSettings: moduleSettings)
        _store = StateObject(wrappedValue: store)
        moduleSettings.setVisibilityChangeHandler { [weak store] module, isVisible in
            store?.moduleVisibilityChanged(module, isVisible: isVisible)
        }
        StockRefreshCoordinator.shared.attach(store: store, moduleSettings: moduleSettings)
    }

    var body: some Scene {
        WindowGroup {
            ConfiguredRootView(
                store: store,
                auth: auth,
                moduleSettings: moduleSettings,
                stockAppearanceSettings: stockAppearanceSettings,
                appearanceModeRawValue: appearanceModeRawValue,
                fontSizeRawValue: fontSizeRawValue
            )
        }
    }
}

private struct ConfiguredRootView: View {
    let store: AppStore
    let auth: AuthManager
    let moduleSettings: ToolModuleSettings
    let stockAppearanceSettings: StockAppearanceSettings
    let appearanceModeRawValue: String
    let fontSizeRawValue: String
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize

    var body: some View {
        RootView()
            .environmentObject(store)
            .environmentObject(auth)
            .environmentObject(moduleSettings)
            .environmentObject(stockAppearanceSettings)
            .environmentObject(AppNotificationService.shared)
            .preferredColorScheme(
                AppAppearanceMode(rawValue: appearanceModeRawValue)?.colorScheme
                    ?? AppAppearanceMode.system.colorScheme
            )
            .environment(\.dynamicTypeSize, resolvedDynamicTypeSize)
            .appListSpacing()
    }

    private var resolvedDynamicTypeSize: DynamicTypeSize {
        AppFontSize(rawValue: fontSizeRawValue)?.dynamicTypeSize
            ?? systemDynamicTypeSize
    }
}
