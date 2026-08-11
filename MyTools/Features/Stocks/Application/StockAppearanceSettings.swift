#if MYTOOLS_FEATURE_STOCKS
import Foundation
import Combine

@MainActor
final class StockAppearanceSettings: ObservableObject {
    static let aShareKey = "stock-color-scheme-a-share-v1"
    static let hongKongKey = "stock-color-scheme-hong-kong-v1"
    static let unitedStatesKey = "stock-color-scheme-us-v1"

    @Published private(set) var aShareScheme: StockRiseFallColorScheme
    @Published private(set) var hongKongScheme: StockRiseFallColorScheme
    @Published private(set) var unitedStatesScheme: StockRiseFallColorScheme
    private let defaults: UserDefaults
    private var changeHandler: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        aShareScheme = Self.savedScheme(forKey: Self.aShareKey, market: .aShare, defaults: defaults)
        hongKongScheme = Self.savedScheme(forKey: Self.hongKongKey, market: .hongKong, defaults: defaults)
        unitedStatesScheme = Self.savedScheme(forKey: Self.unitedStatesKey, market: .unitedStates, defaults: defaults)
    }

    func scheme(for market: StockMarket) -> StockRiseFallColorScheme {
        switch market {
        case .aShare: return aShareScheme
        case .hongKong: return hongKongScheme
        case .unitedStates: return unitedStatesScheme
        }
    }

    func setScheme(_ scheme: StockRiseFallColorScheme, for market: StockMarket) {
        guard scheme != self.scheme(for: market) else { return }
        switch market {
        case .aShare:
            aShareScheme = scheme
            defaults.set(scheme.rawValue, forKey: Self.aShareKey)
        case .hongKong:
            hongKongScheme = scheme
            defaults.set(scheme.rawValue, forKey: Self.hongKongKey)
        case .unitedStates:
            unitedStatesScheme = scheme
            defaults.set(scheme.rawValue, forKey: Self.unitedStatesKey)
        }
        changeHandler?()
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
        market: StockMarket,
        defaults: UserDefaults
    ) -> StockRiseFallColorScheme {
        guard let saved = defaults.string(forKey: key),
              let scheme = StockRiseFallColorScheme(rawValue: saved) else {
            return .defaultScheme(for: market)
        }
        return scheme
    }
}

#endif
