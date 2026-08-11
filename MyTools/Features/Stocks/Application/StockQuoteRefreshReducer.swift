#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockQuoteRefreshReduction {
    var stocks: [StockHolding]
    var failures: [UUID: String]
    var sources: [UUID: String]
    var refreshedMarkets: Set<StockMarket>
    var successCount: Int
    var didChangePersistedQuote: Bool
}

enum StockQuoteRefreshReducer {
    static func stocksToRefresh(
        from stocks: [StockHolding],
        market: StockMarket?,
        forcedMarkets: Set<StockMarket>,
        allowClosedMissingData: Bool,
        at date: Date
    ) -> [StockHolding] {
        stocks.filter { stock in
            guard stock.hasConfiguredSymbol else { return false }
            if let market, stock.market != market { return false }
            let quoteDataMissing = stock.latestPrice == nil
                || stock.latestPrice.map { $0 <= 0 } == true
                || stock.lastQuoteAt == nil
            return forcedMarkets.contains(stock.market)
                || (allowClosedMissingData && quoteDataMissing)
                || StockMarketTradingCalendar.isOpen(stock.market, at: date)
        }
    }

    static func reduce(
        currentStocks: [StockHolding],
        requestedStocks: [StockHolding],
        quotes: [UUID: StockQuote]
    ) -> StockQuoteRefreshReduction {
        var stocks = currentStocks
        var stockIndices: [UUID: Int] = [:]
        for index in stocks.indices {
            stockIndices[stocks[index].id] = index
        }
        var failures: [UUID: String] = [:]
        var sources: [UUID: String] = [:]
        var refreshedMarkets = Set<StockMarket>()
        var successCount = 0
        var didChangePersistedQuote = false

        for requestedStock in requestedStocks {
            guard let quote = quotes[requestedStock.id] else {
                failures[requestedStock.id] = "行情服务暂时不可用"
                continue
            }
            guard let index = stockIndices[requestedStock.id] else { continue }

            let previous = stocks[index]
            stocks[index].symbol = quote.symbol
            let quoteName = quote.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoteName.isEmpty {
                stocks[index].quoteName = quoteName
            }
            stocks[index].latestPrice = quote.latestPrice
            stocks[index].previousClose = quote.previousClose
            stocks[index].changePercent = quote.changePercent
            stocks[index].lastQuoteAt = quote.updatedAt
            if previous.symbol != quote.symbol
                || (!quoteName.isEmpty && previous.quoteName != quoteName)
                || previous.latestPrice != quote.latestPrice
                || previous.previousClose != quote.previousClose
                || previous.changePercent != quote.changePercent
                || previous.lastQuoteAt != quote.updatedAt {
                didChangePersistedQuote = true
            }
            sources[requestedStock.id] = quote.source
            refreshedMarkets.insert(requestedStock.market)
            successCount += 1
        }

        return StockQuoteRefreshReduction(
            stocks: stocks,
            failures: failures,
            sources: sources,
            refreshedMarkets: refreshedMarkets,
            successCount: successCount,
            didChangePersistedQuote: didChangePersistedQuote
        )
    }
}

#endif
