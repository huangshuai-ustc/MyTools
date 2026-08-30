#if MYTOOLS_FEATURE_SPORTS_LOTTERY
import Foundation

/// Reads and writes the two user preferences that the sports-lottery module
/// persists to UserDefaults: the selected league list and the per-league match
/// display order.  This keeps persistence logic out of the Domain layer, which
/// should contain only value types and pure business rules.
///
/// Both preferences are non-Vault data (they don't enter backup or CloudKit
/// records); the league selection is broadcast via `AppPreferenceChangeBus` so
/// CloudSyncPreferences can pick it up for iCloud sync.
enum SportsLotteryLeaguePreferences {
    static let key = AppStorageKey.sportsLotteryLeagues

    static func load(from defaults: UserDefaults = .standard) -> [SportsLotteryLeague] {
        guard let data = defaults.data(forKey: key),
              let leagues = try? JSONDecoder().decode([SportsLotteryLeague].self, from: data) else {
            return sorted(SportsLotteryLeague.allCases)
        }
        return sorted(unique(leagues))
    }

    static func save(_ leagues: [SportsLotteryLeague], to defaults: UserDefaults = .standard) {
        let value = sorted(unique(leagues))
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        Task { @MainActor in
            AppPreferenceChangeBus.shared.notifyChanged()
        }
    }

    private static func unique(_ leagues: [SportsLotteryLeague]) -> [SportsLotteryLeague] {
        var seen = Set<Int>()
        return leagues.filter { seen.insert($0.leagueID).inserted }
    }

    static func sorted(
        _ leagues: [SportsLotteryLeague]
    ) -> [SportsLotteryLeague] {
        leagues.sorted { lhs, rhs in
            AppAlphabeticalSort.isOrderedBefore(
                lhs.title,
                rhs.title,
                lhsTieBreaker: String(lhs.leagueID),
                rhsTieBreaker: String(rhs.leagueID)
            )
        }
    }
}

enum SportsLotteryMatchOrderPreferences {
    static let key = AppStorageKey.sportsLotteryMatchOrder

    static func load(
        for leagueID: Int,
        from defaults: UserDefaults = .standard
    ) -> [Int] {
        guard let data = defaults.data(forKey: key),
              let orders = try? JSONDecoder().decode([String: [Int]].self, from: data) else {
            return []
        }
        return orders[String(leagueID), default: []]
    }

    static func save(
        _ order: [Int],
        for leagueID: Int,
        to defaults: UserDefaults = .standard
    ) {
        var orders: [String: [Int]] = [:]
        if let data = defaults.data(forKey: key),
           let existing = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            orders = existing
        }
        orders[String(leagueID)] = order
        guard let data = try? JSONEncoder().encode(orders) else { return }
        defaults.set(data, forKey: key)
        Task { @MainActor in
            AppPreferenceChangeBus.shared.notifyChanged()
        }
    }
}
#endif
