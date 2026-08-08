import SwiftUI

#if os(iOS)
import UIKit

@MainActor
enum AppOrientationController {
    private(set) static var supportedOrientations: UIInterfaceOrientationMask = .all

    static func allow(_ orientations: UIInterfaceOrientationMask) {
        supportedOrientations = orientations
    }
}
#endif

@main
struct ToolBoxApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(StockRefreshAppDelegate.self)
    private var appDelegate
#endif
    @StateObject private var moduleSettings: ToolModuleSettings
    @StateObject private var store: AppStore
    @StateObject private var auth = AuthManager()
    @StateObject private var stockAppearanceSettings: StockAppearanceSettings
    @AppStorage(AppStorageKey.appearanceMode) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppStorageKey.fontSize) private var fontSizeRawValue = AppFontSize.system.rawValue

    init() {
        let moduleSettings = ToolModuleSettings()
        let stockAppearanceSettings = StockAppearanceSettings()
        _moduleSettings = StateObject(wrappedValue: moduleSettings)
        _stockAppearanceSettings = StateObject(wrappedValue: stockAppearanceSettings)
        let store = AppStore(
            moduleSettings: moduleSettings,
            stockAppearanceSettings: stockAppearanceSettings,
            dependencies: .live
        )
        _store = StateObject(wrappedValue: store)
        StockRefreshCoordinator.shared.attach(
            store: store.stockStore,
            moduleSettings: moduleSettings
        )
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
            .environmentObject(store.stockStore)
            .environmentObject(store.exchangeRateStore)
            .environmentObject(store.healthStore)
            .environmentObject(store.financeStore)
            .environmentObject(store.secretStore)
            .environmentObject(store.currencyExchangeStore)
            .environmentObject(store.cloudSync)
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
            .onChange(of: appearanceModeRawValue) { _, _ in
                store.preferenceSettingsDidChange()
            }
            .onChange(of: fontSizeRawValue) { _, _ in
                store.preferenceSettingsDidChange()
            }
    }

    private var resolvedDynamicTypeSize: DynamicTypeSize {
        AppFontSize(rawValue: fontSizeRawValue)?.dynamicTypeSize
            ?? systemDynamicTypeSize
    }
}
