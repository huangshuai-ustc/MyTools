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

    private let chartService: any StockChartServing
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private var memoryCache: [String: PortfolioValueCacheFile] = [:]
    private var minuteMemoryCache: [String: PortfolioValueSeries] = [:]

    init(chartService: any StockChartServing = StockChartService.shared) {
        self.chartService = chartService
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
            return await buildMarketSeries(
                market: market,
                stocks: marketStocks,
                liveOverrides: liveOverrides
            )
        } else {
            var marketSeries: [PortfolioValueSeries] = []
            for m in StockMarket.topLevelOrder {
                let marketStocks = holdingStocks.filter { $0.market == m }
                guard !marketStocks.isEmpty else { continue }
                let series = await buildMarketSeries(
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
            let series = await buildMinuteMarketSeries(for: market, range: range, stocks: marketStocks)
            return series.points.isEmpty ? [] : [series]
        } else {
            var marketSeries: [PortfolioValueSeries] = []
            for m in StockMarket.topLevelOrder {
                let marketStocks = holdingStocks.filter { $0.market == m }
                guard !marketStocks.isEmpty else { continue }
                let series = await buildMinuteMarketSeries(for: m, range: range, stocks: marketStocks)
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
    ) async -> PortfolioValueSeries {
        let minutePrices = await loadPrices(for: stocks, range: .fiveDays)
        let sourceSignature = stocks.sorted { $0.id.uuidString < $1.id.uuidString }.map { stock in
            let points = minutePrices[stock.symbol] ?? []
            let transactionData = (try? JSONEncoder.portfolioHistory.encode(stock.transactions)) ?? Data()
            let transactionDigest = SHA256.hash(data: transactionData)
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            // A provider may correct an earlier OHLC bar without changing the
            // point count or final close. Those corrections affect portfolio
            // candles too, so fingerprint the complete source.
            let sourceData = (try? JSONEncoder.portfolioHistory.encode(points)) ?? Data()
            let sourceDigest = SHA256.hash(data: sourceData)
                .map { String(format: "%02x", $0) }.joined()
            return "\(stock.id.uuidString):\(sourceDigest):\(transactionDigest)"
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
    ) async -> [PortfolioValueSeries] {
        let key = market.rawValue
        let prices = await loadPrices(for: stocks, range: .dayK)
        let fp = fingerprint(for: stocks, prices: prices)
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

    private func fingerprint(for stocks: [StockHolding], prices: [String: [StockChartPoint]]) -> String {
        var parts: [String] = ["moving-average-cost-v2"]
        for stock in stocks.sorted(by: { $0.symbol < $1.symbol }) {
            let transactionData = (try? JSONEncoder.portfolioHistory.encode(stock.transactions)) ?? Data()
            let transactionDigest = SHA256.hash(data: transactionData)
                .map { String(format: "%02x", $0) }
                .joined()
            let sourceData = (try? JSONEncoder.portfolioHistory.encode(prices[stock.symbol] ?? [])) ?? Data()
            let sourceDigest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
            parts.append("\(stock.id)|\(stock.symbol)|\(sourceDigest)|\(transactionDigest)")
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: ";").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadPrices(for stocks: [StockHolding], range: StockChartRange) async -> [String: [StockChartPoint]] {
        var result: [String: [StockChartPoint]] = [:]
        await withTaskGroup(of: (String, [StockChartPoint]).self) { group in
            for stock in stocks {
                group.addTask { [chartService] in
                    guard let snapshot = await chartService.cachedChart(for: stock, range: range) else {
                        return (stock.symbol, [])
                    }
                    return (stock.symbol, range.isMinuteRange
                        ? (snapshot.indicatorPoints ?? snapshot.points)
                        : (snapshot.dailyIndicatorPoints ?? snapshot.indicatorPoints ?? snapshot.points))
                }
            }
            for await (symbol, points) in group {
                if !points.isEmpty { result[symbol] = points }
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
