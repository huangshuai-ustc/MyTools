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
        dailyIndicatorPoints: [StockChartPoint]? = nil,
        cachedMinuteTechnicalIndicators: [StockTechnicalIndicatorPoint]? = nil,
        cachedDailyTechnicalIndicators: [StockTechnicalIndicatorPoint]? = nil
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
            cachedMinuteTechnicalIndicators: cachedMinuteTechnicalIndicators,
            cachedDailyTechnicalIndicators: cachedDailyTechnicalIndicators,
            quoteUpdatedAt: points.last?.date ?? quoteUpdatedAt,
            fetchedAt: fetchedAt,
            source: source,
            supportsCandlesticks: supportsCandlesticks
        )
    }
}

struct StockChartPersistedStore: Codable, Sendable {
    static let currentVersion = 5

    let version: Int
    let market: StockMarket
    let symbol: String
    var series: [String: [StockChartPoint]]
    var derivedSeries: [String: [StockChartPoint]] = [:]
    var technicalIndicators: [String: [StockTechnicalIndicatorPoint]] = [:]
    var rangeMetadata: [String: StockChartStoredRangeMetadata]
}

private enum StockChartTechnicalCacheKind: String {
    case minute
    case daily
}

struct StockChartDiskStore {
    private let fileManager: FileManager
    private let persistentStoreDirectory: URL
    private var memoryStores: [StockChartStoreKey: StockChartPersistedStore] = [:]

    init(
        fileManager: FileManager = .default,
        persistentStoreDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
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
        guard !points.isEmpty else { return nil }
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
            dailyIndicatorPoints: dailyPoints,
            cachedMinuteTechnicalIndicators: store.technicalIndicators[
                StockChartTechnicalCacheKind.minute.rawValue
            ],
            cachedDailyTechnicalIndicators: store.technicalIndicators[
                StockChartTechnicalCacheKind.daily.rawValue
            ]
        )
    }

    func hasRequestedCoverage(
        in store: StockChartPersistedStore,
        for range: StockChartRange
    ) -> Bool {
        StockChartSeriesProcessor.compatibleMetadataRanges(for: range).contains {
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
            rebuildMinuteDerivedCaches(
                in: &store,
                at: snapshot.fetchedAt
            )
        } else if range.isKLineRange {
            rebuildDailyDerivedCaches(in: &store)
        }
        store.rangeMetadata[range.rawValue] = StockChartStoredRangeMetadata(snapshot: snapshot)
    }

    private func rebuildMinuteDerivedCaches(
        in store: inout StockChartPersistedStore,
        at date: Date
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
        store.technicalIndicators[StockChartTechnicalCacheKind.minute.rawValue] =
            StockTechnicalIndicators.calculate(regularPoints.sorted { $0.date < $1.date })
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

    private func fileName(for identifier: String) -> String {
        Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }
}

#endif
