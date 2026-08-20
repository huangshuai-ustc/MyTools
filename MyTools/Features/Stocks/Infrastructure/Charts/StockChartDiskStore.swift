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

    private enum CodingKeys: String, CodingKey {
        case symbol, name, currencyCode, previousClose, preMarketPoints, postMarketPoints
        case quoteUpdatedAt, fetchedAt, source, supportsCandlesticks, indicatorPointCount
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
        indicatorPointCount: Int?
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
    }

    func snapshot(
        points: [StockChartPoint],
        indicatorPoints: [StockChartPoint]
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
        let metadata = compatibleMetadata ?? StockChartRange.allCases
            .filter {
                StockChartSeriesProcessor.seriesKind(for: $0)
                    == StockChartSeriesProcessor.seriesKind(for: range)
            }
            .compactMap { store.rangeMetadata[$0.rawValue] }
            .max { $0.fetchedAt < $1.fetchedAt }
        guard let metadata else { return nil }

        let kind = StockChartSeriesProcessor.seriesKind(for: range)
        let storedPoints = store.series[kind.rawValue] ?? []
        let inceptionDate = StockChartSeriesProcessor.inceptionDate(in: store.series)
        let points = StockChartSeriesProcessor.visiblePoints(
            from: storedPoints,
            for: range,
            market: store.market,
            inceptionDate: inceptionDate
        )
        guard !points.isEmpty else { return nil }
        return metadata.snapshot(
            points: points,
            indicatorPoints: StockChartSeriesProcessor.indicatorPoints(
                from: storedPoints,
                visiblePoints: points,
                range: range
            )
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
        for range in StockChartRange.allCases {
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
        let existing = store.series[kind.rawValue] ?? []
        store.series[kind.rawValue] = StockChartSeriesProcessor.mergedPoints(
            existing,
            with: snapshot.indicatorPoints ?? snapshot.points,
            kind: kind,
            market: store.market
        )
        store.rangeMetadata[range.rawValue] = StockChartStoredRangeMetadata(snapshot: snapshot)
    }

    private func fileName(for identifier: String) -> String {
        Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }
}

#endif
