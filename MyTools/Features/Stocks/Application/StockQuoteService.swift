#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockQuoteService: Sendable {
    private let providers: StockQuoteProviders
    private let now: @Sendable () -> Date
    /// 港股报价源延迟约 15 分钟，分时接口实时。只读缓存、不发请求，
    /// 拿到的最坏情况是上一轮分时，仍远优于 15 分钟延迟。
    private let intradayChart: (@Sendable (StockHolding) async -> StockChartSnapshot?)?

    init(
        providers: StockQuoteProviders = StockQuoteProviders(),
        now: @escaping @Sendable () -> Date = { Date() },
        intradayChart: (@Sendable (StockHolding) async -> StockChartSnapshot?)? = nil
    ) {
        self.providers = providers
        self.now = now
        self.intradayChart = intradayChart
    }

    func fetchQuote(for stock: StockHolding) async throws -> StockQuote {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty else { throw StockQuoteError.invalidSymbol }
        guard let quote = await fetchQuotes(for: [stock])[stock.id] else {
            throw StockQuoteError.quoteUnavailable
        }
        return quote
    }

    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote] {
        let validStocks = stocks.filter {
            !StockQuoteProviderSupport.symbol(for: $0).isEmpty
        }
        guard !validStocks.isEmpty else { return [:] }

        async let tencentTask = providers.tencent.fetchQuotes(for: validStocks)
        async let sinaTask = providers.sina.fetchQuotes(for: validStocks)
        let (tencentQuotes, sinaQuotes) = await (tencentTask, sinaTask)

        var quotes: [UUID: StockQuote] = [:]
        for stock in validStocks {
            quotes[stock.id] = preferredQuote(
                primary: tencentQuotes[stock.id],
                validator: sinaQuotes[stock.id]
            )
        }

        let missingStocks = validStocks.filter { quotes[$0.id] == nil }
        guard !missingStocks.isEmpty else {
            return await quotesPreferringIntraday(quotes, for: validStocks)
        }

        await withTaskGroup(of: (UUID, StockQuote?).self) { group in
            for stock in missingStocks {
                group.addTask {
                    (stock.id, await fetchFallbackQuote(for: stock))
                }
            }
            for await (stockID, quote) in group {
                quotes[stockID] = quote
            }
        }
        return await quotesPreferringIntraday(quotes, for: validStocks)
    }

    /// 港股延迟行情修正：用实时分时末点替换最新价，并**同时**重算涨跌幅。
    ///
    /// 实测（2026-09-21 11:30 前后）港股报价源整体延迟：`qt.gtimg.cn` 时间戳
    /// 停在 11:15、`hq.sinajs.cn` 停在 11:11，而同族分时接口给出 11:31 的当前
    /// 分钟柱；同一时刻 A 股两个报价源都是实时的。两个延迟源之间无论怎么择优
    /// 都选不出实时价，所以把分时当作港股报价的又一个数据源参与同一套
    /// 「时间戳较新者胜出」的比较。
    ///
    /// 价格、涨跌额、涨跌幅必须一起替换：只换价格不重算涨跌幅，就会显示
    /// 「4.328 却 +0.006」这种自相矛盾的组合（顶部价格来自报价链路、涨跌来自
    /// 图表链路正是原先的表现）。`previousClose` 沿用报价源的结算值——分时不
    /// 提供昨收，而昨收是已结算的值，不需要实时源。
    ///
    /// 不需要额外的「当天校验」：时间戳比较已经隐含处理了。收盘后报价源追上
    /// 收盘价（时间戳更新），隔夜的分时缓存自然落选。
    private func quotesPreferringIntraday(
        _ quotes: [UUID: StockQuote],
        for stocks: [StockHolding]
    ) async -> [UUID: StockQuote] {
        guard let intradayChart else { return quotes }
        var result = quotes
        let currentDate = now()
        for stock in stocks where stock.market == .hongKong {
            guard let quote = result[stock.id],
                  let snapshot = await intradayChart(stock),
                  let lastPoint = snapshot.points.max(by: { $0.date < $1.date })
            else { continue }
            // 分钟柱按结束时刻标注，末点可以略超前当前时刻，沿用报价择优的同一份容忍度。
            guard lastPoint.date > quote.updatedAt,
                  lastPoint.date <= currentDate.addingTimeInterval(Self.futureTolerance)
            else { continue }
            let chartPrice = Self.decimalQuoteValue(lastPoint.close)
            guard chartPrice > 0 else { continue }
            result[stock.id] = StockQuote(
                symbol: quote.symbol,
                name: quote.name,
                shortName: quote.shortName,
                latestPrice: chartPrice,
                previousClose: quote.previousClose,
                changePercent: StockQuoteProviderSupport.percentageChange(
                    latestPrice: chartPrice,
                    previousClose: quote.previousClose
                ),
                updatedAt: lastPoint.date,
                source: "\(quote.source)+intraday"
            )
        }
        return result
    }

    /// 分时收盘价是 `Double`，先经字符串再转 `Decimal`，避免二进制浮点尾数
    /// 污染后续的金额运算（与 `StockStore.decimalQuoteValue` 同一手法）。
    private static func decimalQuoteValue(_ value: Double) -> Decimal {
        Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
            ?? Decimal(value)
    }

    private static let futureTolerance: TimeInterval = 5 * 60

    private func preferredQuote(
        primary: StockQuote?,
        validator: StockQuote?
    ) -> StockQuote? {
        guard let primary else { return validator }
        guard let validator else { return primary }

        let currentDate = now()
        let primaryHasValidTime = primary.updatedAt <= currentDate.addingTimeInterval(Self.futureTolerance)
        let validatorHasValidTime = validator.updatedAt <= currentDate.addingTimeInterval(Self.futureTolerance)
        if primaryHasValidTime != validatorHasValidTime {
            return primaryHasValidTime ? primary : validator
        }

        let timeDifference = primary.updatedAt.timeIntervalSince(validator.updatedAt)
        if abs(timeDifference) > 2 {
            return timeDifference > 0 ? primary : validator
        }
        return primary
    }

    private func fetchFallbackQuote(for stock: StockHolding) async -> StockQuote? {
        switch stock.market {
        case .aShare:
            if let quote = await providers.tencent.fetchQuote(for: stock) { return quote }
            if let quote = await providers.sina.fetchQuote(for: stock) { return quote }
            if let quote = await providers.officialAShare.fetchQuote(for: stock) { return quote }
            return await providers.eastmoney.fetchQuote(for: stock)
        case .hongKong:
            if let quote = await providers.tencent.fetchQuote(for: stock) { return quote }
            if let quote = await providers.sina.fetchQuote(for: stock) { return quote }
            if let quote = await providers.eastmoney.fetchQuote(for: stock) { return quote }
            return await providers.yahoo.fetchQuote(for: stock)
        case .unitedStates:
            if let quote = await providers.tencent.fetchQuote(for: stock) { return quote }
            if let quote = await providers.sina.fetchQuote(for: stock) { return quote }
            if let quote = await providers.nasdaq.fetchQuote(for: stock) { return quote }
            return await providers.yahoo.fetchQuote(for: stock)
        }
    }
}

#endif
