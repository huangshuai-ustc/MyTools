#if MYTOOLS_FEATURE_STOCKS
import CryptoKit
import Foundation

// MARK: - Persisted cache schema

private struct PortfolioValueCacheFile: Codable {
    // Version 2 adds portfolio OHLC values used by the candlestick view.
    static let currentVersion = 2

    let version: Int
    let computedAt: Date
    let fingerprint: String
    let series: [PortfolioValueSeries]
}

// MARK: - Service

actor PortfolioValueHistoryService {

    private var diskStore: StockChartDiskStore
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private var memoryCache: [String: PortfolioValueCacheFile] = [:]
    private var minuteMemoryCache: [String: PortfolioValueSeries] = [:]

    init(diskStore: StockChartDiskStore = StockChartDiskStore()) {
        self.diskStore = diskStore
        self.fileManager = .default
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fm.temporaryDirectory
        self.cacheDirectory = support
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("PortfolioHistory", isDirectory: true)
    }

    // MARK: - Public API

    /// Build series for the given market filter.
    /// - `liveOverrides`: latest prices keyed by symbol, used to patch today's value
    ///   when any relevant market is currently in session.
    func buildSeries(
        for market: StockMarket?,
        stocks: [StockHolding],
        rates: [CurrencyCode: Decimal],
        liveOverrides: [String: Decimal] = [:],
        selectedStockIDs: Set<UUID>? = nil
    ) async -> [PortfolioValueSeries] {
        let holdingStocks = stocks.filter { $0.hasPurchaseRecord && (selectedStockIDs == nil || selectedStockIDs!.contains($0.id)) }

        if let market {
            let marketStocks = holdingStocks.filter { $0.market == market }
            guard !marketStocks.isEmpty else { return [] }
            return buildMarketSeries(
                market: market,
                stocks: marketStocks,
                liveOverrides: liveOverrides
            )
        } else {
            var marketSeries: [PortfolioValueSeries] = []
            for m in StockMarket.topLevelOrder {
                let marketStocks = holdingStocks.filter { $0.market == m }
                guard !marketStocks.isEmpty else { continue }
                let series = buildMarketSeries(
                    market: m,
                    stocks: marketStocks,
                    liveOverrides: liveOverrides
                )
                marketSeries.append(contentsOf: series)
            }
            if let cny = PortfolioValueHistoryBuilder.buildCNYSeries(
                from: marketSeries,
                rates: rates
            ) {
                return marketSeries + [cny]
            }
            return marketSeries
        }
    }

    func buildMinuteSeries(
        for market: StockMarket?,
        range: StockChartRange,
        stocks: [StockHolding],
        rates: [CurrencyCode: Decimal],
        selectedStockIDs: Set<UUID>? = nil
    ) async -> [PortfolioValueSeries] {
        let holdingStocks = stocks.filter { $0.hasPurchaseRecord && (selectedStockIDs == nil || selectedStockIDs!.contains($0.id)) }

        if let market {
            let marketStocks = holdingStocks.filter { $0.market == market }
            guard !marketStocks.isEmpty else { return [] }
            let series = buildMinuteMarketSeries(for: market, range: range, stocks: marketStocks)
            return series.points.isEmpty ? [] : [series]
        } else {
            var marketSeries: [PortfolioValueSeries] = []
            for m in StockMarket.topLevelOrder {
                let marketStocks = holdingStocks.filter { $0.market == m }
                guard !marketStocks.isEmpty else { continue }
                let series = buildMinuteMarketSeries(for: m, range: range, stocks: marketStocks)
                if !series.points.isEmpty {
                    marketSeries.append(series)
                }
            }
            if let cny = PortfolioValueHistoryBuilder.buildMinuteCNYSeries(
                from: marketSeries,
                rates: rates
            ) {
                return marketSeries + [cny]
            }
            return marketSeries
        }
    }

    func invalidateCache(for market: StockMarket) {
        let key = market.rawValue
        memoryCache.removeValue(forKey: key)
        minuteMemoryCache = minuteMemoryCache.filter { !$0.key.hasPrefix("\(key)|") }
        let url = cacheFileURL(for: key)
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Internal

    private func buildMinuteMarketSeries(
        for market: StockMarket,
        range: StockChartRange,
        stocks: [StockHolding]
    ) -> PortfolioValueSeries {
        let minutePrices = loadMinutePrices(for: stocks)
        let sourceSignature = stocks.sorted { $0.id.uuidString < $1.id.uuidString }.map { stock in
            let points = minutePrices[stock.symbol] ?? []
            let transactionData = (try? JSONEncoder.portfolioHistory.encode(stock.transactions)) ?? Data()
            let transactionDigest = SHA256.hash(data: transactionData)
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            return "\(stock.id.uuidString):\(points.count):\(points.last?.date.timeIntervalSinceReferenceDate ?? 0):\(points.last?.close ?? 0):\(transactionDigest)"
        }.joined(separator: ";")
        let digest = SHA256.hash(data: Data(sourceSignature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let cacheKey = "\(market.rawValue)|\(range.rawValue)|\(digest)"
        if let cached = minuteMemoryCache[cacheKey] { return cached }

        let series = PortfolioValueHistoryBuilder.buildMinuteSeries(
            for: market,
            range: range,
            stocks: stocks,
            minutePointsBySymbol: minutePrices
        )
        minuteMemoryCache = minuteMemoryCache.filter {
            !$0.key.hasPrefix("\(market.rawValue)|\(range.rawValue)|")
        }
        minuteMemoryCache[cacheKey] = series
        return series
    }

    private func buildMarketSeries(
        market: StockMarket,
        stocks: [StockHolding],
        liveOverrides: [String: Decimal]
    ) -> [PortfolioValueSeries] {
        let key = market.rawValue
        let fp = fingerprint(for: stocks, market: market)
        let marketOverrides = liveOverrides.filter { sym, _ in
            stocks.contains { $0.symbol == sym }
        }

        // If market is in session, skip cache so live prices show through
        let isLive = StockMarketTradingCalendar.isSessionActive(market)

        if !isLive {
            if let cached = memoryCache[key],
               cached.version == PortfolioValueCacheFile.currentVersion,
               cached.fingerprint == fp {
                return cached.series
            }
            if let cached = loadFromDisk(key: key),
               cached.version == PortfolioValueCacheFile.currentVersion,
               cached.fingerprint == fp {
                memoryCache[key] = cached
                return cached.series
            }
        }

        let prices = loadDailyPrices(for: stocks)
        let series = PortfolioValueHistoryBuilder.buildSeries(
            for: market,
            stocks: stocks,
            dailyPointsBySymbol: prices,
            todayPriceOverrides: marketOverrides
        )
        let seriesList = series.points.isEmpty ? [] : [series]

        if !isLive {
            let file = PortfolioValueCacheFile(
                version: PortfolioValueCacheFile.currentVersion,
                computedAt: Date(),
                fingerprint: fp,
                series: seriesList
            )
            memoryCache[key] = file
            saveToDisk(file, key: key)
        }

        return seriesList
    }

    private func fingerprint(for stocks: [StockHolding], market: StockMarket) -> String {
        var parts: [String] = []
        for stock in stocks.sorted(by: { $0.symbol < $1.symbol }) {
            let transactionData = (try? JSONEncoder.portfolioHistory.encode(stock.transactions)) ?? Data()
            let transactionDigest = SHA256.hash(data: transactionData)
                .map { String(format: "%02x", $0) }
                .joined()
            let storeKey = StockChartStoreKey(market: market, symbol: stock.symbol)
            let latestDate = diskStore.load(for: storeKey)?
                .series[StockChartSeriesKind.daily.rawValue]?
                .map(\.date)
                .max()
                .map { String($0.timeIntervalSinceReferenceDate) }
                ?? "none"
            parts.append("\(stock.symbol)|\(latestDate)|\(transactionDigest)")
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: ";").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadMinutePrices(for stocks: [StockHolding]) -> [String: [StockChartPoint]] {
        var result: [String: [StockChartPoint]] = [:]
        for stock in stocks {
            let key = StockChartStoreKey(market: stock.market, symbol: stock.symbol)
            if let minute = diskStore.load(for: key)?.series[StockChartSeriesKind.intraday.rawValue],
               !minute.isEmpty {
                result[stock.symbol] = minute
            }
        }
        return result
    }

    private func loadDailyPrices(for stocks: [StockHolding]) -> [String: [StockChartPoint]] {
        var result: [String: [StockChartPoint]] = [:]
        for stock in stocks {
            let key = StockChartStoreKey(market: stock.market, symbol: stock.symbol)
            if let daily = diskStore.load(for: key)?.series[StockChartSeriesKind.daily.rawValue],
               !daily.isEmpty {
                result[stock.symbol] = daily
            }
        }
        return result
    }

    // MARK: - Disk I/O

    private func cacheFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).json")
    }

    private func loadFromDisk(key: String) -> PortfolioValueCacheFile? {
        let url = cacheFileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PortfolioValueCacheFile.self, from: data)
    }

    private func saveToDisk(_ file: PortfolioValueCacheFile, key: String) {
        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            var dir = cacheDirectory
            var res = URLResourceValues()
            res.isExcludedFromBackup = true
            try? dir.setResourceValues(res)
            let data = try JSONEncoder().encode(file)
            try data.write(to: cacheFileURL(for: key), options: .atomic)
        } catch {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "持仓总价值历史缓存写入失败：\(error.localizedDescription)",
                level: .warning
            )
        }
    }
}

private extension JSONEncoder {
    static let portfolioHistory: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

#endif
