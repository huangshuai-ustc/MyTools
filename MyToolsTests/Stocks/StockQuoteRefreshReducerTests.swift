import Foundation
import Testing
@testable import MyTools

struct StockQuoteRefreshReducerTests {
    @Test func closedMarketRefreshesOnlyMissingOrForcedQuotes() {
        let weekend = Date(timeIntervalSince1970: 1_786_276_800)
        let missing = Self.stock(symbol: "600000", market: .aShare)
        var complete = Self.stock(symbol: "AAPL", market: .unitedStates)
        complete.latestPrice = 100
        complete.lastQuoteAt = weekend.addingTimeInterval(-3_600)
        let blank = Self.stock(symbol: "", market: .aShare)

        let missingOnly = StockQuoteRefreshReducer.stocksToRefresh(
            from: [missing, complete, blank],
            market: nil,
            forcedMarkets: [],
            allowClosedMissingData: true,
            at: weekend
        )
        #expect(missingOnly.map(\.id) == [missing.id])

        let forced = StockQuoteRefreshReducer.stocksToRefresh(
            from: [missing, complete, blank],
            market: .unitedStates,
            forcedMarkets: [.unitedStates],
            allowClosedMissingData: false,
            at: weekend
        )
        #expect(forced.map(\.id) == [complete.id])
    }

    @Test func quoteReductionUpdatesSuccessAndReportsMissingResponse() throws {
        let updatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        var success = Self.stock(symbol: "OLD", market: .unitedStates)
        success.quoteName = "Old name"
        var failure = Self.stock(symbol: "600000", market: .aShare)
        failure.latestPrice = 10
        let quote = StockQuote(
            symbol: "NEW",
            name: "  New name  ",
            latestPrice: 101,
            previousClose: 99,
            changePercent: 2,
            updatedAt: updatedAt,
            source: "Test"
        )

        let result = StockQuoteRefreshReducer.reduce(
            currentStocks: [success, failure],
            requestedStocks: [success, failure],
            quotes: [success.id: quote]
        )
        let updated = try #require(result.stocks.first)

        #expect(updated.symbol == "NEW")
        #expect(updated.quoteName == "New name")
        #expect(updated.latestPrice == 101)
        #expect(updated.previousClose == 99)
        #expect(updated.changePercent == 2)
        #expect(updated.lastQuoteAt == updatedAt)
        #expect(result.failures == [failure.id: "行情服务暂时不可用"])
        #expect(result.sources == [success.id: "Test"])
        #expect(result.refreshedMarkets == [.unitedStates])
        #expect(result.successCount == 1)
        #expect(result.didChangePersistedQuote)
    }

    @Test func blankQuoteNamePreservesCachedNameAndUnchangedQuoteNeedsNoSave() throws {
        let updatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        var stock = Self.stock(symbol: "AAPL", market: .unitedStates)
        stock.quoteName = "Apple"
        stock.latestPrice = 100
        stock.previousClose = 99
        stock.changePercent = 1
        stock.lastQuoteAt = updatedAt
        let quote = StockQuote(
            symbol: "AAPL",
            name: "   ",
            latestPrice: 100,
            previousClose: 99,
            changePercent: 1,
            updatedAt: updatedAt,
            source: "Test"
        )

        let result = StockQuoteRefreshReducer.reduce(
            currentStocks: [stock],
            requestedStocks: [stock],
            quotes: [stock.id: quote]
        )

        #expect(try #require(result.stocks.first).quoteName == "Apple")
        #expect(!result.didChangePersistedQuote)
        #expect(result.successCount == 1)
    }

    @Test func quoteForStockDeletedDuringRequestIsIgnored() {
        let requested = Self.stock(symbol: "AAPL", market: .unitedStates)
        let quote = StockQuote(
            symbol: "AAPL",
            name: "Apple",
            latestPrice: 100,
            previousClose: 99,
            changePercent: 1,
            updatedAt: Date(),
            source: "Test"
        )

        let result = StockQuoteRefreshReducer.reduce(
            currentStocks: [],
            requestedStocks: [requested],
            quotes: [requested.id: quote]
        )

        #expect(result.stocks.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(result.sources.isEmpty)
        #expect(result.successCount == 0)
        #expect(!result.didChangePersistedQuote)
    }

    private static func stock(symbol: String, market: StockMarket) -> StockHolding {
        var stock = StockHolding()
        stock.symbol = symbol
        stock.market = market
        return stock
    }
}
