#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockQuoteService: Sendable {
    private let providers: StockQuoteProviders
    private let now: @Sendable () -> Date

    init(
        providers: StockQuoteProviders = StockQuoteProviders(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.now = now
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
        guard !missingStocks.isEmpty else { return quotes }

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
        return quotes
    }

    private func preferredQuote(
        primary: StockQuote?,
        validator: StockQuote?
    ) -> StockQuote? {
        guard let primary else { return validator }
        guard let validator else { return primary }

        let futureTolerance: TimeInterval = 5 * 60
        let currentDate = now()
        let primaryHasValidTime = primary.updatedAt <= currentDate.addingTimeInterval(futureTolerance)
        let validatorHasValidTime = validator.updatedAt <= currentDate.addingTimeInterval(futureTolerance)
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
