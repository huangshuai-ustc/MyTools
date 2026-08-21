#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockChartStoreKey: Hashable, Sendable {
    let market: StockMarket
    let symbol: String
}

struct StockChartCacheKey: Hashable, Sendable {
    let market: StockMarket
    let symbol: String
    let range: StockChartRange
}

struct StockChartStoredRangeMetadata: Codable, Sendable {
    static let currentCompleteHistoryRevision = 3

    let symbol: String
    let name: String
    let currencyCode: String
    let previousClose: Double?
    let preMarketPoints: [StockChartPoint]
    let postMarketPoints: [StockChartPoint]
    let quoteUpdatedAt: Date
    let fetchedAt: Date
    let source: String
    let supportsCandlesticks: Bool
    let indicatorPointCount: Int?
    let dailyIndicatorPointCount: Int?
    let historyCoverageRevision: Int

    private enum CodingKeys: String, CodingKey {
        case symbol, name, currencyCode, previousClose, preMarketPoints, postMarketPoints
        case quoteUpdatedAt, fetchedAt, source, supportsCandlesticks, indicatorPointCount
        case dailyIndicatorPointCount, historyCoverageRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        name = try container.decode(String.self, forKey: .name)
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
        previousClose = try container.decodeIfPresent(Double.self, forKey: .previousClose)
        preMarketPoints = try container.decodeIfPresent(
            [StockChartPoint].self,
            forKey: .preMarketPoints
        ) ?? []
        postMarketPoints = try container.decodeIfPresent(
            [StockChartPoint].self,
            forKey: .postMarketPoints
        ) ?? []
        quoteUpdatedAt = try container.decode(Date.self, forKey: .quoteUpdatedAt)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        source = try container.decode(String.self, forKey: .source)
        supportsCandlesticks = try container.decode(Bool.self, forKey: .supportsCandlesticks)
        indicatorPointCount = try container.decodeIfPresent(Int.self, forKey: .indicatorPointCount)
        dailyIndicatorPointCount = try container.decodeIfPresent(
            Int.self,
            forKey: .dailyIndicatorPointCount
        )
        historyCoverageRevision = try container.decodeIfPresent(
            Int.self,
            forKey: .historyCoverageRevision
        ) ?? 0
    }

    init(snapshot: StockChartSnapshot) {
        symbol = snapshot.symbol
        name = snapshot.name
        currencyCode = snapshot.currencyCode
        previousClose = snapshot.previousClose
        preMarketPoints = snapshot.preMarketPoints
        postMarketPoints = snapshot.postMarketPoints
        quoteUpdatedAt = snapshot.quoteUpdatedAt
        fetchedAt = snapshot.fetchedAt
        source = snapshot.source
        supportsCandlesticks = snapshot.supportsCandlesticks
        indicatorPointCount = snapshot.indicatorPoints?.count
        dailyIndicatorPointCount = snapshot.dailyIndicatorPoints?.count
        historyCoverageRevision = Self.currentCompleteHistoryRevision
    }

    init(
        symbol: String,
        name: String,
        currencyCode: String,
        previousClose: Double?,
        preMarketPoints: [StockChartPoint] = [],
        postMarketPoints: [StockChartPoint] = [],
        quoteUpdatedAt: Date,
        fetchedAt: Date,
        source: String,
        supportsCandlesticks: Bool,
        indicatorPointCount: Int?,
        dailyIndicatorPointCount: Int? = nil,
        historyCoverageRevision: Int = Self.currentCompleteHistoryRevision
    ) {
        self.symbol = symbol
        self.name = name
        self.currencyCode = currencyCode
        self.previousClose = previousClose
        self.preMarketPoints = preMarketPoints
        self.postMarketPoints = postMarketPoints
        self.quoteUpdatedAt = quoteUpdatedAt
        self.fetchedAt = fetchedAt
        self.source = source
        self.supportsCandlesticks = supportsCandlesticks
        self.indicatorPointCount = indicatorPointCount
        self.dailyIndicatorPointCount = dailyIndicatorPointCount
        self.historyCoverageRevision = historyCoverageRevision
    }

    func snapshot(
        points: [StockChartPoint],
        indicatorPoints: [StockChartPoint],
        dailyIndicatorPoints: [StockChartPoint]? = nil
    ) -> StockChartSnapshot {
        StockChartSnapshot(
            symbol: symbol,
            name: name,
            currencyCode: currencyCode,
            previousClose: previousClose,
            points: points,
            preMarketPoints: preMarketPoints,
            postMarketPoints: postMarketPoints,
            indicatorPoints: indicatorPoints,
            dailyIndicatorPoints: dailyIndicatorPoints,
            quoteUpdatedAt: points.last?.date ?? quoteUpdatedAt,
            fetchedAt: fetchedAt,
            source: source,
            supportsCandlesticks: supportsCandlesticks
        )
    }
}

struct StockChartPersistedStore: Codable, Sendable {
    static let currentVersion = 2

    let version: Int
    let market: StockMarket
    let symbol: String
    var series: [String: [StockChartPoint]]
    var rangeMetadata: [String: StockChartStoredRangeMetadata]
}

// Kept only to decode the range-based cache created before the time-series store.
struct StockChartLegacyCacheEntry: Codable, Sendable {
    let market: StockMarket
    let symbol: String
    let range: StockChartRange
    let snapshot: StockChartSnapshot
}

struct StockChartDiskStore {
    private let fileManager: FileManager
    private let persistentStoreDirectory: URL
    private let legacyCacheDirectory: URL
    private var memoryStores: [StockChartStoreKey: StockChartPersistedStore] = [:]

    init(
        fileManager: FileManager = .default,
        persistentStoreDirectory: URL? = nil,
        legacyCacheDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.legacyCacheDirectory = legacyCacheDirectory ?? cacheDirectory
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("StockCharts", isDirectory: true)
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? cacheDirectory
        self.persistentStoreDirectory = persistentStoreDirectory ?? supportDirectory
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("StockCharts", isDirectory: true)
    }

    mutating func load(for key: StockChartStoreKey) -> StockChartPersistedStore? {
        if let stored = memoryStores[key],
           stored.version == StockChartPersistedStore.currentVersion,
           stored.market == key.market,
           stored.symbol == key.symbol {
            return stored
        }
        memoryStores[key] = nil
        let url = persistentStoreURL(for: key)
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StockChartPersistedStore.self, from: data),
           stored.version == StockChartPersistedStore.currentVersion,
           stored.market == key.market,
           stored.symbol == key.symbol {
            memoryStores[key] = stored
            return stored
        }

        guard let migration = migratedLegacyStore(for: key) else { return nil }
        if save(migration.store, for: key) {
            removeMigratedLegacyFiles(migration.urls)
        }
        return migration.store
    }

    func emptyStore(for key: StockChartStoreKey) -> StockChartPersistedStore {
        StockChartPersistedStore(
            version: StockChartPersistedStore.currentVersion,
            market: key.market,
            symbol: key.symbol,
            series: [:],
            rangeMetadata: [:]
        )
    }

    func merging(
        _ snapshot: StockChartSnapshot,
        range: StockChartRange,
        for key: StockChartStoreKey,
        into existingStore: StockChartPersistedStore?
    ) -> StockChartPersistedStore {
        var store = existingStore ?? emptyStore(for: key)
        merge(snapshot, range: range, into: &store)
        return store
    }

    @discardableResult
    mutating func save(_ store: StockChartPersistedStore, for key: StockChartStoreKey) -> Bool {
        guard store.version == StockChartPersistedStore.currentVersion,
              store.market == key.market,
              store.symbol == key.symbol else {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "离线行情文件版本或标识不匹配，已拒绝写入",
                level: .warning
            )
            return false
        }
        memoryStores[key] = store
        do {
            try fileManager.createDirectory(
                at: persistentStoreDirectory,
                withIntermediateDirectories: true
            )
            var directory = persistentStoreDirectory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? directory.setResourceValues(resourceValues)
            let data = try JSONEncoder().encode(store)
            try data.write(to: persistentStoreURL(for: key), options: .atomic)
            return true
        } catch {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "离线行情文件写入失败：\(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    mutating func removeAll() {
        memoryStores.removeAll()
        for directory in [persistentStoreDirectory, legacyCacheDirectory] {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                DiagnosticLogger.shared.log(
                    .stockQuote,
                    "离线行情缓存清理失败：\(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    func renderedSnapshot(
        from store: StockChartPersistedStore,
        range: StockChartRange
    ) -> StockChartSnapshot? {
        let compatibleMetadata = StockChartSeriesProcessor.compatibleMetadataRanges(for: range)
            .compactMap { store.rangeMetadata[$0.rawValue] }
            .max { $0.fetchedAt < $1.fetchedAt }
        let metadata = compatibleMetadata ?? store.rangeMetadata[range.rawValue]
        guard let metadata else { return nil }

        let kind = StockChartSeriesProcessor.seriesKind(for: range)
        let dailyPoints = store.series[StockChartSeriesKind.daily.rawValue] ?? []
        let storedPoints: [StockChartPoint]
        if range.isKLineRange, let cachedDerivedPoints = store.series[kind.rawValue],
           !cachedDerivedPoints.isEmpty {
            // K-line series are derived from the same cached daily source.
            // Read the prepared series directly so switching tabs does not
            // re-aggregate the entire history on the main thread.
            storedPoints = cachedDerivedPoints
        } else if range.isKLineRange, !dailyPoints.isEmpty {
            storedPoints = StockChartSeriesProcessor.preparedKLinePoints(
                dailyPoints,
                range: range,
                market: store.market
            )
        } else {
            storedPoints = store.series[kind.rawValue] ?? []
        }
        // The canonical daily source is the only reliable listing boundary
        // for both the current K-line tabs and legacy time-window ranges.
        // A coarse yearly series can contain one bar even when the daily
        // history spans many months, which would otherwise collapse a
        // one-month/one-year view to its last point.
        let inceptionDate = dailyPoints.map(\.date).min()
            ?? StockChartSeriesProcessor.inceptionDate(in: store.series)
        let points = StockChartSeriesProcessor.visiblePoints(
            from: storedPoints,
            for: range,
            market: store.market,
            inceptionDate: inceptionDate
        )
        guard !points.isEmpty else { return nil }
        let indicatorPoints: [StockChartPoint]
        if range.isMinuteRange {
            // Keep the complete minute history for indicator warm-up. The
            // presentation layer draws only `points`, which are already
            // scoped to the latest session or latest five trading days.
            indicatorPoints = storedPoints
        } else {
            indicatorPoints = StockChartSeriesProcessor.indicatorPoints(
                from: storedPoints,
                visiblePoints: points,
                range: range
            )
        }
        return metadata.snapshot(
            points: points,
            indicatorPoints: indicatorPoints,
            dailyIndicatorPoints: dailyPoints
        )
    }

    func hasRequestedCoverage(
        in store: StockChartPersistedStore,
        for range: StockChartRange
    ) -> Bool {
        StockChartSeriesProcessor.compatibleMetadataRanges(for: range).contains {
            guard let metadata = store.rangeMetadata[$0.rawValue] else { return false }
            let usesIncompleteUSFallback = range.isKLineRange
                && store.market == .unitedStates
                && metadata.source != "Yahoo Finance"
                && metadata.source != "Nasdaq"
            let needsCompleteHistoryRefresh = metadata.historyCoverageRevision
                < StockChartStoredRangeMetadata.currentCompleteHistoryRevision
                || usesIncompleteUSFallback
            if range.isKLineRange, needsCompleteHistoryRefresh {
                // Caches created before the complete-history request was
                // introduced, or populated by a US fallback provider, may
                // stop around 2016 for ETFs. Force a complete-history retry.
                return false
            }
            if range == .intraday || range == .fiveDays {
                return metadata.indicatorPointCount != nil
            }
            return true
        }
    }

    func persistentStoreURL(for key: StockChartStoreKey) -> URL {
        let identifier = "\(key.market.rawValue)|\(key.symbol)"
        return persistentStoreDirectory
            .appendingPathComponent(fileName(for: identifier), isDirectory: false)
            .appendingPathExtension("json")
    }

    func legacyCacheURL(for key: StockChartCacheKey) -> URL {
        let identifier = "\(key.market.rawValue)|\(key.symbol)|\(key.range.rawValue)"
        return legacyCacheDirectory
            .appendingPathComponent(fileName(for: identifier), isDirectory: false)
            .appendingPathExtension("json")
    }

    private mutating func migratedLegacyStore(
        for key: StockChartStoreKey
    ) -> (store: StockChartPersistedStore, urls: [URL])? {
        var store = emptyStore(for: key)
        var migratedURLs: [URL] = []
        for range in StockChartRange.allPersistedCases {
            let cacheKey = StockChartCacheKey(
                market: key.market,
                symbol: key.symbol,
                range: range
            )
            let url = legacyCacheURL(for: cacheKey)
            guard let data = try? Data(contentsOf: url),
                  let persisted = try? JSONDecoder().decode(
                    StockChartLegacyCacheEntry.self,
                    from: data
                  ),
                  persisted.market == key.market,
                  persisted.symbol == key.symbol,
                  persisted.range == range else { continue }
            merge(persisted.snapshot, range: range, into: &store)
            migratedURLs.append(url)
        }
        return migratedURLs.isEmpty ? nil : (store, migratedURLs)
    }

    private func removeMigratedLegacyFiles(_ urls: [URL]) {
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                DiagnosticLogger.shared.log(
                    .stockQuote,
                    "旧行情缓存清理失败：\(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    private func merge(
        _ snapshot: StockChartSnapshot,
        range: StockChartRange,
        into store: inout StockChartPersistedStore
    ) {
        let kind = StockChartSeriesProcessor.seriesKind(for: range)
        let incomingPoints = snapshot.indicatorPoints ?? snapshot.points
        let existing = store.series[kind.rawValue] ?? []
        store.series[kind.rawValue] = StockChartSeriesProcessor.mergedPoints(
            existing,
            with: incomingPoints,
            kind: kind,
            market: store.market
        )
        // Every visible K-line request now fetches daily bars. Preserve those
        // bars as the canonical source even when the selected tab is week,
        // month, quarter, or year; all displayed K-line granularities are
        // then derived from this one source.
        let rawDailyPoints = snapshot.dailyIndicatorPoints
            ?? (range.isKLineRange ? incomingPoints : nil)
        if let rawDailyPoints, !rawDailyPoints.isEmpty {
            // When the selected range itself is daily, `store.series` was
            // updated above. Compare against the pre-merge snapshot instead
            // of the already-updated array, otherwise every daily change is
            // incorrectly treated as unchanged and derived bars go stale.
            let existingDaily = kind == .daily
                ? existing
                : (store.series[StockChartSeriesKind.daily.rawValue] ?? [])
            let calendar = StockChartSeriesProcessor.marketCalendar(store.market)
            var existingDailyByBucket: [Date: StockChartPoint] = [:]
            for point in existingDaily {
                existingDailyByBucket[
                    StockChartSeriesProcessor.dailyBucket(for: point.date, calendar: calendar)
                ] = point
            }
            let changedDailyPoints = rawDailyPoints.filter { point in
                existingDailyByBucket[
                    StockChartSeriesProcessor.dailyBucket(for: point.date, calendar: calendar)
                ] != point
            }
            let mergedDaily = StockChartSeriesProcessor.mergedPoints(
                existingDaily,
                with: rawDailyPoints,
                kind: .daily,
                market: store.market
            )
            store.series[StockChartSeriesKind.daily.rawValue] = mergedDaily

            // Keep every K-line tab derived from the same daily source. Only
            // buckets touched by this update are recalculated.
            for (derivedKind, _) in [
                (StockChartSeriesKind.weekly, StockChartRange.weekK),
                (StockChartSeriesKind.monthly, StockChartRange.monthK),
                (StockChartSeriesKind.quarterly, StockChartRange.quarterK),
                (StockChartSeriesKind.yearly, StockChartRange.yearK)
            ] {
                let existingDerived = store.series[derivedKind.rawValue] ?? []
                let expectedBuckets = Set(mergedDaily.map {
                    StockChartSeriesProcessor.seriesBucket(
                        for: $0.date,
                        kind: derivedKind,
                        calendar: calendar
                    )
                })
                let existingBuckets = Set(existingDerived.map {
                    StockChartSeriesProcessor.seriesBucket(
                        for: $0.date,
                        kind: derivedKind,
                        calendar: calendar
                    )
                })
                // A previous interrupted write can leave a derived series with
                // the same prices but missing a whole time bucket. In that
                // case no source point appears "changed", so force a rebuild
                // from the canonical daily source instead of preserving the
                // incomplete aggregate.
                let needsRebuild = expectedBuckets != existingBuckets
                let affectedPoints = existingDerived.isEmpty || needsRebuild
                    ? mergedDaily
                    : changedDailyPoints
                store.series[derivedKind.rawValue] = StockChartSeriesProcessor
                    .updatingAggregatedPoints(
                        existingDerived,
                        sourcePoints: mergedDaily,
                        changedSourcePoints: affectedPoints,
                        kind: derivedKind,
                        market: store.market
                    )
            }
        }
        store.rangeMetadata[range.rawValue] = StockChartStoredRangeMetadata(snapshot: snapshot)
    }

    private func fileName(for identifier: String) -> String {
        Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }
}

#endif
