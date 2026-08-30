#if MYTOOLS_FEATURE_STOCKS
import Foundation

// MARK: - Persisted model

/// A single day's holiday status as returned by the holiday-cn JSON feed.
///
/// Reference: https://github.com/NateScarlet/holiday-cn
/// Each year's file follows the URL:
///   https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/{year}.json
private struct HolidayCNDay: Codable, Sendable {
    /// Calendar date in "YYYY-MM-DD" format.
    let date: String
    /// `true` = holiday / rest day; `false` = compensatory work day (补班).
    let isOffDay: Bool
}

private struct HolidayCNFile: Codable, Sendable {
    let year: Int
    let papers: [String]?
    let days: [HolidayCNDay]
}

// MARK: - Thread-safe snapshot (for synchronous reads from TradingCalendar)

/// A read-only snapshot of the service's override tables, published to a
/// reference type that `StockMarketTradingCalendar` can query synchronously
/// without needing `await`.
final class AShareHolidaySnapshot: @unchecked Sendable {
    // Protected by the nonisolated(unsafe) annotation: mutations happen only
    // from within the actor before the value is published here.
    nonisolated(unsafe) private(set) var workDayOverrides: [Int: Set<Int>] = [:]
    nonisolated(unsafe) private(set) var holidayOverrides: [Int: Set<Int>] = [:]

    fileprivate func update(
        workDayOverrides: [Int: Set<Int>],
        holidayOverrides: [Int: Set<Int>]
    ) {
        self.workDayOverrides = workDayOverrides
        self.holidayOverrides = holidayOverrides
    }

    /// Synchronously returns a trading-day override for `date`.
    ///
    /// - Returns `true`  → compensatory work day (补班); trades even on weekends.
    /// - Returns `false` → mandated holiday; does not trade even on weekdays.
    /// - Returns `nil`   → no override available; fall back to built-in algorithm.
    func tradingDayOverride(for date: Date, calendar: Calendar) -> Bool? {
        let year = calendar.component(.year, from: date)
        let components = calendar.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return nil }
        let key = month * 100 + day
        if workDayOverrides[year]?.contains(key) == true { return true }
        if holidayOverrides[year]?.contains(key) == true { return false }
        return nil
    }
}

// MARK: - Service

/// Fetches and caches the A-share trading calendar for any given year from the
/// holiday-cn open-data repository. Results are merged with the built-in
/// algorithm in `StockMarketTradingCalendar` to provide accurate closures and
/// compensatory-work-day (补班) information without manual annual maintenance.
///
/// - Thread safety: All async methods are actor-isolated. Synchronous reads for
///   the trading calendar go through `snapshot`, a separately published value.
/// - Persistence: Cached data survives app restarts via `UserDefaults`.
/// - Fallback: When the network is unavailable the built-in calendar algorithm
///   continues to work; only the supplemental annotations are unavailable.
actor AShareHolidayService {
    static let shared = AShareHolidayService()

    /// Read-only view of the latest loaded override tables. Published after
    /// every successful load so `StockMarketTradingCalendar` can read it
    /// synchronously without `await`.
    let snapshot = AShareHolidaySnapshot()

    private enum DefaultsKey {
        static func yearData(_ year: Int) -> String { "ashare-holiday-cn-\(year)" }
        static func fetchedAt(_ year: Int) -> String { "ashare-holiday-cn-fetched-at-\(year)" }
    }

    /// Days that are mandated working days (补班) in the given year.
    private var workDayOverrides: [Int: Set<Int>] = [:]
    /// Days that are mandated rest days / non-trading days beyond weekends.
    private var holidayOverrides: [Int: Set<Int>] = [:]
    /// Years whose data has been loaded (from cache or network).
    private var loadedYears: Set<Int> = []

    private let defaults: UserDefaults
    private let session: URLSession

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.defaults = defaults
        self.session = session
    }

    // MARK: - Loading

    /// Ensures data is available for `year`. Reads from `UserDefaults` cache
    /// first; schedules a network refresh if the cached copy is stale.
    func ensureLoaded(for year: Int) async {
        guard !loadedYears.contains(year) else { return }
        if let cached = cachedFile(for: year) {
            applyFile(cached, year: year)
            loadedYears.insert(year)
            if needsRefresh(year: year) {
                Task { await fetch(year: year) }
            }
            return
        }
        await fetch(year: year)
    }

    /// Triggers a background refresh for the current year and, after Dec 20,
    /// also pre-fetches next year's data. Safe to call on every app foreground
    /// transition; internally rate-limited via `needsRefresh`.
    func refreshIfNeeded() async {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        let year = calendar.component(.year, from: now)
        await ensureLoaded(for: year)
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        if month == 12, day >= 20 {
            await ensureLoaded(for: year + 1)
        }
    }

    // MARK: - Network

    private func fetch(year: Int) async {
        let urlString = "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/\(year).json"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }
            let file = try JSONDecoder().decode(HolidayCNFile.self, from: data)
            applyFile(file, year: year)
            loadedYears.insert(year)
            persistFile(file, year: year)
        } catch {
            DiagnosticLogger.logError(
                .lifecycle,
                operation: "AShareHolidayService fetch \(year)",
                error: error
            )
        }
    }

    // MARK: - Parsing

    private func applyFile(_ file: HolidayCNFile, year: Int) {
        var workDays = Set<Int>()
        var holidays = Set<Int>()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt

        for entry in file.days {
            guard let date = formatter.date(from: entry.date) else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
            let comps = cal.dateComponents([.month, .day], from: date)
            guard let m = comps.month, let d = comps.day else { continue }
            let key = m * 100 + d
            if entry.isOffDay {
                holidays.insert(key)
            } else {
                workDays.insert(key)
            }
        }
        workDayOverrides[year] = workDays
        holidayOverrides[year] = holidays
        // Publish to the snapshot so synchronous readers see the update.
        snapshot.update(workDayOverrides: workDayOverrides, holidayOverrides: holidayOverrides)
    }

    // MARK: - Persistence

    private func cachedFile(for year: Int) -> HolidayCNFile? {
        guard let data = defaults.data(forKey: DefaultsKey.yearData(year)) else { return nil }
        return try? JSONDecoder().decode(HolidayCNFile.self, from: data)
    }

    private func persistFile(_ file: HolidayCNFile, year: Int) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        defaults.set(data, forKey: DefaultsKey.yearData(year))
        defaults.set(Date(), forKey: DefaultsKey.fetchedAt(year))
    }

    private func needsRefresh(year: Int) -> Bool {
        guard let fetchedAt = defaults.object(forKey: DefaultsKey.fetchedAt(year)) as? Date
        else { return true }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        let now = Date()
        let currentYear = cal.component(.year, from: now)
        if year > currentYear {
            // Re-fetch future-year data every 30 days (announcement usually
            // comes in November/December of the prior year).
            return now.timeIntervalSince(fetchedAt) > 30 * 24 * 3600
        }
        // Re-fetch current-year data every 6 months (rare mid-year adjustments).
        return now.timeIntervalSince(fetchedAt) > 180 * 24 * 3600
    }
}

#endif
