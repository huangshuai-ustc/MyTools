import Foundation
import Testing
@testable import MyTools

struct StockQuoteServiceTests {
    @Test func newerValidBatchQuoteWins() async {
        let stock = StockHolding(market: .unitedStates, symbol: "VOO")
        let tencent = quote(source: "Tencent", updatedAt: Date(timeIntervalSince1970: 800))
        let sina = quote(source: "Sina", updatedAt: Date(timeIntervalSince1970: 900))
        let service = makeService(
            tencentBatch: [stock.id: tencent],
            sinaBatch: [stock.id: sina],
            now: Date(timeIntervalSince1970: 1_000)
        )

        let result = await service.fetchQuotes(for: [stock])

        #expect(result[stock.id]?.source == "Sina")
    }

    @Test func validTimestampWinsOverNewerFutureTimestamp() async {
        let stock = StockHolding(market: .unitedStates, symbol: "VOO")
        let future = quote(source: "Tencent", updatedAt: Date(timeIntervalSince1970: 1_400))
        let valid = quote(source: "Sina", updatedAt: Date(timeIntervalSince1970: 900))
        let service = makeService(
            tencentBatch: [stock.id: future],
            sinaBatch: [stock.id: valid],
            now: Date(timeIntervalSince1970: 1_000)
        )

        let result = await service.fetchQuotes(for: [stock])

        #expect(result[stock.id]?.source == "Sina")
    }

    @Test func aShareFallbackOrderIsStable() async {
        let calls = ProviderCallLog()
        let stock = StockHolding(market: .aShare, symbol: "600519")
        let service = fallbackService(
            successfulProvider: "eastmoney",
            calls: calls
        )

        let result = await service.fetchQuotes(for: [stock])
        let fallbackCalls = await calls.values().filter { !$0.hasSuffix("-batch") }

        #expect(result[stock.id]?.source == "eastmoney")
        #expect(fallbackCalls == ["tencent", "sina", "official", "eastmoney"])
    }

    @Test func hongKongFallbackOrderIsStable() async {
        let calls = ProviderCallLog()
        let stock = StockHolding(market: .hongKong, symbol: "00700")
        let service = fallbackService(
            successfulProvider: "yahoo",
            calls: calls
        )

        let result = await service.fetchQuotes(for: [stock])
        let fallbackCalls = await calls.values().filter { !$0.hasSuffix("-batch") }

        #expect(result[stock.id]?.source == "yahoo")
        #expect(fallbackCalls == ["tencent", "sina", "eastmoney", "yahoo"])
    }

    @Test func unitedStatesFallbackOrderIsStable() async {
        let calls = ProviderCallLog()
        let stock = StockHolding(market: .unitedStates, symbol: "VOO")
        let service = fallbackService(
            successfulProvider: "yahoo",
            calls: calls
        )

        let result = await service.fetchQuotes(for: [stock])
        let fallbackCalls = await calls.values().filter { !$0.hasSuffix("-batch") }

        #expect(result[stock.id]?.source == "yahoo")
        #expect(fallbackCalls == ["tencent", "sina", "nasdaq", "yahoo"])
    }

    @Test func invalidSymbolsAreRejectedWithoutCallingProviders() async {
        let calls = ProviderCallLog()
        let service = fallbackService(successfulProvider: nil, calls: calls)
        let stock = StockHolding(market: .aShare, symbol: "   ")

        let result = await service.fetchQuotes(for: [stock])
        let recordedCalls = await calls.values()

        #expect(result.isEmpty)
        #expect(recordedCalls.isEmpty)
    }

    @Test func allProvidersFailWithoutCreatingPlaceholderQuote() async {
        let calls = ProviderCallLog()
        let service = fallbackService(successfulProvider: nil, calls: calls)
        let stock = StockHolding(market: .unitedStates, symbol: "UNKNOWN")

        let result = await service.fetchQuotes(for: [stock])

        #expect(result.isEmpty)
    }

    // MARK: - 港股延迟行情：分时末点择优

    /// 港股报价源整体延迟约 15 分钟，分时接口实时。分时末点更新时必须胜出，
    /// 而且价格与涨跌幅一起替换——只换价格就会显示自相矛盾的涨跌。
    @Test func hongKongIntradayLastPointOverridesDelayedQuote() async {
        let stock = StockHolding(market: .hongKong, symbol: "03033")
        let delayed = quote(source: "Tencent", updatedAt: Date(timeIntervalSince1970: 100))
        let service = makeService(
            tencentBatch: [stock.id: delayed],
            sinaBatch: [:],
            now: Date(timeIntervalSince1970: 1_000),
            intradaySnapshot: snapshot(
                closes: [104, 106, 108],
                lastDate: Date(timeIntervalSince1970: 900)
            )
        )

        let result = await service.fetchQuotes(for: [stock])

        #expect(result[stock.id]?.latestPrice == 108)
        #expect(result[stock.id]?.previousClose == 100)
        // (108 − 100) / 100，与 latestPrice/previousClose 自洽，而不是报价源的 0.05。
        #expect(result[stock.id]?.changePercent == Decimal(string: "0.08"))
        #expect(result[stock.id]?.updatedAt == Date(timeIntervalSince1970: 900))
        #expect(result[stock.id]?.source == "Tencent+intraday")
    }

    /// 收盘后报价源会追上收盘价，此时分时缓存更旧，应保留报价。
    @Test func hongKongStaleIntradayKeepsProviderQuote() async {
        let stock = StockHolding(market: .hongKong, symbol: "03033")
        let fresh = quote(source: "Tencent", updatedAt: Date(timeIntervalSince1970: 900))
        let service = makeService(
            tencentBatch: [stock.id: fresh],
            sinaBatch: [:],
            now: Date(timeIntervalSince1970: 1_000),
            intradaySnapshot: snapshot(
                closes: [108],
                lastDate: Date(timeIntervalSince1970: 200)
            )
        )

        let result = await service.fetchQuotes(for: [stock])

        #expect(result[stock.id]?.latestPrice == 105)
        #expect(result[stock.id]?.source == "Tencent")
    }

    @Test func hongKongWithoutIntradayCacheKeepsProviderQuote() async {
        let stock = StockHolding(market: .hongKong, symbol: "03033")
        let delayed = quote(source: "Tencent", updatedAt: Date(timeIntervalSince1970: 100))
        let service = makeService(
            tencentBatch: [stock.id: delayed],
            sinaBatch: [:],
            now: Date(timeIntervalSince1970: 1_000),
            intradaySnapshot: nil
        )

        let result = await service.fetchQuotes(for: [stock])

        #expect(result[stock.id]?.latestPrice == 105)
        #expect(result[stock.id]?.source == "Tencent")
    }

    /// 时间戳跑到未来容忍窗口（5 分钟）之外的分时不可信，沿用报价。
    @Test func hongKongFutureIntradayPointIsRejected() async {
        let stock = StockHolding(market: .hongKong, symbol: "03033")
        let delayed = quote(source: "Tencent", updatedAt: Date(timeIntervalSince1970: 100))
        let service = makeService(
            tencentBatch: [stock.id: delayed],
            sinaBatch: [:],
            now: Date(timeIntervalSince1970: 1_000),
            intradaySnapshot: snapshot(
                closes: [108],
                lastDate: Date(timeIntervalSince1970: 1_400)
            )
        )

        let result = await service.fetchQuotes(for: [stock])

        #expect(result[stock.id]?.latestPrice == 105)
        #expect(result[stock.id]?.source == "Tencent")
    }

    /// A 股与美股报价源本身实时，不引入分时这条依赖——美股还另有
    /// `StockExtendedHoursPerformance` 负责盘前盘后。
    @Test func nonHongKongMarketsIgnoreIntradayOverride() async {
        let aShare = StockHolding(market: .aShare, symbol: "600519")
        let usStock = StockHolding(market: .unitedStates, symbol: "VOO")
        let delayed = quote(source: "Tencent", updatedAt: Date(timeIntervalSince1970: 100))
        let service = makeService(
            tencentBatch: [aShare.id: delayed, usStock.id: delayed],
            sinaBatch: [:],
            now: Date(timeIntervalSince1970: 1_000),
            intradaySnapshot: snapshot(
                closes: [108],
                lastDate: Date(timeIntervalSince1970: 900)
            )
        )

        let result = await service.fetchQuotes(for: [aShare, usStock])

        #expect(result[aShare.id]?.latestPrice == 105)
        #expect(result[aShare.id]?.source == "Tencent")
        #expect(result[usStock.id]?.latestPrice == 105)
        #expect(result[usStock.id]?.source == "Tencent")
    }

    private func makeService(
        tencentBatch: [UUID: StockQuote],
        sinaBatch: [UUID: StockQuote],
        now: Date,
        intradaySnapshot: StockChartSnapshot? = nil
    ) -> StockQuoteService {
        let calls = ProviderCallLog()
        let providers = StockQuoteProviders(
            tencent: RecordingBatchQuoteProvider(
                name: "tencent",
                batchQuotes: tencentBatch,
                singleQuote: nil,
                calls: calls
            ),
            sina: RecordingBatchQuoteProvider(
                name: "sina",
                batchQuotes: sinaBatch,
                singleQuote: nil,
                calls: calls
            ),
            officialAShare: RecordingQuoteProvider(name: "official", quote: nil, calls: calls),
            eastmoney: RecordingQuoteProvider(name: "eastmoney", quote: nil, calls: calls),
            nasdaq: RecordingQuoteProvider(name: "nasdaq", quote: nil, calls: calls),
            yahoo: RecordingQuoteProvider(name: "yahoo", quote: nil, calls: calls)
        )
        let intradayChart: (@Sendable (StockHolding) async -> StockChartSnapshot?)?
        if let intradaySnapshot {
            intradayChart = { _ in intradaySnapshot }
        } else {
            intradayChart = nil
        }
        return StockQuoteService(
            providers: providers,
            now: { now },
            intradayChart: intradayChart
        )
    }

    private func fallbackService(
        successfulProvider: String?,
        calls: ProviderCallLog
    ) -> StockQuoteService {
        func result(for provider: String) -> StockQuote? {
            successfulProvider == provider
                ? quote(source: provider, updatedAt: Date(timeIntervalSince1970: 1_000))
                : nil
        }
        return StockQuoteService(providers: StockQuoteProviders(
            tencent: RecordingBatchQuoteProvider(
                name: "tencent",
                batchQuotes: [:],
                singleQuote: result(for: "tencent"),
                calls: calls
            ),
            sina: RecordingBatchQuoteProvider(
                name: "sina",
                batchQuotes: [:],
                singleQuote: result(for: "sina"),
                calls: calls
            ),
            officialAShare: RecordingQuoteProvider(
                name: "official",
                quote: result(for: "official"),
                calls: calls
            ),
            eastmoney: RecordingQuoteProvider(
                name: "eastmoney",
                quote: result(for: "eastmoney"),
                calls: calls
            ),
            nasdaq: RecordingQuoteProvider(
                name: "nasdaq",
                quote: result(for: "nasdaq"),
                calls: calls
            ),
            yahoo: RecordingQuoteProvider(
                name: "yahoo",
                quote: result(for: "yahoo"),
                calls: calls
            )
        ))
    }

    private func quote(source: String, updatedAt: Date) -> StockQuote {
        StockQuote(
            symbol: "TEST",
            name: "Test",
            latestPrice: 105,
            previousClose: 100,
            changePercent: Decimal(string: "0.05"),
            updatedAt: updatedAt,
            source: source
        )
    }

    /// 造一段分时：`closes` 最后一个值落在 `lastDate`，前面的点每分钟往前推。
    private func snapshot(closes: [Double], lastDate: Date) -> StockChartSnapshot {
        let points = closes.enumerated().map { index, close in
            StockChartFixtures.point(
                at: lastDate.addingTimeInterval(TimeInterval((index - closes.count + 1) * 60)),
                close: close
            )
        }
        return StockChartSnapshot(
            symbol: "TEST",
            name: "Test",
            currencyCode: "HKD",
            previousClose: nil,
            points: points,
            preMarketPoints: [],
            postMarketPoints: [],
            indicatorPoints: nil,
            quoteUpdatedAt: lastDate,
            fetchedAt: lastDate,
            source: "Fixture",
            supportsCandlesticks: true
        )
    }
}

private actor ProviderCallLog {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func values() -> [String] {
        recordedValues
    }
}

private struct RecordingBatchQuoteProvider: StockQuoteBatchProviding {
    let name: String
    let batchQuotes: [UUID: StockQuote]
    let singleQuote: StockQuote?
    let calls: ProviderCallLog

    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote] {
        await calls.append("\(name)-batch")
        return batchQuotes
    }

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
        await calls.append(name)
        return singleQuote
    }
}

private struct RecordingQuoteProvider: StockQuoteProviding {
    let name: String
    let quote: StockQuote?
    let calls: ProviderCallLog

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
        await calls.append(name)
        return quote
    }
}
