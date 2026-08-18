import Foundation
#if !MYTOOLS_FEATURE_STOCKS
import Combine
#endif

#if !MYTOOLS_FEATURE_STOCKS
enum StockRiseFallColorScheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case redRiseGreenFall
    case greenRiseRedFall

    var id: Self { self }
}

@MainActor
final class StockAppearanceSettings: ObservableObject {
    static let aShareKey = "stock-color-scheme-a-share-v1"
    static let hongKongKey = "stock-color-scheme-hong-kong-v1"
    static let unitedStatesKey = "stock-color-scheme-us-v1"

    private(set) var aShareScheme: StockRiseFallColorScheme
    private(set) var hongKongScheme: StockRiseFallColorScheme
    private(set) var unitedStatesScheme: StockRiseFallColorScheme
    private let defaults: UserDefaults
    private var changeHandler: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        aShareScheme = Self.savedScheme(
            forKey: Self.aShareKey,
            fallback: .redRiseGreenFall,
            defaults: defaults
        )
        hongKongScheme = Self.savedScheme(
            forKey: Self.hongKongKey,
            fallback: .redRiseGreenFall,
            defaults: defaults
        )
        unitedStatesScheme = Self.savedScheme(
            forKey: Self.unitedStatesKey,
            fallback: .greenRiseRedFall,
            defaults: defaults
        )
    }

    func setChangeHandler(_ handler: (@MainActor () -> Void)?) {
        changeHandler = handler
    }

    func applySyncedSchemes(
        aShare: StockRiseFallColorScheme,
        hongKong: StockRiseFallColorScheme,
        unitedStates: StockRiseFallColorScheme
    ) {
        let changed = aShareScheme != aShare
            || hongKongScheme != hongKong
            || unitedStatesScheme != unitedStates
        guard changed else { return }
        aShareScheme = aShare
        hongKongScheme = hongKong
        unitedStatesScheme = unitedStates
        defaults.set(aShare.rawValue, forKey: Self.aShareKey)
        defaults.set(hongKong.rawValue, forKey: Self.hongKongKey)
        defaults.set(unitedStates.rawValue, forKey: Self.unitedStatesKey)
        changeHandler?()
    }

    private static func savedScheme(
        forKey key: String,
        fallback: StockRiseFallColorScheme,
        defaults: UserDefaults
    ) -> StockRiseFallColorScheme {
        guard let rawValue = defaults.string(forKey: key),
              let value = StockRiseFallColorScheme(rawValue: rawValue) else {
            return fallback
        }
        return value
    }
}
#endif

struct CloudSyncAppPreferences: Codable, Equatable, Sendable {
    static let itemID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let moduleOrder: [ToolModule]
    let moduleVisibility: [String: Bool]
    let appearanceMode: AppAppearanceMode
    let fontSize: AppFontSize
    let aShareScheme: StockRiseFallColorScheme
    let hongKongScheme: StockRiseFallColorScheme
    let unitedStatesScheme: StockRiseFallColorScheme
    let accountSortOrder: String?
    let cardSortOrder: String?
    let cardCategoryFilter: String?
    let stockSortCriterion: String?
    let stockSortDirection: String?
    let secretSortOrder: String?
    let sportsLotteryLeagues: Data?
    let sportsLotteryMatchOrder: Data?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        moduleOrder: [ToolModule],
        moduleVisibility: [String: Bool],
        appearanceMode: AppAppearanceMode,
        fontSize: AppFontSize,
        aShareScheme: StockRiseFallColorScheme,
        hongKongScheme: StockRiseFallColorScheme,
        unitedStatesScheme: StockRiseFallColorScheme,
        accountSortOrder: String? = nil,
        cardSortOrder: String? = nil,
        cardCategoryFilter: String? = nil,
        stockSortCriterion: String? = nil,
        stockSortDirection: String? = nil,
        secretSortOrder: String? = nil,
        sportsLotteryLeagues: Data? = nil,
        sportsLotteryMatchOrder: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.moduleOrder = moduleOrder
        self.moduleVisibility = moduleVisibility
        self.appearanceMode = appearanceMode
        self.fontSize = fontSize
        self.aShareScheme = aShareScheme
        self.hongKongScheme = hongKongScheme
        self.unitedStatesScheme = unitedStatesScheme
        self.accountSortOrder = accountSortOrder
        self.cardSortOrder = cardSortOrder
        self.cardCategoryFilter = cardCategoryFilter
        self.stockSortCriterion = stockSortCriterion
        self.stockSortDirection = stockSortDirection
        self.secretSortOrder = secretSortOrder
        self.sportsLotteryLeagues = sportsLotteryLeagues
        self.sportsLotteryMatchOrder = sportsLotteryMatchOrder
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, moduleOrder, moduleVisibility, appearanceMode, fontSize
        case aShareScheme, hongKongScheme, unitedStatesScheme
        case accountSortOrder, cardSortOrder, cardCategoryFilter
        case stockSortCriterion, stockSortDirection, secretSortOrder
        case sportsLotteryLeagues, sportsLotteryMatchOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        moduleOrder = try container.decode([ToolModule].self, forKey: .moduleOrder)
        moduleVisibility = try container.decode([String: Bool].self, forKey: .moduleVisibility)
        appearanceMode = try container.decode(AppAppearanceMode.self, forKey: .appearanceMode)
        fontSize = try container.decode(AppFontSize.self, forKey: .fontSize)
        aShareScheme = try container.decode(StockRiseFallColorScheme.self, forKey: .aShareScheme)
        hongKongScheme = try container.decode(StockRiseFallColorScheme.self, forKey: .hongKongScheme)
        unitedStatesScheme = try container.decode(StockRiseFallColorScheme.self, forKey: .unitedStatesScheme)
        accountSortOrder = try container.decodeIfPresent(String.self, forKey: .accountSortOrder)
        cardSortOrder = try container.decodeIfPresent(String.self, forKey: .cardSortOrder)
        cardCategoryFilter = try container.decodeIfPresent(String.self, forKey: .cardCategoryFilter)
        stockSortCriterion = try container.decodeIfPresent(String.self, forKey: .stockSortCriterion)
        stockSortDirection = try container.decodeIfPresent(String.self, forKey: .stockSortDirection)
        secretSortOrder = try container.decodeIfPresent(String.self, forKey: .secretSortOrder)
        sportsLotteryLeagues = try container.decodeIfPresent(Data.self, forKey: .sportsLotteryLeagues)
        sportsLotteryMatchOrder = try container.decodeIfPresent(Data.self, forKey: .sportsLotteryMatchOrder)
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
            unitedStatesScheme: stockAppearanceSettings.unitedStatesScheme,
            accountSortOrder: defaults.string(forKey: AppStorageKey.accountSortOrder),
            cardSortOrder: defaults.string(forKey: AppStorageKey.cardSortOrder),
            cardCategoryFilter: defaults.string(forKey: AppStorageKey.cardCategoryFilter),
            stockSortCriterion: defaults.string(forKey: AppStorageKey.stockSortCriterion),
            stockSortDirection: defaults.string(forKey: AppStorageKey.stockSortDirection),
            secretSortOrder: defaults.string(forKey: AppStorageKey.secretSortOrder),
            sportsLotteryLeagues: defaults.data(forKey: AppStorageKey.sportsLotteryLeagues),
            sportsLotteryMatchOrder: defaults.data(forKey: AppStorageKey.sportsLotteryMatchOrder)
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
        apply(preferences.accountSortOrder, to: AppStorageKey.accountSortOrder)
        apply(preferences.cardSortOrder, to: AppStorageKey.cardSortOrder)
        apply(preferences.cardCategoryFilter, to: AppStorageKey.cardCategoryFilter)
        apply(preferences.stockSortCriterion, to: AppStorageKey.stockSortCriterion)
        apply(preferences.stockSortDirection, to: AppStorageKey.stockSortDirection)
        apply(preferences.secretSortOrder, to: AppStorageKey.secretSortOrder)
        if let sportsLotteryLeagues = preferences.sportsLotteryLeagues {
            defaults.set(sportsLotteryLeagues, forKey: AppStorageKey.sportsLotteryLeagues)
        }
        if let sportsLotteryMatchOrder = preferences.sportsLotteryMatchOrder {
            defaults.set(sportsLotteryMatchOrder, forKey: AppStorageKey.sportsLotteryMatchOrder)
        }
    }

    private func apply(_ value: String?, to key: String) {
        guard let value else { return }
        defaults.set(value, forKey: key)
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
