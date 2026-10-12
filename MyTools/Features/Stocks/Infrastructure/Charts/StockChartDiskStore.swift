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

struct StockChartStoredRangeMetadata: Codable, Equatable, Sendable {
    let symbol: String
    let name: String
    let currencyCode: String
    let previousClose: Double?
    let preMarketPoints: [StockChartPoint]
    let postMarketPoints: [StockChartPoint]
    let quoteUpdatedAt: Date
    var fetchedAt: Date
    let source: String
    let supportsCandlesticks: Bool
    let indicatorPointCount: Int?
    let dailyIndicatorPointCount: Int?

    private enum CodingKeys: String, CodingKey {
        case symbol, name, currencyCode, previousClose, preMarketPoints, postMarketPoints
        case quoteUpdatedAt, fetchedAt, source, supportsCandlesticks, indicatorPointCount
        case dailyIndicatorPointCount
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
        dailyIndicatorPointCount: Int? = nil
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
    }

    func snapshot(
        points: [StockChartPoint],
        indicatorPoints: [StockChartPoint],
        preMarketPoints storedPreMarketPoints: [StockChartPoint]? = nil,
        postMarketPoints storedPostMarketPoints: [StockChartPoint]? = nil,
        dailyIndicatorPoints: [StockChartPoint]? = nil,
        cachedMinuteTechnicalIndicators: [StockTechnicalIndicatorPoint]? = nil,
        cachedDailyTechnicalIndicators: [StockTechnicalIndicatorPoint]? = nil,
        quoteUpdatedAt latestQuoteUpdatedAt: Date? = nil
    ) -> StockChartSnapshot {
        StockChartSnapshot(
            symbol: symbol,
            name: name,
            currencyCode: currencyCode,
            previousClose: previousClose,
            points: points,
            preMarketPoints: storedPreMarketPoints ?? preMarketPoints,
            postMarketPoints: storedPostMarketPoints ?? postMarketPoints,
            indicatorPoints: indicatorPoints,
            dailyIndicatorPoints: dailyIndicatorPoints,
            cachedMinuteTechnicalIndicators: cachedMinuteTechnicalIndicators,
            cachedDailyTechnicalIndicators: cachedDailyTechnicalIndicators,
            quoteUpdatedAt: latestQuoteUpdatedAt ?? points.last?.date ?? quoteUpdatedAt,
            fetchedAt: fetchedAt,
            source: source,
            supportsCandlesticks: supportsCandlesticks
        )
    }
}

struct StockChartPersistedStore: Codable, Sendable {
    // Version 7 invalidates minute caches that were merged through the
    // generic US regular-session filter with an inclusive 16:00 boundary.
    // Version 6 can be repaired by moving that boundary print to the
    // post-market series; its daily history must remain untouched.
    // Version 8 persists extended-hours minutes separately and applies the
    // seven-trading-day retention policy to every minute source.
    static let currentVersion = 8
    // Keep this separate from the file schema version. Adding a technical
    // indicator does not invalidate the raw OHLCV cache: an older file can be
    // upgraded locally once, then written back with the current indicator set.
    static let currentTechnicalIndicatorCacheVersion = 1

    var version: Int
    let market: StockMarket
    let symbol: String
    var series: [String: [StockChartPoint]]
    var derivedSeries: [String: [StockChartPoint]] = [:]
    var technicalIndicators: [String: [StockTechnicalIndicatorPoint]] = [:]
    var technicalIndicatorCacheVersion: Int? = currentTechnicalIndicatorCacheVersion
    var rangeMetadata: [String: StockChartStoredRangeMetadata]

    /// A successful check with no new prices need not rewrite the whole
    /// history and indicator cache. Fetch times remain current in memory.
    func hasSameContent(as other: Self) -> Bool {
        guard version == other.version, market == other.market, symbol == other.symbol,
              series == other.series, derivedSeries == other.derivedSeries,
              technicalIndicators == other.technicalIndicators,
              technicalIndicatorCacheVersion == other.technicalIndicatorCacheVersion else { return false }
        var metadata = rangeMetadata
        for (key, var value) in metadata {
            value.fetchedAt = other.rangeMetadata[key]?.fetchedAt ?? value.fetchedAt
            metadata[key] = value
        }
        return metadata == other.rangeMetadata
    }
}

private enum StockChartTechnicalCacheKind: String {
    case minute
    case daily
}

struct StockChartDiskStore {
    private let fileManager: FileManager
    private let persistentStoreDirectory: URL
    private var memoryStores: [StockChartStoreKey: StockChartPersistedStore] = [:]
    private var recentKeys: [StockChartStoreKey] = []
    private var lastSuccessfulWriteAt: [StockChartStoreKey: Date] = [:]
    // Keep unreadable/unsupported files intact, including when fresh network
    // data becomes available. Only an explicit cache clear removes this block.
    private var blockedWrites: Set<StockChartStoreKey> = []
    private let memoryCapacity: Int
    var cachedStockCount: Int { memoryStores.count }

    init(
        fileManager: FileManager = .default,
        persistentStoreDirectory: URL? = nil,
        memoryCapacity: Int = 32
    ) {
        self.fileManager = fileManager
        self.memoryCapacity = max(1, memoryCapacity)
        let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? cacheDirectory
        self.persistentStoreDirectory = persistentStoreDirectory ?? supportDirectory
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("StockCharts", isDirectory: true)
    }

    mutating func load(for key: StockChartStoreKey) -> StockChartPersistedStore? {
        if var stored = memoryStores[key],
           (7...StockChartPersistedStore.currentVersion).contains(stored.version),
           stored.market == key.market,
           stored.symbol == key.symbol {
            remember(stored, for: key)
            if migrateExtendedMinuteCacheIfNeeded(in: &stored) {
                save(stored, for: key, validatingWrite: true)
            }
            if refreshTechnicalIndicatorCachesIfNeeded(in: &stored) {
                save(stored, for: key)
            }
            return stored
        }
        memoryStores[key] = nil
        let url = persistentStoreURL(for: key)
        if let data = try? Data(contentsOf: url) {
            guard var stored = try? JSONDecoder().decode(
                StockChartPersistedStore.self,
                from: data
            ),
            (6...StockChartPersistedStore.currentVersion).contains(stored.version),
            stored.market == key.market,
            stored.symbol == key.symbol else {
                blockedWrites.insert(key)
                DiagnosticLogger.shared.log(.stockQuote,
                    "离线行情无法读取或版本不支持，保留原文件并阻断覆盖 symbol=\(key.symbol)", level: .warning)
                return nil
            }
            let originalVersion = stored.version
            if originalVersion < StockChartPersistedStore.currentVersion {
                do {
                    let recoveryURL = url.appendingPathExtension("v\(originalVersion).recovery")
                    if !fileManager.fileExists(atPath: recoveryURL.path) {
                        try data.write(to: recoveryURL, options: .atomic)
                    }
                } catch {
                    blockedWrites.insert(key)
                    DiagnosticLogger.logError(.stockQuote, operation: "行情迁移快照", error: error)
                    return nil
                }
            }
            let didMigrate = migrateExtendedMinuteCacheIfNeeded(in: &stored)
            if refreshTechnicalIndicatorCachesIfNeeded(in: &stored) || didMigrate {
                save(stored, for: key, validatingWrite: didMigrate)
                return stored
            }
            remember(stored, for: key)
            return stored
        }

        if fileManager.fileExists(atPath: url.path) {
            blockedWrites.insert(key)
            DiagnosticLogger.shared.log(.stockQuote, "离线行情文件暂不可读，保留原文件 symbol=\(key.symbol)", level: .warning)
        }
        return nil
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
    mutating func save(
        _ store: StockChartPersistedStore,
        for key: StockChartStoreKey,
        validatingWrite: Bool = false,
        at now: Date = Date()
    ) -> Bool {
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
        let previous = memoryStores[key]
        let lastWrite = lastSuccessfulWriteAt[key]
        remember(store, for: key)
        guard !blockedWrites.contains(key) else { return false }
        if !validatingWrite, let previous, let lastWrite,
           (0..<300).contains(now.timeIntervalSince(lastWrite)),
           previous.hasSameContent(as: store),
           fileManager.fileExists(atPath: persistentStoreURL(for: key).path) {
            return true
        }
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
            if validatingWrite {
                let stagingURL = persistentStoreDirectory.appendingPathComponent("migration-\(UUID().uuidString).tmp")
                defer { try? fileManager.removeItem(at: stagingURL) }
                try data.write(to: stagingURL, options: .atomic)
                let verifiedData = try Data(contentsOf: stagingURL)
                let verified = try JSONDecoder().decode(StockChartPersistedStore.self, from: verifiedData)
                guard verifiedData == data, verified.series == store.series,
                      verified.version == store.version, verified.market == key.market,
                      verified.symbol == key.symbol else {
                    blockedWrites.insert(key)
                    return false
                }
            }
            try data.write(to: persistentStoreURL(for: key), options: .atomic)
            lastSuccessfulWriteAt[key] = now
            DiagnosticLogger.shared.log(.stockQuote,
                "离线行情写入 symbol=\(key.symbol) bytes=\(data.count) daily=\(store.series[StockChartSeriesKind.daily.rawValue]?.count ?? 0) minute=\(store.series[StockChartSeriesKind.intraday.rawValue]?.count ?? 0) post=\(store.series[StockChartSeriesKind.postMarketMinute.rawValue]?.count ?? 0)")
            return true
        } catch {
            lastSuccessfulWriteAt[key] = nil
            if validatingWrite { blockedWrites.insert(key) }
            DiagnosticLogger.shared.log(
                .stockQuote,
                "离线行情文件写入失败：\(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    mutating func removeAll() {
        lastSuccessfulWriteAt.removeAll()
        blockedWrites.removeAll()
        recentKeys.removeAll()
        memoryStores.removeAll()
        guard fileManager.fileExists(atPath: persistentStoreDirectory.path) else { return }
        do {
            try fileManager.removeItem(at: persistentStoreDirectory)
        } catch {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "离线行情缓存清理失败：\(error.localizedDescription)",
                level: .warning
            )
        }
    }

    mutating func remove(for key: StockChartStoreKey) {
        lastSuccessfulWriteAt[key] = nil
        blockedWrites.remove(key)
        memoryStores.removeValue(forKey: key)
        let url = persistentStoreURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "离线行情缓存删除失败（\(key.symbol)）：\(error.localizedDescription)",
                level: .warning
            )
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

        let dailyPoints = store.series[StockChartSeriesKind.daily.rawValue] ?? []
        let rawMinutePoints = store.series[StockChartSeriesKind.intraday.rawValue] ?? []
        let rawPreMarketPoints = store.series[
            StockChartSeriesKind.preMarketMinute.rawValue
        ] ?? []
        let rawPostMarketPoints = store.series[
            StockChartSeriesKind.postMarketMinute.rawValue
        ] ?? []
        let storedPoints: [StockChartPoint]
        if let derivedKind = StockChartSeriesProcessor.derivedSeriesKind(for: range),
           let cachedPoints = store.derivedSeries[derivedKind.rawValue],
           !cachedPoints.isEmpty {
            storedPoints = cachedPoints
        } else if range.isKLineRange, !dailyPoints.isEmpty {
            storedPoints = StockChartSeriesProcessor.preparedKLinePoints(
                dailyPoints,
                range: range,
                market: store.market
            )
        } else {
            storedPoints = range.isMinuteRange ? rawMinutePoints : dailyPoints
        }
        // The canonical daily source is the reliable listing boundary for all
        // current K-line tabs.
        let inceptionDate = dailyPoints.map(\.date).min()
            ?? StockChartSeriesProcessor.inceptionDate(in: store.series)
        let points = StockChartSeriesProcessor.visiblePoints(
            from: storedPoints,
            for: range,
            market: store.market,
            inceptionDate: inceptionDate
        )
        guard !points.isEmpty || (range == .intraday && (!rawPreMarketPoints.isEmpty || !rawPostMarketPoints.isEmpty)) else {
            return nil
        }
        let indicatorPoints: [StockChartPoint]
        if range.isMinuteRange {
            // Keep the complete minute history for indicator warm-up. The
            // presentation layer draws only `points`, which are already
            // scoped to the latest session or latest five trading days.
            indicatorPoints = rawMinutePoints
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
            preMarketPoints: StockChartSeriesProcessor.pointsOnLatestTradingDay(
                rawPreMarketPoints,
                market: store.market,
                at: metadata.fetchedAt
            ),
            postMarketPoints: StockChartSeriesProcessor.pointsOnLatestTradingDay(
                rawPostMarketPoints,
                market: store.market,
                at: metadata.fetchedAt
            ),
            dailyIndicatorPoints: dailyPoints,
            cachedMinuteTechnicalIndicators: store.technicalIndicators[
                StockChartTechnicalCacheKind.minute.rawValue
            ],
            cachedDailyTechnicalIndicators: store.technicalIndicators[
                StockChartTechnicalCacheKind.daily.rawValue
            ],
            quoteUpdatedAt: range.isMinuteRange
                ? [points.last?.date, rawPreMarketPoints.last?.date, rawPostMarketPoints.last?.date].compactMap { $0 }.max()
                : points.last?.date
        )
    }

    func hasRequestedCoverage(
        in store: StockChartPersistedStore,
        for range: StockChartRange
    ) -> Bool {
        if range == .fiveDays {
            let calendar = StockChartSeriesProcessor.marketCalendar(store.market)
            let points = store.series[StockChartSeriesKind.intraday.rawValue] ?? []
            let days = Set(points.map { calendar.startOfDay(for: $0.date) })
            if var day = days.max() {
                var expected: Set<Date> = [day]
                for _ in 0..<4 {
                    guard let previous = StockMarketTradingCalendar.previousTradingDay(for: store.market, before: day) else { break }
                    day = calendar.startOfDay(for: previous)
                    expected.insert(day)
                }
                if expected.count == 5, expected.isSubset(of: days) { return true }
            }
            // Newly listed stocks may have fewer than five days. An explicit
            // history fetch distinguishes that from a one-day-only cache.
            guard let history = store.rangeMetadata[StockChartRange.fiveDays.rawValue],
                  let latest = points.map(\.date).max() else { return false }
            return calendar.startOfDay(for: history.fetchedAt) >= calendar.startOfDay(for: latest)
        }
        return StockChartSeriesProcessor.compatibleMetadataRanges(for: range).contains {
            guard let metadata = store.rangeMetadata[$0.rawValue] else { return false }
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

    private func merge(
        _ snapshot: StockChartSnapshot,
        range: StockChartRange,
        into store: inout StockChartPersistedStore
    ) {
        // `merging` is also used directly by tests and import-like callers,
        // so do not rely on every store having passed through `load` first.
        refreshTechnicalIndicatorCachesIfNeeded(in: &store)
        let kind = StockChartSeriesProcessor.seriesKind(for: range)
        let incomingPoints: [StockChartPoint]
        if range.isKLineRange {
            incomingPoints = snapshot.dailyIndicatorPoints
                ?? snapshot.indicatorPoints
                ?? snapshot.points
        } else {
            incomingPoints = StockChartSeriesProcessor.regularSessionPoints(
                snapshot.indicatorPoints ?? snapshot.points,
                market: store.market
            )
        }
        let existing = store.series[kind.rawValue] ?? []
        store.series[kind.rawValue] = StockChartSeriesProcessor.mergedPoints(
            existing,
            with: incomingPoints,
            kind: kind,
            market: store.market
        )
        if range.isMinuteRange {
            mergeExtendedMinuteSeries(
                snapshot.preMarketPoints,
                kind: .preMarketMinute,
                into: &store
            )
            mergeExtendedMinuteSeries(
                snapshot.postMarketPoints,
                kind: .postMarketMinute,
                into: &store
            )
            pruneMinuteSeries(in: &store, at: snapshot.fetchedAt)
            rebuildMinuteDerivedCaches(
                in: &store,
                at: snapshot.fetchedAt,
                rebuildIndicators: existing != (store.series[kind.rawValue] ?? [])
            )
        } else if range.isKLineRange {
            if existing != (store.series[kind.rawValue] ?? [])
                || store.derivedSeries[StockChartSeriesKind.weekly.rawValue] == nil {
                rebuildDailyDerivedCaches(in: &store)
            }
        }
        store.rangeMetadata[range.rawValue] = StockChartStoredRangeMetadata(snapshot: snapshot)
    }

    private func mergeExtendedMinuteSeries(
        _ incoming: [StockChartPoint],
        kind: StockChartSeriesKind,
        into store: inout StockChartPersistedStore
    ) {
        guard !incoming.isEmpty else { return }
        store.series[kind.rawValue] = StockChartSeriesProcessor.mergedPoints(
            store.series[kind.rawValue] ?? [],
            with: incoming,
            kind: kind,
            market: store.market
        )
    }

    /// Version 8 added dedicated pre/post-market minute series. Version 7's
    /// regular and daily sources are still valid, so upgrade them locally
    /// instead of deleting every chart and forcing the user to wait for all
    /// ranges to download again after installing the update.
    private func migrateExtendedMinuteCacheIfNeeded(
        in store: inout StockChartPersistedStore
    ) -> Bool {
        guard (6...7).contains(store.version) else { return false }
        if store.version == 6 {
            let original = store.series[StockChartSeriesKind.intraday.rawValue] ?? []
            // Repair only the erroneous US boundary, never discard daily bars.
            mergeExtendedMinuteSeries(
                StockChartSeriesProcessor.postMarketSessionPoints(original, market: store.market),
                kind: .postMarketMinute, into: &store
            )
            store.series[StockChartSeriesKind.intraday.rawValue] =
                StockChartSeriesProcessor.regularSessionPoints(original, market: store.market)
        }
        let latestMetadata = store.rangeMetadata.values.max {
            $0.fetchedAt < $1.fetchedAt
        }
        for metadata in store.rangeMetadata.values.sorted(by: { $0.fetchedAt < $1.fetchedAt }) {
            mergeExtendedMinuteSeries(
                metadata.preMarketPoints,
                kind: .preMarketMinute,
                into: &store
            )
            mergeExtendedMinuteSeries(
                metadata.postMarketPoints,
                kind: .postMarketMinute,
                into: &store
            )
        }
        if let latestMetadata {
            pruneMinuteSeries(in: &store, at: latestMetadata.fetchedAt)
            rebuildMinuteDerivedCaches(in: &store, at: latestMetadata.fetchedAt)
        }
        store.version = StockChartPersistedStore.currentVersion
        return true
    }

    /// Minute history is only needed by the real-time and five-day views.
    /// Keep seven actual trading days (not seven calendar days); the daily
    /// source remains unbounded and backs every K-line aggregation.
    private func pruneMinuteSeries(
        in store: inout StockChartPersistedStore,
        at date: Date
    ) {
        for kind in [
            StockChartSeriesKind.intraday,
            .preMarketMinute,
            .postMarketMinute
        ] {
            store.series[kind.rawValue] = StockChartSeriesProcessor.pointsOnLatestTradingDays(
                store.series[kind.rawValue] ?? [],
                count: 7,
                market: store.market,
                at: date
            )
        }
    }

    private func rebuildMinuteDerivedCaches(
        in store: inout StockChartPersistedStore,
        at date: Date,
        rebuildIndicators: Bool = true
    ) {
        let rawPoints = store.series[StockChartSeriesKind.intraday.rawValue] ?? []
        let regularPoints = StockChartSeriesProcessor.regularSessionPoints(
            rawPoints,
            market: store.market
        )
        store.derivedSeries[StockChartSeriesKind.fiveDayMinute.rawValue] =
            StockChartSeriesProcessor.pointsOnLatestTradingDays(
                regularPoints,
                count: 5,
                market: store.market,
                at: date
            )
        if rebuildIndicators {
            store.technicalIndicators[StockChartTechnicalCacheKind.minute.rawValue] =
                StockTechnicalIndicators.calculate(regularPoints.sorted { $0.date < $1.date })
        }
    }

    private func rebuildDailyDerivedCaches(
        in store: inout StockChartPersistedStore
    ) {
        let dailyPoints = (store.series[StockChartSeriesKind.daily.rawValue] ?? [])
            .sorted { $0.date < $1.date }
        let calendar = StockChartSeriesProcessor.marketCalendar(store.market)
        store.derivedSeries[StockChartSeriesKind.weekly.rawValue] =
            StockChartSeriesProcessor.weeklyPoints(from: dailyPoints, calendar: calendar)
        store.derivedSeries[StockChartSeriesKind.monthly.rawValue] =
            StockChartSeriesProcessor.monthlyPoints(from: dailyPoints, calendar: calendar)
        store.derivedSeries[StockChartSeriesKind.quarterly.rawValue] =
            StockChartSeriesProcessor.preparedKLinePoints(
                dailyPoints,
                range: .quarterK,
                market: store.market
            )
        store.derivedSeries[StockChartSeriesKind.yearly.rawValue] =
            StockChartSeriesProcessor.preparedKLinePoints(
                dailyPoints,
                range: .yearK,
                market: store.market
            )
        store.technicalIndicators[StockChartTechnicalCacheKind.daily.rawValue] =
            StockTechnicalIndicators.calculate(dailyPoints)
    }

    /// Rebuilds advanced indicator fields from the canonical local OHLCV
    /// series. Returning `true` lets `load` persist the migration exactly once.
    @discardableResult
    private func refreshTechnicalIndicatorCachesIfNeeded(
        in store: inout StockChartPersistedStore
    ) -> Bool {
        let rawMinutePoints = store.series[StockChartSeriesKind.intraday.rawValue] ?? []
        let dailyPoints = store.series[StockChartSeriesKind.daily.rawValue] ?? []
        let cachedMinuteCount = store.technicalIndicators[
            StockChartTechnicalCacheKind.minute.rawValue
        ]?.count ?? 0
        let cachedDailyCount = store.technicalIndicators[
            StockChartTechnicalCacheKind.daily.rawValue
        ]?.count ?? 0
        let versionChanged = store.technicalIndicatorCacheVersion
            != StockChartPersistedStore.currentTechnicalIndicatorCacheVersion
        let refreshMinute = versionChanged || cachedMinuteCount != rawMinutePoints.count
        let refreshDaily = versionChanged || cachedDailyCount != dailyPoints.count
        guard refreshMinute || refreshDaily else { return false }
        if refreshMinute {
            let minutePoints = StockChartSeriesProcessor.regularSessionPoints(rawMinutePoints, market: store.market)
                .sorted { $0.date < $1.date }
            store.technicalIndicators[StockChartTechnicalCacheKind.minute.rawValue] =
                StockTechnicalIndicators.calculate(minutePoints)
        }
        if refreshDaily {
            store.technicalIndicators[StockChartTechnicalCacheKind.daily.rawValue] =
                StockTechnicalIndicators.calculate(dailyPoints.sorted { $0.date < $1.date })
        }
        store.technicalIndicatorCacheVersion =
            StockChartPersistedStore.currentTechnicalIndicatorCacheVersion
        return true
    }

    private func fileName(for identifier: String) -> String {
        Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }

    private mutating func remember(_ store: StockChartPersistedStore, for key: StockChartStoreKey) {
        memoryStores[key] = store
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
        while recentKeys.count > memoryCapacity {
            let evicted = recentKeys.removeFirst()
            memoryStores[evicted] = nil
            lastSuccessfulWriteAt[evicted] = nil
        }
    }
}

#endif
