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
#elseif os(macOS)
import AppKit
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
    @StateObject private var preferenceChangeBus = AppPreferenceChangeBus.shared
    @State private var desktopSelection: RootDestination? = .module(.personalFinance)

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
        // Pre-warm the A-share holiday calendar so that trading-day queries
        // during the current session reflect the official closure/补班 schedule.
        Task { await AShareHolidayService.shared.refreshIfNeeded() }
#endif
    }

    var body: some Scene {
        WindowGroup {
            ConfiguredRootView(
                store: store,
                auth: auth,
                moduleSettings: moduleSettings,
                stockAppearanceSettings: stockAppearanceSettings,
                preferenceChangeBus: preferenceChangeBus,
                desktopSelection: $desktopSelection
            )
        }
#if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
#endif
    }
}

private struct ConfiguredRootView: View {
    let store: AppStore
    let auth: AuthManager
    let moduleSettings: ToolModuleSettings
    let stockAppearanceSettings: StockAppearanceSettings
    @ObservedObject var preferenceChangeBus: AppPreferenceChangeBus
    @Binding var desktopSelection: RootDestination?
    @AppStorage(AppStorageKey.appearanceMode) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppStorageKey.fontSize) private var fontSizeRawValue = AppFontSize.system.rawValue
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize

    var body: some View {
        RootView(desktopSelection: $desktopSelection)
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
            .environmentObject(preferenceChangeBus)
            .environmentObject(AppNotificationService.shared)
#if !os(macOS)
            .preferredColorScheme(
                AppAppearanceMode(rawValue: appearanceModeRawValue)?.colorScheme
                    ?? AppAppearanceMode.system.colorScheme
            )
#endif
            .environment(\.dynamicTypeSize, resolvedDynamicTypeSize)
#if os(macOS)
            .modifier(AppFontSizeModifier(rawValue: fontSizeRawValue))
#endif
            .appListSpacing()
#if os(macOS)
            .environment(\.appFontScale, resolvedMacFontScale)
#endif
            .onAppear {
#if os(macOS)
                applyMacAppearance()
#endif
            }
            .onChange(of: appearanceModeRawValue) { _, _ in
#if os(macOS)
                applyMacAppearance()
#endif
                store.preferenceSettingsDidChange()
            }
            .onChange(of: fontSizeRawValue) { _, _ in
                store.preferenceSettingsDidChange()
            }
            .onChange(of: preferenceChangeBus.revision) { _, _ in
                store.preferenceSettingsDidChange()
            }
    }

    private var resolvedDynamicTypeSize: DynamicTypeSize {
        AppFontSize(rawValue: fontSizeRawValue)?.dynamicTypeSize
            ?? systemDynamicTypeSize
    }

#if os(macOS)
    private var resolvedMacFontScale: CGFloat? {
        (AppFontSize(rawValue: fontSizeRawValue) ?? .system).macOSScale
    }

    private func applyMacAppearance() {
        switch AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
#endif
}

#if os(macOS)
private struct AppFontSizeModifier: ViewModifier {
    let rawValue: String

    func body(content: Content) -> some View {
        content.font(configuredFont)
    }

    private var configuredFont: Font? {
        guard let fontSize = AppFontSize(rawValue: rawValue),
              let scale = fontSize.macOSScale else {
            return nil
        }
        // Unstyled Text, Label and native controls must use the same complete
        // body scale as explicit `.appFont(.body)` content. Capping this value
        // created two visibly different font systems on the same screen.
        return .system(size: 13 * scale)
    }
}

private extension AppFontSize {
    var macOSScale: CGFloat? {
        switch self {
        case .system: return nil
        case .xSmall: return 0.78
        case .small: return 0.86
        case .medium: return 0.93
        case .large: return 1
        case .xLarge: return 1.12
        case .xxLarge: return 1.25
        case .xxxLarge: return 1.4
        case .accessibility1: return 1.6
        case .accessibility2: return 1.8
        case .accessibility3: return 2
        case .accessibility4: return 2.25
        case .accessibility5: return 2.5
        }
    }
}
#endif
