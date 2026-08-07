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

    private func makeService(
        tencentBatch: [UUID: StockQuote],
        sinaBatch: [UUID: StockQuote],
        now: Date
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
        return StockQuoteService(providers: providers, now: { now })
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
