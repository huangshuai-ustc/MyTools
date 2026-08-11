#if MYTOOLS_FEATURE_STOCKS
import Foundation

protocol StockFundamentalServing: Sendable {
    func fundamentals(
        for stock: StockHolding,
        forceRefresh: Bool
    ) async -> StockFundamentalSnapshot?
}

actor StockFundamentalService: StockFundamentalServing {
    static let shared = StockFundamentalService()

    private struct CacheKey: Hashable {
        let market: StockMarket
        let symbol: String
    }

    private struct CacheEntry {
        let snapshot: StockFundamentalSnapshot
        let fetchedAt: Date
    }

    private let providers: StockFundamentalProviders
    private let now: @Sendable () -> Date
    private let cacheLifetime: TimeInterval
    private var cache: [CacheKey: CacheEntry] = [:]

    init(
        providers: StockFundamentalProviders = StockFundamentalProviders(),
        now: @escaping @Sendable () -> Date = { Date() },
        cacheLifetime: TimeInterval = 24 * 60 * 60
    ) {
        self.providers = providers
        self.now = now
        self.cacheLifetime = cacheLifetime
    }

    func fundamentals(
        for stock: StockHolding,
        forceRefresh: Bool = false
    ) async -> StockFundamentalSnapshot? {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { return nil }
        let key = CacheKey(market: stock.market, symbol: symbol)
        let currentDate = now()
        if !forceRefresh,
           let cached = cache[key],
           currentDate.timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.snapshot
        }

        let snapshot: StockFundamentalSnapshot?
        switch stock.market {
        case .aShare, .hongKong:
            async let eastmoney = providers.eastmoney.fetchFundamentals(for: stock)
            async let yahoo = providers.yahoo.fetchFundamentals(for: stock)
            snapshot = merged(primary: await eastmoney, supplement: await yahoo)
        case .unitedStates:
            snapshot = await providers.yahoo.fetchFundamentals(for: stock)
        }
        if let snapshot {
            cache[key] = CacheEntry(snapshot: snapshot, fetchedAt: currentDate)
            return snapshot
        }
        return cache[key]?.snapshot
    }

    private func merged(
        primary: StockFundamentalSnapshot?,
        supplement: StockFundamentalSnapshot?
    ) -> StockFundamentalSnapshot? {
        guard primary != nil || supplement != nil else { return nil }
        let sources = [primary?.source, supplement?.source]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let source = Array(Set(sources)).sorted().joined(separator: " / ")
        return StockFundamentalSnapshot(
            asOfDate: max(
                primary?.asOfDate ?? .distantPast,
                supplement?.asOfDate ?? .distantPast
            ),
            source: source,
            priceEarningsRatioTTM: primary?.priceEarningsRatioTTM
                ?? supplement?.priceEarningsRatioTTM,
            priceBookRatioMRQ: primary?.priceBookRatioMRQ
                ?? supplement?.priceBookRatioMRQ,
            dividendYield: primary?.dividendYield ?? supplement?.dividendYield,
            returnOnEquity: primary?.returnOnEquity ?? supplement?.returnOnEquity,
            netProfitMargin: primary?.netProfitMargin ?? supplement?.netProfitMargin,
            revenueGrowth: primary?.revenueGrowth ?? supplement?.revenueGrowth,
            earningsGrowth: primary?.earningsGrowth ?? supplement?.earningsGrowth
        )
    }
}

#endif
