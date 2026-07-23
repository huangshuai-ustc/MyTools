import Foundation
import Combine

@MainActor
final class StockAppearanceSettings: ObservableObject {
    static let aShareKey = "stock-color-scheme-a-share-v1"
    static let unitedStatesKey = "stock-color-scheme-us-v1"

    @Published private(set) var aShareScheme: StockRiseFallColorScheme
    @Published private(set) var unitedStatesScheme: StockRiseFallColorScheme
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        aShareScheme = Self.savedScheme(forKey: Self.aShareKey, market: .aShare, defaults: defaults)
        unitedStatesScheme = Self.savedScheme(forKey: Self.unitedStatesKey, market: .unitedStates, defaults: defaults)
    }

    func scheme(for market: StockMarket) -> StockRiseFallColorScheme {
        market == .aShare ? aShareScheme : unitedStatesScheme
    }

    func setScheme(_ scheme: StockRiseFallColorScheme, for market: StockMarket) {
        switch market {
        case .aShare:
            aShareScheme = scheme
            defaults.set(scheme.rawValue, forKey: Self.aShareKey)
        case .unitedStates:
            unitedStatesScheme = scheme
            defaults.set(scheme.rawValue, forKey: Self.unitedStatesKey)
        }
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
