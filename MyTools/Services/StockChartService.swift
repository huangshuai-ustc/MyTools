import Foundation

enum StockChartRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case intraday
    case fiveDays
    case oneMonth
    case threeMonths
    case oneYear
    case fiveYears
    case tenYears
    case sinceInception

    var id: Self { self }

    var title: String {
        switch self {
        case .intraday: return "分时"
        case .fiveDays: return "5 日"
        case .oneMonth: return "1 月"
        case .threeMonths: return "3 月"
        case .oneYear: return "1 年"
        case .fiveYears: return "5 年"
        case .tenYears: return "10 年"
        case .sinceInception: return "成立以来"
        }
    }

    fileprivate var yahooRange: String {
        switch self {
        case .intraday: return "5d"
        case .fiveDays: return "1mo"
        case .oneMonth: return "1mo"
        case .threeMonths: return "3mo"
        case .oneYear: return "1y"
        case .fiveYears: return "5y"
        case .tenYears: return "10y"
        case .sinceInception: return "max"
        }
    }

    fileprivate var yahooInterval: String {
        switch self {
        case .intraday: return "5m"
        case .fiveDays: return "15m"
        case .oneMonth, .threeMonths, .oneYear: return "1d"
        case .fiveYears, .tenYears: return "1wk"
        case .sinceInception: return "1mo"
        }
    }

    fileprivate var eastmoneyInterval: String {
        switch self {
        case .intraday: return "5"
        case .fiveDays: return "15"
        case .oneMonth, .threeMonths, .oneYear: return "101"
        case .fiveYears, .tenYears: return "102"
        case .sinceInception: return "103"
        }
    }

    fileprivate var eastmoneyLimit: Int {
        switch self {
        case .intraday, .fiveDays: return 500
        case .oneMonth: return 100
        case .threeMonths: return 150
        case .oneYear: return 330
        case .fiveYears: return 330
        case .tenYears: return 600
        case .sinceInception: return 1_500
        }
    }

    fileprivate var cacheLifetime: TimeInterval {
        switch self {
        case .intraday: return 20
        case .fiveDays: return 60
        case .oneMonth, .threeMonths, .oneYear: return 5 * 60
        case .fiveYears, .tenYears: return 15 * 60
        case .sinceInception: return 30 * 60
        }
    }
}

struct StockChartPoint: Identifiable, Codable, Equatable, Sendable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?

    var id: Date { date }
}

struct StockChartSnapshot: Codable, Equatable, Sendable {
    let symbol: String
    let name: String
    let currencyCode: String
    let previousClose: Double?
    let points: [StockChartPoint]
    let indicatorPoints: [StockChartPoint]?
    let quoteUpdatedAt: Date
    let fetchedAt: Date
    let source: String
    let supportsCandlesticks: Bool

    var latestPoint: StockChartPoint? { points.last }
}

enum StockChartError: LocalizedError, Sendable {
    case invalidSymbol
    case noData
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSymbol:
            return "股票代码无效。"
        case .noData:
            return "该时段暂无可用行情。"
        case .serviceUnavailable:
            return "暂时无法取得走势图，请稍后重试。"
        }
    }
}

actor StockChartService {
    static let shared = StockChartService()

    private enum SeriesKind: String, Codable {
        case intraday
        case fiveDayMinute
        case daily
        case weekly
        case monthly
    }

    private struct StockKey: Hashable {
        let market: StockMarket
        let symbol: String
    }

    private struct CacheKey: Hashable {
        let market: StockMarket
        let symbol: String
        let range: StockChartRange
    }

    private struct StoredRangeMetadata: Codable {
        let symbol: String
        let name: String
        let currencyCode: String
        let previousClose: Double?
        let quoteUpdatedAt: Date
        let fetchedAt: Date
        let source: String
        let supportsCandlesticks: Bool
        let indicatorPointCount: Int?

        init(snapshot: StockChartSnapshot) {
            symbol = snapshot.symbol
            name = snapshot.name
            currencyCode = snapshot.currencyCode
            previousClose = snapshot.previousClose
            quoteUpdatedAt = snapshot.quoteUpdatedAt
            fetchedAt = snapshot.fetchedAt
            source = snapshot.source
            supportsCandlesticks = snapshot.supportsCandlesticks
            indicatorPointCount = snapshot.indicatorPoints?.count
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
                indicatorPoints: indicatorPoints,
                quoteUpdatedAt: points.last?.date ?? quoteUpdatedAt,
                fetchedAt: fetchedAt,
                source: source,
                supportsCandlesticks: supportsCandlesticks
            )
        }
    }

    private struct PersistedStockChartStore: Codable {
        let version: Int
        let market: StockMarket
        let symbol: String
        var series: [String: [StockChartPoint]]
        var rangeMetadata: [String: StoredRangeMetadata]
    }

    // Decodes the range-based cache used before the local time-series store.
    private struct PersistedCacheEntry: Codable {
        let market: StockMarket
        let symbol: String
        let range: StockChartRange
        let snapshot: StockChartSnapshot
    }

    private struct YahooEnvelope: Decodable {
        let chart: YahooChart
    }

    private struct YahooChart: Decodable {
        let result: [YahooResult]?
    }

    private struct YahooResult: Decodable {
        let meta: YahooMeta
        let timestamp: [TimeInterval]?
        let indicators: YahooIndicators
    }

    private struct YahooMeta: Decodable {
        let currency: String?
        let symbol: String?
        let longName: String?
        let shortName: String?
        let chartPreviousClose: Double?
        let previousClose: Double?
    }

    private struct YahooIndicators: Decodable {
        let quote: [YahooQuoteValues]
    }

    private struct YahooQuoteValues: Decodable {
        let open: [Double?]?
        let high: [Double?]?
        let low: [Double?]?
        let close: [Double?]?
        let volume: [Double?]?
    }

    private struct EastmoneyEnvelope: Decodable {
        let data: EastmoneyPayload?
    }

    private struct EastmoneyPayload: Decodable {
        let code: String?
        let name: String?
        let preKPrice: FlexibleDouble?
        let klines: [String]?
    }

    private struct FlexibleDouble: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = Double(text)
            } else {
                value = nil
            }
        }
    }

    private let fileManager: FileManager
    private let persistentStoreDirectory: URL
    private let legacyCacheDirectory: URL
    private var stores: [StockKey: PersistedStockChartStore] = [:]
    private var lastRefreshAttemptAt: [CacheKey: Date] = [:]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        legacyCacheDirectory = cacheDirectory
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("StockCharts", isDirectory: true)
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? cacheDirectory
        persistentStoreDirectory = supportDirectory
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("StockCharts", isDirectory: true)
    }

    func cachedChart(
        for stock: StockHolding,
        range: StockChartRange
    ) -> StockChartSnapshot? {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { return nil }
        let key = StockKey(market: stock.market, symbol: symbol)
        guard let store = storedChartStore(for: key) else { return nil }
        return renderedSnapshot(from: store, range: range)
    }

    func fetchChart(
        for stock: StockHolding,
        range: StockChartRange,
        forceRefresh: Bool = false
    ) async throws -> StockChartSnapshot {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { throw StockChartError.invalidSymbol }

        let stockKey = StockKey(market: stock.market, symbol: symbol)
        let key = CacheKey(market: stock.market, symbol: symbol, range: range)
        let now = Date()
        let stored = storedChartStore(for: stockKey)
        let cached = stored.flatMap { renderedSnapshot(from: $0, range: range) }
        if let cached,
           let stored,
           hasRequestedCoverage(in: stored, for: range),
           shouldUseCachedChart(
                cached,
                for: key,
                forceRefresh: forceRefresh,
                now: now
           ) {
            return cached
        }

        do {
            lastRefreshAttemptAt[key] = now
            let snapshot = try await fetchRemoteChart(
                for: stock,
                symbol: symbol,
                range: range
            )
            var updatedStore = stored ?? emptyChartStore(for: stockKey)
            merge(snapshot, range: range, into: &updatedStore)
            stores[stockKey] = updatedStore
            persist(updatedStore, for: stockKey)
            return renderedSnapshot(from: updatedStore, range: range) ?? snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    private func fetchRemoteChart(
        for stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) async throws -> StockChartSnapshot {
        do {
            return try await fetchTencentChart(for: stock, symbol: symbol, range: range)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            if stock.market != .unitedStates,
               let fallback = try? await fetchEastmoneyChart(
                    for: stock,
                    symbol: symbol,
                    range: range
               ) {
                return fallback
            }
            if stock.market == .unitedStates,
               range == .intraday,
               let fallback = try? await fetchYahooChart(
                    for: stock,
                    symbol: symbol,
                    range: range
               ) {
                return fallback
            }
            if stock.market == .unitedStates,
               range != .fiveDays,
               range != .sinceInception,
               let fallback = try? await fetchNasdaqChart(
                    for: stock,
                    symbol: symbol,
                    range: range
               ) {
                return fallback
            }
            if !(stock.market == .unitedStates && range == .intraday),
               let fallback = try? await fetchYahooChart(
                for: stock,
                symbol: symbol,
                range: range
            ) {
                return fallback
            }
            guard !Task.isCancelled else { throw CancellationError() }
            throw StockChartError.serviceUnavailable
        }
    }

    private func shouldUseCachedChart(
        _ snapshot: StockChartSnapshot,
        for key: CacheKey,
        forceRefresh: Bool,
        now: Date
    ) -> Bool {
        if StockMarketTradingCalendar.isOpen(key.market, at: now) {
            return !forceRefresh
                && now.timeIntervalSince(snapshot.fetchedAt) < key.range.cacheLifetime
        }
        let sessionEnded = StockMarketTradingCalendar.sessionEnded(
            for: key.market,
            between: snapshot.fetchedAt,
            and: now
        )
        guard sessionEnded else { return true }
        if let lastAttempt = lastRefreshAttemptAt[key],
           now.timeIntervalSince(lastAttempt) < 12 * 60 * 60 {
            return true
        }
        return false
    }

    private func storedChartStore(for key: StockKey) -> PersistedStockChartStore? {
        if let stored = stores[key] { return stored }
        let url = persistentStoreURL(for: key)
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(PersistedStockChartStore.self, from: data),
           stored.market == key.market,
           stored.symbol == key.symbol {
            stores[key] = stored
            return stored
        }

        guard let migrated = migratedLegacyStore(for: key) else { return nil }
        stores[key] = migrated
        persist(migrated, for: key)
        return migrated
    }

    private func emptyChartStore(for key: StockKey) -> PersistedStockChartStore {
        PersistedStockChartStore(
            version: 1,
            market: key.market,
            symbol: key.symbol,
            series: [:],
            rangeMetadata: [:]
        )
    }

    private func migratedLegacyStore(for key: StockKey) -> PersistedStockChartStore? {
        var store = emptyChartStore(for: key)
        var migratedAnyRange = false
        for range in StockChartRange.allCases {
            let cacheKey = CacheKey(market: key.market, symbol: key.symbol, range: range)
            let url = legacyCacheURL(for: cacheKey)
            guard let data = try? Data(contentsOf: url),
                  let persisted = try? JSONDecoder().decode(PersistedCacheEntry.self, from: data),
                  persisted.market == key.market,
                  persisted.symbol == key.symbol,
                  persisted.range == range else { continue }
            merge(persisted.snapshot, range: range, into: &store)
            migratedAnyRange = true
        }
        return migratedAnyRange ? store : nil
    }

    private func merge(
        _ snapshot: StockChartSnapshot,
        range: StockChartRange,
        into store: inout PersistedStockChartStore
    ) {
        let kind = seriesKind(for: range)
        let existing = store.series[kind.rawValue] ?? []
        store.series[kind.rawValue] = mergedPoints(
            existing,
            with: snapshot.indicatorPoints ?? snapshot.points,
            kind: kind,
            market: store.market
        )
        store.rangeMetadata[range.rawValue] = StoredRangeMetadata(snapshot: snapshot)
    }

    private func persist(_ store: PersistedStockChartStore, for key: StockKey) {
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
        } catch {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "离线行情文件写入失败：\(error.localizedDescription)",
                level: .warning
            )
        }
    }

    private func persistentStoreURL(for key: StockKey) -> URL {
        let identifier = "\(key.market.rawValue)|\(key.symbol)"
        let fileName = Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return persistentStoreDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func legacyCacheURL(for key: CacheKey) -> URL {
        let identifier = "\(key.market.rawValue)|\(key.symbol)|\(key.range.rawValue)"
        let fileName = Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return legacyCacheDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func renderedSnapshot(
        from store: PersistedStockChartStore,
        range: StockChartRange
    ) -> StockChartSnapshot? {
        let compatibleMetadata = compatibleMetadataRanges(for: range)
            .compactMap { store.rangeMetadata[$0.rawValue] }
            .max { $0.fetchedAt < $1.fetchedAt }
        let metadata = compatibleMetadata ?? StockChartRange.allCases
            .filter { seriesKind(for: $0) == seriesKind(for: range) }
            .compactMap { store.rangeMetadata[$0.rawValue] }
            .max { $0.fetchedAt < $1.fetchedAt }
        guard let metadata else { return nil }

        let kind = seriesKind(for: range)
        let storedPoints = store.series[kind.rawValue] ?? []
        let points = points(storedPoints, for: range, market: store.market)
        guard !points.isEmpty else { return nil }
        return metadata.snapshot(
            points: points,
            indicatorPoints: indicatorPoints(
                from: storedPoints,
                visiblePoints: points,
                range: range
            )
        )
    }

    private func hasRequestedCoverage(
        in store: PersistedStockChartStore,
        for range: StockChartRange
    ) -> Bool {
        compatibleMetadataRanges(for: range).contains {
            guard let metadata = store.rangeMetadata[$0.rawValue] else { return false }
            if range == .intraday || range == .fiveDays {
                return metadata.indicatorPointCount != nil
            }
            return true
        }
    }

    private func seriesKind(for range: StockChartRange) -> SeriesKind {
        switch range {
        case .intraday: return .intraday
        case .fiveDays: return .fiveDayMinute
        case .oneMonth, .threeMonths, .oneYear: return .daily
        case .fiveYears, .tenYears: return .weekly
        case .sinceInception: return .monthly
        }
    }

    private func compatibleMetadataRanges(for range: StockChartRange) -> [StockChartRange] {
        switch range {
        case .intraday: return [.intraday]
        case .fiveDays: return [.fiveDays]
        case .oneMonth: return [.oneMonth, .threeMonths, .oneYear]
        case .threeMonths: return [.threeMonths, .oneYear]
        case .oneYear: return [.oneYear]
        case .fiveYears: return [.fiveYears, .tenYears]
        case .tenYears: return [.tenYears]
        case .sinceInception: return [.sinceInception]
        }
    }

    private func points(
        _ storedPoints: [StockChartPoint],
        for range: StockChartRange,
        market: StockMarket
    ) -> [StockChartPoint] {
        let sortedPoints = storedPoints.sorted { $0.date < $1.date }
        guard let latest = sortedPoints.last else { return [] }
        let calendar = marketCalendar(market)

        switch range {
        case .intraday:
            return pointsOnLatestTradingDay(sortedPoints, market: market)
        case .fiveDays:
            return pointsOnLatestTradingDays(sortedPoints, count: 5, market: market)
        case .oneMonth:
            return points(
                sortedPoints,
                since: calendar.date(byAdding: .month, value: -1, to: latest.date)
            )
        case .threeMonths:
            return points(
                sortedPoints,
                since: calendar.date(byAdding: .month, value: -3, to: latest.date)
            )
        case .oneYear:
            return points(
                sortedPoints,
                since: calendar.date(byAdding: .year, value: -1, to: latest.date)
            )
        case .fiveYears:
            return points(
                sortedPoints,
                since: calendar.date(byAdding: .year, value: -5, to: latest.date)
            )
        case .tenYears:
            return points(
                sortedPoints,
                since: calendar.date(byAdding: .year, value: -10, to: latest.date)
            )
        case .sinceInception:
            return sortedPoints
        }
    }

    private func points(
        _ points: [StockChartPoint],
        since startDate: Date?
    ) -> [StockChartPoint] {
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    private func indicatorPoints(
        from storedPoints: [StockChartPoint],
        visiblePoints: [StockChartPoint],
        range: StockChartRange
    ) -> [StockChartPoint] {
        guard range != .sinceInception,
              let firstVisibleDate = visiblePoints.first?.date,
              let lastVisibleDate = visiblePoints.last?.date else {
            return visiblePoints
        }

        let sortedPoints = storedPoints.sorted { $0.date < $1.date }
        guard let firstVisibleIndex = sortedPoints.firstIndex(where: {
            $0.date >= firstVisibleDate
        }),
        let lastVisibleIndex = sortedPoints.lastIndex(where: {
            $0.date <= lastVisibleDate
        }) else {
            return visiblePoints
        }

        let warmupStartIndex = max(0, firstVisibleIndex - 60)
        return Array(sortedPoints[warmupStartIndex...lastVisibleIndex])
    }

    private func preparedMinuteChartPoints(
        _ rawPoints: [StockChartPoint],
        range: StockChartRange,
        market: StockMarket
    ) -> (visible: [StockChartPoint], indicators: [StockChartPoint]) {
        let completeSeries: [StockChartPoint]
        if range == .intraday {
            completeSeries = resampledIntradayPoints(
                rawPoints.sorted { $0.date < $1.date },
                targetMinutes: 3
            )
        } else {
            completeSeries = rawPoints.sorted { $0.date < $1.date }
        }

        let visible: [StockChartPoint]
        if range == .intraday {
            visible = pointsOnLatestTradingDay(completeSeries, market: market)
        } else {
            visible = pointsOnLatestTradingDays(completeSeries, count: 5, market: market)
        }
        return (visible, completeSeries)
    }

    private func mergedPoints(
        _ existing: [StockChartPoint],
        with incoming: [StockChartPoint],
        kind: SeriesKind,
        market: StockMarket
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(market)
        var pointsByBucket: [Date: StockChartPoint] = [:]
        for point in existing {
            pointsByBucket[seriesBucket(for: point.date, kind: kind, calendar: calendar)] = point
        }
        for point in incoming {
            pointsByBucket[seriesBucket(for: point.date, kind: kind, calendar: calendar)] = point
        }
        return pointsByBucket.values.sorted { $0.date < $1.date }
    }

    private func seriesBucket(
        for date: Date,
        kind: SeriesKind,
        calendar: Calendar
    ) -> Date {
        switch kind {
        case .intraday, .fiveDayMinute:
            return calendar.dateInterval(of: .minute, for: date)?.start ?? date
        case .daily:
            return calendar.startOfDay(for: date)
        case .weekly:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .monthly:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    private func fetchTencentChart(
        for stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) async throws -> StockChartSnapshot {
        let identifier = tencentIdentifier(symbol, market: stock.market)
        let isMinuteChart = range == .intraday || range == .fiveDays
        let interval = range == .intraday ? "m5" : "m15"
        let historicalInterval: String
        switch range {
        case .fiveYears, .tenYears:
            historicalInterval = "week"
        case .sinceInception:
            historicalInterval = "month"
        default:
            historicalInterval = "day"
        }
        let endpoint = isMinuteChart
            ? "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/kline/mkline"
            : "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/fqkline/get"
        var components = URLComponents(string: endpoint)
        let parameter = isMinuteChart
            ? "\(identifier),\(interval),,\(range.eastmoneyLimit)"
            : "\(identifier),\(historicalInterval),,,\(range.eastmoneyLimit),qfq"
        components?.queryItems = [URLQueryItem(name: "param", value: parameter)]
        guard let url = components?.url else { throw StockChartError.invalidSymbol }

        let data = try await responseData(for: url, referer: "https://stockapp.finance.qq.com/")
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = envelope["code"] as? NSNumber,
              code.intValue == 0,
              let dataPayload = envelope["data"] as? [String: Any],
              let payload = dataPayload[identifier] as? [String: Any] else {
            throw StockChartError.noData
        }

        let rawPoints: [[Any]]?
        if isMinuteChart {
            rawPoints = payload[interval] as? [[Any]]
        } else {
            rawPoints = (payload["qfq\(historicalInterval)"] as? [[Any]])
                ?? (payload[historicalInterval] as? [[Any]])
        }
        guard let rawPoints else { throw StockChartError.noData }

        let parsedPoints = rawPoints.compactMap { parseTencentPoint($0, market: stock.market) }
        let points: [StockChartPoint]
        let fetchedIndicatorPoints: [StockChartPoint]?
        if isMinuteChart {
            let prepared = preparedMinuteChartPoints(
                parsedPoints,
                range: range,
                market: stock.market
            )
            points = prepared.visible
            fetchedIndicatorPoints = prepared.indicators
        } else {
            points = parsedPoints
            fetchedIndicatorPoints = nil
        }
        guard hasRequiredCoverage(points, for: range, market: stock.market),
              let latest = points.last else { throw StockChartError.noData }

        let quoteValues = (payload["qt"] as? [String: Any])?[identifier] as? [Any]
        let quoteName = stringValue(in: quoteValues, at: 1)
        let previousClose = doubleValue(in: quoteValues, at: 4)
            ?? stock.previousClose.map { NSDecimalNumber(decimal: $0).doubleValue }
        let resolvedName = quoteName.flatMap { $0.isEmpty ? nil : $0 } ?? stock.displayName

        return StockChartSnapshot(
            symbol: symbol,
            name: resolvedName,
            currencyCode: stock.market.currencyCode,
            previousClose: previousClose,
            points: points,
            indicatorPoints: fetchedIndicatorPoints,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "腾讯证券",
            supportsCandlesticks: true
        )
    }

    private func fetchNasdaqChart(
        for stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) async throws -> StockChartSnapshot {
        if range == .intraday {
            return try await fetchNasdaqIntradayChart(for: stock, symbol: symbol)
        }
        return try await fetchNasdaqHistoricalChart(for: stock, symbol: symbol, range: range)
    }

    private func fetchNasdaqIntradayChart(
        for stock: StockHolding,
        symbol: String
    ) async throws -> StockChartSnapshot {
        let payload = try await fetchNasdaqPayload(
            symbol: symbol,
            endpoint: "chart",
            queryItems: []
        )
        guard let rawChart = payload["chart"] as? [[String: Any]] else {
            throw StockChartError.noData
        }
        let rawPoints = rawChart.compactMap { item -> StockChartPoint? in
            guard let milliseconds = cleanedDouble(item["x"]),
                  let price = cleanedDouble(item["y"]),
                  price > 0 else { return nil }
            return StockChartPoint(
                date: Date(timeIntervalSince1970: milliseconds / 1_000),
                open: price,
                high: price,
                low: price,
                close: price,
                volume: nil
            )
        }
        let points = resampledIntradayPoints(
            pointsOnLatestTradingDay(
                regularUnitedStatesSessionPoints(rawPoints),
                market: .unitedStates
            ),
            targetMinutes: 3
        )
        guard points.count >= minimumPointCount(for: .intraday),
              let latest = points.last else { throw StockChartError.noData }

        return StockChartSnapshot(
            symbol: payload["symbol"] as? String ?? symbol,
            name: payload["company"] as? String ?? stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: cleanedDouble(payload["previousClose"])
                ?? stock.previousClose.map { NSDecimalNumber(decimal: $0).doubleValue },
            points: points,
            indicatorPoints: points,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "Nasdaq",
            supportsCandlesticks: false
        )
    }

    private func fetchNasdaqHistoricalChart(
        for stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) async throws -> StockChartSnapshot {
        let calendar = marketCalendar(.unitedStates)
        let endDate = Date()
        let startDate = historicalStartDate(
            for: range,
            endingAt: endDate,
            calendar: calendar
        )

        let payload = try await fetchNasdaqPayload(
            symbol: symbol,
            endpoint: "historical",
            queryItems: [
            URLQueryItem(name: "fromdate", value: isoDate(startDate, calendar: calendar)),
            URLQueryItem(name: "todate", value: isoDate(endDate, calendar: calendar)),
            URLQueryItem(name: "limit", value: "5000")
            ]
        )
        guard let table = payload["tradesTable"] as? [String: Any],
              let rows = table["rows"] as? [[String: Any]] else {
            throw StockChartError.noData
        }
        var points = rows.compactMap { row -> StockChartPoint? in
            guard let dateText = row["date"] as? String,
                  let date = nasdaqHistoricalDate(dateText),
                  let open = cleanedDouble(row["open"]),
                  let high = cleanedDouble(row["high"]),
                  let low = cleanedDouble(row["low"]),
                  let close = cleanedDouble(row["close"]),
                  close > 0 else { return nil }
            return StockChartPoint(
                date: date,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: cleanedDouble(row["volume"])
            )
        }
        points.sort { $0.date < $1.date }
        if range == .fiveDays, points.count > 5 {
            points = Array(points.suffix(5))
        } else if range == .fiveYears || range == .tenYears {
            points = weeklyPoints(from: points, calendar: calendar)
        }
        guard hasRequiredCoverage(points, for: range, market: stock.market),
              let latest = points.last else { throw StockChartError.noData }

        return StockChartSnapshot(
            symbol: symbol,
            name: stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: stock.previousClose.map { NSDecimalNumber(decimal: $0).doubleValue },
            points: points,
            indicatorPoints: nil,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "Nasdaq",
            supportsCandlesticks: true
        )
    }

    private func fetchYahooChart(
        for stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) async throws -> StockChartSnapshot {
        let path = "/v8/finance/chart/\(yahooIdentifier(symbol, market: stock.market))"
        var queryItems = [
            URLQueryItem(name: "interval", value: range.yahooInterval),
            URLQueryItem(name: "includePrePost", value: "false"),
            URLQueryItem(name: "events", value: "div,splits")
        ]
        if range == .sinceInception {
            // Yahoo accepts pre-Unix timestamps, so old listings are not truncated at 1970.
            queryItems.append(URLQueryItem(name: "period1", value: "-2208988800"))
            queryItems.append(URLQueryItem(
                name: "period2",
                value: String(Int(Date().timeIntervalSince1970))
            ))
        } else if range != .intraday, range != .fiveDays {
            let endDate = Date()
            let calendar = marketCalendar(stock.market)
            let startDate = historicalStartDate(
                for: range,
                endingAt: endDate,
                calendar: calendar
            )
            queryItems.append(URLQueryItem(
                name: "period1",
                value: String(Int(startDate.timeIntervalSince1970))
            ))
            queryItems.append(URLQueryItem(
                name: "period2",
                value: String(Int(endDate.timeIntervalSince1970))
            ))
        } else {
            queryItems.append(URLQueryItem(name: "range", value: range.yahooRange))
        }
        let data = try await yahooChartData(path: path, queryItems: queryItems)
        let result = try JSONDecoder().decode(YahooEnvelope.self, from: data).chart.result?.first
        guard let result,
              let timestamps = result.timestamp,
              let values = result.indicators.quote.first,
              let closes = values.close else {
            throw StockChartError.noData
        }

        let parsedPoints = timestamps.indices.compactMap { index -> StockChartPoint? in
            guard index < closes.count, let close = closes[index], close > 0 else { return nil }
            let open = value(in: values.open, at: index) ?? close
            let high = value(in: values.high, at: index) ?? max(open, close)
            let low = value(in: values.low, at: index) ?? min(open, close)
            return StockChartPoint(
                date: Date(timeIntervalSince1970: timestamps[index]),
                open: open,
                high: max(high, open, close),
                low: min(low, open, close),
                close: close,
                volume: value(in: values.volume, at: index)
            )
        }
        let points: [StockChartPoint]
        let fetchedIndicatorPoints: [StockChartPoint]?
        if range == .intraday || range == .fiveDays {
            let prepared = preparedMinuteChartPoints(
                parsedPoints,
                range: range,
                market: stock.market
            )
            points = prepared.visible
            fetchedIndicatorPoints = prepared.indicators
        } else {
            points = parsedPoints
            fetchedIndicatorPoints = nil
        }
        guard hasRequiredCoverage(points, for: range, market: stock.market),
              let latest = points.last else { throw StockChartError.noData }

        return StockChartSnapshot(
            symbol: result.meta.symbol ?? symbol,
            name: result.meta.longName ?? result.meta.shortName ?? stock.displayName,
            currencyCode: result.meta.currency ?? stock.market.currencyCode,
            previousClose: result.meta.chartPreviousClose ?? result.meta.previousClose,
            points: points,
            indicatorPoints: fetchedIndicatorPoints,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "Yahoo Finance",
            supportsCandlesticks: true
        )
    }

    private func fetchEastmoneyChart(
        for stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) async throws -> StockChartSnapshot {
        guard let identifier = eastmoneyIdentifier(symbol, market: stock.market) else {
            throw StockChartError.invalidSymbol
        }
        var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get")
        components?.queryItems = [
            URLQueryItem(name: "secid", value: identifier),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57"),
            URLQueryItem(name: "klt", value: range.eastmoneyInterval),
            URLQueryItem(name: "fqt", value: "1"),
            URLQueryItem(name: "end", value: "20500101"),
            URLQueryItem(name: "lmt", value: String(range.eastmoneyLimit))
        ]
        guard let url = components?.url else { throw StockChartError.invalidSymbol }

        let data = try await responseData(for: url, referer: "https://quote.eastmoney.com/")
        let payload = try JSONDecoder().decode(EastmoneyEnvelope.self, from: data).data
        guard let payload, let rawLines = payload.klines else { throw StockChartError.noData }

        let parsedPoints = rawLines.compactMap { parseEastmoneyPoint($0, market: stock.market) }
        let points: [StockChartPoint]
        let fetchedIndicatorPoints: [StockChartPoint]?
        if range == .intraday || range == .fiveDays {
            let prepared = preparedMinuteChartPoints(
                parsedPoints,
                range: range,
                market: stock.market
            )
            points = prepared.visible
            fetchedIndicatorPoints = prepared.indicators
        } else {
            points = parsedPoints
            fetchedIndicatorPoints = nil
        }
        guard hasRequiredCoverage(points, for: range, market: stock.market),
              let latest = points.last else { throw StockChartError.noData }

        return StockChartSnapshot(
            symbol: payload.code ?? symbol,
            name: payload.name ?? stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: stock.previousClose.map {
                NSDecimalNumber(decimal: $0).doubleValue
            } ?? payload.preKPrice?.value,
            points: points,
            indicatorPoints: fetchedIndicatorPoints,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "东方财富",
            supportsCandlesticks: true
        )
    }

    private func responseData(for url: URL, referer: String) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 8
        )
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw StockChartError.serviceUnavailable
        }
        return data
    }

    private func fetchNasdaqPayload(
        symbol: String,
        endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> [String: Any] {
        var lastError: Error = StockChartError.noData
        for assetClass in ["stocks", "etf"] {
            var components = URLComponents(
                string: "https://api.nasdaq.com/api/quote/\(symbol)/\(endpoint)"
            )
            components?.queryItems = [
                URLQueryItem(name: "assetclass", value: assetClass)
            ] + queryItems
            guard let url = components?.url else { throw StockChartError.invalidSymbol }

            do {
                let data = try await responseData(
                    for: url,
                    referer: "https://www.nasdaq.com/"
                )
                guard let envelope = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                      let payload = envelope["data"] as? [String: Any] else {
                    lastError = StockChartError.noData
                    continue
                }
                return payload
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func yahooChartData(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        var lastError: Error = StockChartError.serviceUnavailable
        for host in ["query2.finance.yahoo.com", "query1.finance.yahoo.com"] {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            components.queryItems = queryItems
            guard let url = components.url else { throw StockChartError.invalidSymbol }

            do {
                return try await responseData(for: url, referer: "https://finance.yahoo.com/")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func value(in values: [Double?]?, at index: Int) -> Double? {
        guard let values, index < values.count else { return nil }
        return values[index]
    }

    private func tencentIdentifier(_ symbol: String, market: StockMarket) -> String {
        switch market {
        case .aShare:
            let prefix: String
            if symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9") {
                prefix = "sh"
            } else if symbol.hasPrefix("4") || symbol.hasPrefix("8") {
                prefix = "bj"
            } else {
                prefix = "sz"
            }
            return prefix + symbol.lowercased()
        case .hongKong:
            return "hk" + symbol
        case .unitedStates:
            return "us" + symbol.uppercased()
        }
    }

    private func yahooIdentifier(_ symbol: String, market: StockMarket) -> String {
        switch market {
        case .aShare:
            let suffix = symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9")
                ? ".SS"
                : symbol.hasPrefix("4") || symbol.hasPrefix("8") ? ".BJ" : ".SZ"
            return symbol + suffix
        case .hongKong:
            var compactSymbol = symbol
            while compactSymbol.hasPrefix("0"), compactSymbol.count > 4 {
                compactSymbol.removeFirst()
            }
            return compactSymbol + ".HK"
        case .unitedStates:
            return symbol.replacingOccurrences(of: ".", with: "-")
        }
    }

    private func eastmoneyIdentifier(_ symbol: String, market: StockMarket) -> String? {
        switch market {
        case .aShare:
            let marketID = symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9")
                ? "1"
                : "0"
            return "\(marketID).\(symbol)"
        case .hongKong:
            return "116.\(symbol)"
        case .unitedStates:
            return nil
        }
    }

    private func parseEastmoneyPoint(_ line: String, market: StockMarket) -> StockChartPoint? {
        let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard values.count >= 6,
              let date = eastmoneyDate(values[0], market: market),
              let open = Double(values[1]),
              let close = Double(values[2]),
              let high = Double(values[3]),
              let low = Double(values[4]),
              close > 0 else { return nil }
        return StockChartPoint(
            date: date,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: Double(values[5])
        )
    }

    private func parseTencentPoint(_ values: [Any], market: StockMarket) -> StockChartPoint? {
        guard values.count >= 6,
              let dateText = values[0] as? String,
              let date = tencentDate(dateText, market: market),
              let open = double(values[1]),
              let close = double(values[2]),
              let high = double(values[3]),
              let low = double(values[4]),
              close > 0 else { return nil }
        return StockChartPoint(
            date: date,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: double(values[5])
        )
    }

    private func tencentDate(_ text: String, market: StockMarket) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = marketTimeZone(market)
        formatter.dateFormat = text.contains("-") ? "yyyy-MM-dd" : "yyyyMMddHHmm"
        return formatter.date(from: text)
    }

    private func double(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func cleanedDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = value as? String else { return nil }
        return Double(
            text
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func doubleValue(in values: [Any]?, at index: Int) -> Double? {
        guard let values, index < values.count else { return nil }
        return double(values[index])
    }

    private func stringValue(in values: [Any]?, at index: Int) -> String? {
        guard let values, index < values.count else { return nil }
        return values[index] as? String
    }

    private func eastmoneyDate(_ text: String, market: StockMarket) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = marketTimeZone(market)
        formatter.dateFormat = text.contains(":") ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private func nasdaqHistoricalDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = marketTimeZone(.unitedStates)
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.date(from: text)
    }

    private func isoDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func regularUnitedStatesSessionPoints(
        _ points: [StockChartPoint]
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(.unitedStates)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else { return false }
            let localMinutes = hour * 60 + minute
            return localMinutes >= 570 && localMinutes <= 960
        }
    }

    private func minimumPointCount(for range: StockChartRange) -> Int {
        switch range {
        case .intraday: return 1
        case .fiveDays: return 20
        case .oneMonth: return 6
        case .threeMonths: return 15
        case .oneYear: return 30
        case .fiveYears, .tenYears, .sinceInception: return 2
        }
    }

    private func hasRequiredCoverage(
        _ points: [StockChartPoint],
        for range: StockChartRange,
        market: StockMarket
    ) -> Bool {
        guard points.count >= minimumPointCount(for: range) else { return false }
        guard range == .fiveDays else { return true }

        let calendar = marketCalendar(market)
        let tradingDays = Set(points.map { calendar.startOfDay(for: $0.date) })
        return tradingDays.count == 5
    }

    private func weeklyPoints(
        from points: [StockChartPoint],
        calendar: Calendar
    ) -> [StockChartPoint] {
        let groups = Dictionary(grouping: points) { point in
            calendar.dateInterval(of: .weekOfYear, for: point.date)?.start
                ?? calendar.startOfDay(for: point.date)
        }
        return groups.keys.sorted().compactMap { weekStart in
            guard let group = groups[weekStart]?.sorted(by: { $0.date < $1.date }),
                  let first = group.first,
                  let last = group.last else { return nil }
            let volumes = group.compactMap(\.volume)
            return StockChartPoint(
                date: last.date,
                open: first.open,
                high: group.map(\.high).max() ?? last.high,
                low: group.map(\.low).min() ?? last.low,
                close: last.close,
                volume: volumes.isEmpty ? nil : volumes.reduce(0, +)
            )
        }
    }

    private func resampledIntradayPoints(
        _ points: [StockChartPoint],
        targetMinutes: Int
    ) -> [StockChartPoint] {
        guard targetMinutes > 1 else { return points.sorted { $0.date < $1.date } }
        let interval = TimeInterval(targetMinutes * 60)
        let groups = Dictionary(grouping: points) { point in
            Int(point.date.timeIntervalSince1970 / interval)
        }
        return groups.keys.sorted().compactMap { bucket in
            guard let group = groups[bucket]?.sorted(by: { $0.date < $1.date }),
                  let first = group.first,
                  let last = group.last else { return nil }
            let volumes = group.compactMap(\.volume)
            return StockChartPoint(
                date: last.date,
                open: first.open,
                high: group.map(\.high).max() ?? last.high,
                low: group.map(\.low).min() ?? last.low,
                close: last.close,
                volume: volumes.isEmpty ? nil : volumes.reduce(0, +)
            )
        }
    }

    private func pointsOnLatestTradingDay(
        _ points: [StockChartPoint],
        market: StockMarket
    ) -> [StockChartPoint] {
        guard let latest = points.last else { return [] }
        let calendar = marketCalendar(market)
        return points.filter { calendar.isDate($0.date, inSameDayAs: latest.date) }
    }

    private func pointsOnLatestTradingDays(
        _ points: [StockChartPoint],
        count: Int,
        market: StockMarket
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(market)
        let days = points.reversed().reduce(into: [Date]()) { result, point in
            let day = calendar.startOfDay(for: point.date)
            if !result.contains(day), result.count < count { result.append(day) }
        }
        let retainedDays = Set(days)
        return points.filter { retainedDays.contains(calendar.startOfDay(for: $0.date)) }
    }

    private func historicalStartDate(
        for range: StockChartRange,
        endingAt endDate: Date,
        calendar: Calendar
    ) -> Date {
        switch range {
        case .intraday:
            return endDate
        case .fiveDays:
            return calendar.date(byAdding: .day, value: -12, to: endDate) ?? endDate
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -4, to: endDate) ?? endDate
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -6, to: endDate) ?? endDate
        case .oneYear:
            return calendar.date(byAdding: .month, value: -15, to: endDate) ?? endDate
        case .fiveYears:
            return calendar.date(byAdding: .month, value: -78, to: endDate) ?? endDate
        case .tenYears:
            return calendar.date(byAdding: .month, value: -138, to: endDate) ?? endDate
        case .sinceInception:
            return Date(timeIntervalSince1970: 0)
        }
    }

    private func marketCalendar(_ market: StockMarket) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(market)
        return calendar
    }

    private func marketTimeZone(_ market: StockMarket) -> TimeZone {
        let identifier: String
        switch market {
        case .aShare: identifier = "Asia/Shanghai"
        case .hongKong: identifier = "Asia/Hong_Kong"
        case .unitedStates: identifier = "America/New_York"
        }
        return TimeZone(identifier: identifier) ?? .gmt
    }
}
