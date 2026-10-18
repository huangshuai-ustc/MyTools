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
    // Version 9 splits the file into a daily part and a minute part
    // (`StockChartStoredPart`). Derived K-lines and technical indicators are
    // rebuilt on load instead of being written: they were ~80% of each file,
    // and every minute refresh used to rewrite decades of daily history.
    // Single-file versions 6...8 are migrated on first load.
    static let currentVersion = 9
    static let legacySingleFileVersions = 6...8
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
}

enum StockChartTechnicalCacheKind: String {
    case minute
    case daily
}

/// The two files a stock's chart cache is written to. Minute data changes
/// every minute during a session; daily history rarely changes except for
/// today's bar, so the two are written independently.
enum StockChartStorePart: String, CaseIterable, Codable, Sendable {
    case daily
    case minute

    private static let minuteSeriesKeys: Set<String> = [
        StockChartSeriesKind.intraday.rawValue,
        StockChartSeriesKind.preMarketMinute.rawValue,
        StockChartSeriesKind.postMarketMinute.rawValue
    ]
    private static let minuteRangeKeys = Set(
        StockChartRange.allCases.filter(\.isMinuteRange).map(\.rawValue)
    )

    func ownsSeries(_ key: String) -> Bool {
        Self.minuteSeriesKeys.contains(key) == (self == .minute)
    }

    func ownsRange(_ key: String) -> Bool {
        Self.minuteRangeKeys.contains(key) == (self == .minute)
    }

    func file(of store: StockChartPersistedStore) -> StockChartStoredPart {
        StockChartStoredPart(
            version: store.version,
            market: store.market,
            symbol: store.symbol,
            part: self,
            series: store.series.filter { ownsSeries($0.key) },
            rangeMetadata: store.rangeMetadata.filter { ownsRange($0.key) }
        )
    }
}

/// On-disk form of one `StockChartStorePart`: raw OHLCV series and fetch
/// metadata only. Everything derived is rebuilt in memory on load.
struct StockChartStoredPart: Codable, Equatable, Sendable {
    let version: Int
    let market: StockMarket
    let symbol: String
    let part: StockChartStorePart
    var series: [String: [StockChartPoint]]
    var rangeMetadata: [String: StockChartStoredRangeMetadata]

    /// Changes that may wait for the next checkpoint: any minute refresh, or a
    /// daily refresh that only touched the latest bar (today's bar while the
    /// session is open, or the first print of a new day). Historical
    /// corrections, new history, and newly fetched ranges write immediately.
    func canDeferWrite(after previous: Self) -> Bool {
        guard version == previous.version, market == previous.market,
              symbol == previous.symbol, part == previous.part,
              Set(rangeMetadata.keys) == Set(previous.rangeMetadata.keys) else { return false }
        guard part == .daily else { return true }
        let dailyKey = StockChartSeriesKind.daily.rawValue
        var others = series
        var previousOthers = previous.series
        let daily = others.removeValue(forKey: dailyKey) ?? []
        let previousDaily = previousOthers.removeValue(forKey: dailyKey) ?? []
        guard others == previousOthers else { return false }
        switch daily.count - previousDaily.count {
        case 0: return daily.dropLast() == previousDaily.dropLast()
        case 1: return daily.prefix(previousDaily.count) == previousDaily[...]
        default: return false
        }
    }
}

extension StockChartStorePart {
    /// How long a deferrable change may stay memory-only. Minute data is
    /// re-fetchable within one request; today's daily bar changes every
    /// refresh but is only needed after relaunch, and `flushPendingWrites`
    /// writes both before the app is suspended.
    var coalescingWindow: TimeInterval {
        switch self {
        case .minute: return 600
        case .daily: return 1_800
        }
    }
}

/// Single-file layout used by versions 6...8. Only raw series and metadata
/// are read; the persisted derived bars and indicators are rebuilt anyway.
private struct StockChartLegacySingleFile: Decodable {
    let version: Int
    let market: StockMarket
    let symbol: String
    let series: [String: [StockChartPoint]]
    let rangeMetadata: [String: StockChartStoredRangeMetadata]
}

struct StockChartDiskStore {
    private let fileManager: FileManager
    private let persistentStoreDirectory: URL
    private var memoryStores: [StockChartStoreKey: StockChartPersistedStore] = [:]
    private var recentKeys: [StockChartStoreKey] = []
    /// Successful write time of each part, seeded from the file modification
    /// date on load so a relaunch does not immediately rewrite fresh files.
    private var lastSuccessfulWriteAt: [StockChartStoreKey: [StockChartStorePart: Date]] = [:]
    /// Parts whose in-memory content is newer than the file.
    private var dirtyParts: [StockChartStoreKey: Set<StockChartStorePart>] = [:]
    // Keep unreadable/unsupported files intact, including when fresh network
    // data becomes available. Only an explicit cache clear removes this block.
    private var blockedWrites: Set<StockChartStoreKey> = []
    private var isDirectoryPrepared = false
    private let memoryCapacity: Int
    var cachedStockCount: Int { memoryStores.count }
    var pendingWriteCount: Int { dirtyParts.values.reduce(0) { $0 + $1.count } }

    init(
        fileManager: FileManager = .default,
        persistentStoreDirectory: URL? = nil,
        // Every refresh round touches each holding once; a capacity below the
        // holding count turns each round into full reloads (decode + rebuild).
        memoryCapacity: Int = 48
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
           stored.version == StockChartPersistedStore.currentVersion,
           stored.market == key.market,
           stored.symbol == key.symbol {
            // Stores handed straight to `save` may not have been through `merge`.
            refreshTechnicalIndicatorCachesIfNeeded(in: &stored)
            remember(stored, for: key)
            return stored
        }
        memoryStores[key] = nil
        let existingParts = StockChartStorePart.allCases.filter {
            fileManager.fileExists(atPath: partURL(for: key, part: $0).path)
        }
        guard !existingParts.isEmpty else { return loadLegacySingleFile(for: key) }
        let started = Date()
        var store = emptyStore(for: key)
        var bytes = 0
        for part in existingParts {
            let url = partURL(for: key, part: part)
            guard let data = try? Data(contentsOf: url) else {
                blockedWrites.insert(key)
                DiagnosticLogger.shared.log(.stockQuote, "离线行情文件暂不可读，保留原文件 symbol=\(key.symbol) part=\(part.rawValue)", level: .warning)
                return nil
            }
            guard let file = try? JSONDecoder().decode(StockChartStoredPart.self, from: data),
                  file.version == StockChartPersistedStore.currentVersion,
                  file.market == key.market, file.symbol == key.symbol, file.part == part else {
                blockedWrites.insert(key)
                DiagnosticLogger.shared.log(.stockQuote,
                    "离线行情无法读取或版本不支持，保留原文件并阻断覆盖 symbol=\(key.symbol) part=\(part.rawValue)", level: .warning)
                return nil
            }
            bytes += data.count
            store.series.merge(file.series.filter { part.ownsSeries($0.key) }) { current, _ in current }
            store.rangeMetadata.merge(file.rangeMetadata.filter { part.ownsRange($0.key) }) { current, _ in current }
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                lastSuccessfulWriteAt[key, default: [:]][part] = modified
            }
        }
        rebuildDerivedCaches(in: &store)
        remember(store, for: key)
        DiagnosticLogger.shared.log(.stockQuote, "离线行情载入 symbol=\(key.symbol) bytes=\(bytes) daily=\(store.series[StockChartSeriesKind.daily.rawValue]?.count ?? 0) minute=\(store.series[StockChartSeriesKind.intraday.rawValue]?.count ?? 0) ms=\(Int(Date().timeIntervalSince(started) * 1000)) resident=\(memoryStores.count)")
        return store
    }

    /// Splits a version 6...8 single file into the two part files. Versions
    /// 6 and 7 changed minute content during migration, so their original is
    /// kept as `.v{N}.recovery`; version 8 is a pure re-layout and the old
    /// file (up to tens of MB per stock) is removed once both parts verify.
    private mutating func loadLegacySingleFile(for key: StockChartStoreKey) -> StockChartPersistedStore? {
        let url = legacyStoreURL(for: key)
        guard let data = try? Data(contentsOf: url) else {
            if fileManager.fileExists(atPath: url.path) {
                blockedWrites.insert(key)
                DiagnosticLogger.shared.log(.stockQuote, "离线行情文件暂不可读，保留原文件 symbol=\(key.symbol)", level: .warning)
            }
            return nil
        }
        guard let legacy = try? JSONDecoder().decode(StockChartLegacySingleFile.self, from: data),
              StockChartPersistedStore.legacySingleFileVersions.contains(legacy.version),
              legacy.market == key.market,
              legacy.symbol == key.symbol else {
            blockedWrites.insert(key)
            DiagnosticLogger.shared.log(.stockQuote,
                "离线行情无法读取或版本不支持，保留原文件并阻断覆盖 symbol=\(key.symbol)", level: .warning)
            return nil
        }
        let started = Date()
        var store = StockChartPersistedStore(
            version: legacy.version,
            market: legacy.market,
            symbol: legacy.symbol,
            series: legacy.series,
            rangeMetadata: legacy.rangeMetadata
        )
        migrateExtendedMinuteCacheIfNeeded(in: &store)
        store.version = StockChartPersistedStore.currentVersion
        rebuildDerivedCaches(in: &store)
        // A failed verification blocks writes; the legacy file stays intact.
        guard save(store, for: key, validatingWrite: true) else { return store }
        do {
            let recoveryURL = url.appendingPathExtension("v\(legacy.version).recovery")
            if legacy.version < 8, !fileManager.fileExists(atPath: recoveryURL.path) {
                try fileManager.moveItem(at: url, to: recoveryURL)
            } else {
                try fileManager.removeItem(at: url)
            }
        } catch {
            DiagnosticLogger.logError(.stockQuote, operation: "行情迁移清理旧文件", error: error)
        }
        DiagnosticLogger.shared.log(.stockQuote, "离线行情已拆分存储 symbol=\(key.symbol) from=v\(legacy.version) legacyBytes=\(data.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return store
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
        remember(store, for: key)
        guard !blockedWrites.contains(key) else { return false }
        var succeeded = true
        for part in StockChartStorePart.allCases {
            let file = part.file(of: store)
            let previousFile = previous.map(part.file(of:))
            let fileExists = fileManager.fileExists(atPath: partURL(for: key, part: part).path)
            let isDirty = dirtyParts[key]?.contains(part) == true
            if !validatingWrite, fileExists, !isDirty, previousFile == file { continue }
            // 内存中始终是最新数据。分钟刷新和只动最新一根日线的刷新在窗口内只记待写，
            // 到期或进入后台时落盘；历史修正、新增区间、迁移和失败重试立即写入。
            // 进程被杀最多丢失一个窗口内可重新拉取的数据（AUDIT-057）。
            if !validatingWrite, fileExists, let previousFile,
               file.canDeferWrite(after: previousFile),
               let lastWrite = lastSuccessfulWriteAt[key]?[part],
               (0..<part.coalescingWindow).contains(now.timeIntervalSince(lastWrite)) {
                dirtyParts[key, default: []].insert(part)
                continue
            }
            succeeded = write(file, for: key, validating: validatingWrite, at: now) && succeeded
            if blockedWrites.contains(key) { return false }
        }
        return succeeded
    }

    /// Writes every deferred part; called before the app is suspended.
    @discardableResult
    mutating func flushPendingWrites(at now: Date = Date()) -> Int {
        var written = 0
        for (key, parts) in dirtyParts {
            guard let store = memoryStores[key], !blockedWrites.contains(key) else {
                dirtyParts[key] = nil
                continue
            }
            for part in parts where write(part.file(of: store), for: key, validating: false, at: now) {
                written += 1
            }
        }
        return written
    }

    /// Releases every resident store after flushing deferred parts.
    mutating func trimMemory() {
        flushPendingWrites()
        memoryStores.removeAll()
        recentKeys.removeAll()
        dirtyParts.removeAll()
    }

    private mutating func write(
        _ file: StockChartStoredPart,
        for key: StockChartStoreKey,
        validating: Bool,
        at now: Date
    ) -> Bool {
        do {
            if !isDirectoryPrepared {
                try fileManager.createDirectory(at: persistentStoreDirectory, withIntermediateDirectories: true)
                var directory = persistentStoreDirectory
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try? directory.setResourceValues(resourceValues)
                isDirectoryPrepared = true
            }
            let started = Date()
            let data = try JSONEncoder().encode(file)
            if validating {
                let stagingURL = persistentStoreDirectory.appendingPathComponent("migration-\(UUID().uuidString).tmp")
                defer { try? fileManager.removeItem(at: stagingURL) }
                try data.write(to: stagingURL, options: .atomic)
                let verifiedData = try Data(contentsOf: stagingURL)
                let verified = try JSONDecoder().decode(StockChartStoredPart.self, from: verifiedData)
                guard verifiedData == data, verified == file else {
                    blockedWrites.insert(key)
                    return false
                }
            }
            try data.write(to: partURL(for: key, part: file.part), options: .atomic)
            lastSuccessfulWriteAt[key, default: [:]][file.part] = now
            dirtyParts[key]?.remove(file.part)
            if dirtyParts[key]?.isEmpty == true { dirtyParts[key] = nil }
            DiagnosticLogger.shared.log(.stockQuote,
                "离线行情写入 symbol=\(key.symbol) part=\(file.part.rawValue) bytes=\(data.count) daily=\(file.series[StockChartSeriesKind.daily.rawValue]?.count ?? 0) minute=\(file.series[StockChartSeriesKind.intraday.rawValue]?.count ?? 0) post=\(file.series[StockChartSeriesKind.postMarketMinute.rawValue]?.count ?? 0) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return true
        } catch {
            // Retry on the next save even if the content is identical, and
            // recreate the directory in case it was removed underneath us.
            lastSuccessfulWriteAt[key]?[file.part] = nil
            dirtyParts[key, default: []].insert(file.part)
            isDirectoryPrepared = false
            if validating { blockedWrites.insert(key) }
            DiagnosticLogger.shared.log(
                .stockQuote,
                "离线行情文件写入失败 part=\(file.part.rawValue)：\(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    mutating func removeAll() {
        lastSuccessfulWriteAt.removeAll()
        dirtyParts.removeAll()
        blockedWrites.removeAll()
        recentKeys.removeAll()
        memoryStores.removeAll()
        isDirectoryPrepared = false
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
        dirtyParts[key] = nil
        blockedWrites.remove(key)
        memoryStores.removeValue(forKey: key)
        recentKeys.removeAll { $0 == key }
        let urls = StockChartStorePart.allCases.map { partURL(for: key, part: $0) } + [legacyStoreURL(for: key)]
        for url in urls where fileManager.fileExists(atPath: url.path) {
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

    func partURL(for key: StockChartStoreKey, part: StockChartStorePart) -> URL {
        persistentStoreDirectory
            .appendingPathComponent(fileName(for: key), isDirectory: false)
            .appendingPathExtension(part.rawValue)
            .appendingPathExtension("json")
    }

    /// Single-file location used by versions 6...8.
    func legacyStoreURL(for key: StockChartStoreKey) -> URL {
        persistentStoreDirectory
            .appendingPathComponent(fileName(for: key), isDirectory: false)
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

    /// Derived K-lines, the five-day viewport and technical indicators are
    /// memory-only since version 9; rebuild them from the raw series.
    private func rebuildDerivedCaches(in store: inout StockChartPersistedStore) {
        let minuteDate = store.rangeMetadata
            .filter { StockChartStorePart.minute.ownsRange($0.key) }
            .values.map(\.fetchedAt).max()
            ?? store.series[StockChartSeriesKind.intraday.rawValue]?.last?.date
            ?? Date()
        rebuildMinuteDerivedCaches(in: &store, at: minuteDate)
        rebuildDailyDerivedCaches(in: &store)
        store.technicalIndicatorCacheVersion = StockChartPersistedStore.currentTechnicalIndicatorCacheVersion
    }

    /// Version 8 added dedicated pre/post-market minute series. Version 7's
    /// regular and daily sources are still valid, so upgrade them locally
    /// instead of deleting every chart and forcing the user to wait for all
    /// ranges to download again after installing the update.
    @discardableResult
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

    /// Rebuilds indicators whose count no longer matches the raw series, e.g.
    /// for stores built by hand rather than through `merge`.
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

    private func fileName(for key: StockChartStoreKey) -> String {
        Data("\(key.market.rawValue)|\(key.symbol)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }

    private mutating func remember(_ store: StockChartPersistedStore, for key: StockChartStoreKey) {
        memoryStores[key] = store
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
        while recentKeys.count > memoryCapacity {
            let evicted = recentKeys.removeFirst()
            // Deferred parts exist only in memory; write them before dropping.
            if let parts = dirtyParts[evicted], let evictedStore = memoryStores[evicted],
               !blockedWrites.contains(evicted) {
                for part in parts {
                    _ = write(part.file(of: evictedStore), for: evicted, validating: false, at: Date())
                }
            }
            dirtyParts[evicted] = nil
            memoryStores[evicted] = nil
            lastSuccessfulWriteAt[evicted] = nil
        }
    }
}

#endif
