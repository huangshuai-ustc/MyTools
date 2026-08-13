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
#if os(iOS) && MYTOOLS_FEATURE_STOCKS
    @UIApplicationDelegateAdaptor(StockRefreshAppDelegate.self)
    private var appDelegate
#elseif os(iOS) && MYTOOLS_FEATURE_SPORTS_LOTTERY
    @UIApplicationDelegateAdaptor(SportsLotteryRefreshAppDelegate.self)
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
#if MYTOOLS_FEATURE_STOCKS
        StockRefreshCoordinator.shared.attach(
            store: store.stockStore,
            moduleSettings: moduleSettings
        )
#endif
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
#if MYTOOLS_FEATURE_STOCKS
            .environmentObject(store.stockStore)
#endif
            .environmentObject(store.exchangeRateStore)
#if MYTOOLS_FEATURE_HEALTH
            .environmentObject(store.healthStore)
#endif
#if MYTOOLS_FEATURE_FINANCE
            .environmentObject(store.financeStore)
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
            .environmentObject(store.foodMapStore)
#endif
#if MYTOOLS_FEATURE_SECRETS
            .environmentObject(store.secretStore)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
            .environmentObject(store.documentsStore)
#endif
#if MYTOOLS_FEATURE_BILLS
            .environmentObject(store.billsStore)
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
            .environmentObject(store.currencyExchangeStore)
#endif
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
