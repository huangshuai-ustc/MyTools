import Foundation

struct CloudSyncAppPreferences: Codable, Equatable, Sendable {
    static let itemID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let moduleOrder: [ToolModule]
    let moduleVisibility: [String: Bool]
    let appearanceMode: AppAppearanceMode
    let fontSize: AppFontSize
    let aShareScheme: StockRiseFallColorScheme
    let hongKongScheme: StockRiseFallColorScheme
    let unitedStatesScheme: StockRiseFallColorScheme

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        moduleOrder: [ToolModule],
        moduleVisibility: [String: Bool],
        appearanceMode: AppAppearanceMode,
        fontSize: AppFontSize,
        aShareScheme: StockRiseFallColorScheme,
        hongKongScheme: StockRiseFallColorScheme,
        unitedStatesScheme: StockRiseFallColorScheme
    ) {
        self.schemaVersion = schemaVersion
        self.moduleOrder = moduleOrder
        self.moduleVisibility = moduleVisibility
        self.appearanceMode = appearanceMode
        self.fontSize = fontSize
        self.aShareScheme = aShareScheme
        self.hongKongScheme = hongKongScheme
        self.unitedStatesScheme = unitedStatesScheme
    }
}

@MainActor
final class CloudSyncPreferencesBridge {
    private let defaults: UserDefaults
    private let moduleSettings: ToolModuleSettings
    private let stockAppearanceSettings: StockAppearanceSettings

    init(
        defaults: UserDefaults,
        moduleSettings: ToolModuleSettings,
        stockAppearanceSettings: StockAppearanceSettings
    ) {
        self.defaults = defaults
        self.moduleSettings = moduleSettings
        self.stockAppearanceSettings = stockAppearanceSettings
    }

    func makeSnapshot() -> CloudSyncAppPreferences {
        CloudSyncAppPreferences(
            moduleOrder: moduleSettings.syncedModuleOrder,
            moduleVisibility: moduleSettings.syncedModuleVisibility,
            appearanceMode: AppAppearanceMode(
                rawValue: defaults.string(forKey: AppStorageKey.appearanceMode) ?? ""
            ) ?? .system,
            fontSize: AppFontSize(
                rawValue: defaults.string(forKey: AppStorageKey.fontSize) ?? ""
            ) ?? .system,
            aShareScheme: stockAppearanceSettings.aShareScheme,
            hongKongScheme: stockAppearanceSettings.hongKongScheme,
            unitedStatesScheme: stockAppearanceSettings.unitedStatesScheme
        )
    }

    func apply(_ preferences: CloudSyncAppPreferences) throws {
        guard preferences.schemaVersion <= CloudSyncAppPreferences.currentSchemaVersion else {
            throw CloudSyncPreferencesError.unsupportedSchema(preferences.schemaVersion)
        }

        moduleSettings.applySyncedPreferences(
            order: preferences.moduleOrder,
            visibility: preferences.moduleVisibility
        )
        stockAppearanceSettings.applySyncedSchemes(
            aShare: preferences.aShareScheme,
            hongKong: preferences.hongKongScheme,
            unitedStates: preferences.unitedStatesScheme
        )
        defaults.set(preferences.appearanceMode.rawValue, forKey: AppStorageKey.appearanceMode)
        defaults.set(preferences.fontSize.rawValue, forKey: AppStorageKey.fontSize)
    }
}

private enum CloudSyncPreferencesError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "云端设置来自更新版本（设置版本：\(version)），请先更新 App。"
        }
    }
}
