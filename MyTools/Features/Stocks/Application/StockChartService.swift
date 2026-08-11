#if MYTOOLS_FEATURE_STOCKS
import Foundation

protocol StockChartServing: Sendable {
    func cachedChart(
        for stock: StockHolding,
        range: StockChartRange
    ) async -> StockChartSnapshot?

    func fetchChart(
        for stock: StockHolding,
        range: StockChartRange,
        forceRefresh: Bool
    ) async throws -> StockChartSnapshot
}

actor StockChartService: StockChartServing {
    static let shared = StockChartService()

    private var diskStore: StockChartDiskStore
    private let providers: StockChartProviders
    private var lastRefreshSessionEnd: [StockChartCacheKey: Date] = [:]

    init(
        diskStore: StockChartDiskStore = StockChartDiskStore(),
        providers: StockChartProviders = StockChartProviders()
    ) {
        self.diskStore = diskStore
        self.providers = providers
    }

    func cachedChart(
        for stock: StockHolding,
        range: StockChartRange
    ) async -> StockChartSnapshot? {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { return nil }
        let key = StockChartStoreKey(market: stock.market, symbol: symbol)
        guard let store = diskStore.load(for: key) else { return nil }
        return diskStore.renderedSnapshot(from: store, range: range)
    }

    func fetchChart(
        for stock: StockHolding,
        range: StockChartRange,
        forceRefresh: Bool = false
    ) async throws -> StockChartSnapshot {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { throw StockChartError.invalidSymbol }

        let stockKey = StockChartStoreKey(market: stock.market, symbol: symbol)
        let cacheKey = StockChartCacheKey(
            market: stock.market,
            symbol: symbol,
            range: range
        )
        let now = Date()
        let stored = diskStore.load(for: stockKey)
        let cached = stored.flatMap {
            diskStore.renderedSnapshot(from: $0, range: range)
        }
        if let cached,
           let stored,
           diskStore.hasRequestedCoverage(in: stored, for: range),
           shouldUseCachedChart(
                cached,
                for: cacheKey,
                forceRefresh: forceRefresh,
                now: now
           ) {
            return cached
        }

        do {
            if !StockMarketTradingCalendar.isOpen(stock.market, at: now) {
                lastRefreshSessionEnd[cacheKey] = StockMarketTradingCalendar
                    .latestCompletedFinalSessionEnd(for: stock.market, at: now)
            }
            let request = StockChartRequest(stock: stock, symbol: symbol, range: range)
            let remoteSnapshot = try await fetchRemoteChart(for: request)
            guard let snapshot = StockChartSeriesProcessor.normalizedSnapshot(
                remoteSnapshot,
                range: range,
                market: stock.market,
                at: now
            ) else {
                throw StockChartError.noData
            }
            let updatedStore = diskStore.merging(
                snapshot,
                range: range,
                for: stockKey,
                into: stored
            )
            diskStore.save(updatedStore, for: stockKey)
            return diskStore.renderedSnapshot(from: updatedStore, range: range) ?? snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    private func fetchRemoteChart(
        for request: StockChartRequest
    ) async throws -> StockChartSnapshot {
        do {
            return try await providers.tencent.fetchChart(for: request)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }

            if request.stock.market != .unitedStates,
               let fallback = try? await providers.eastmoney.fetchChart(for: request) {
                return fallback
            }

            if request.stock.market == .unitedStates,
               request.range == .intraday,
               let fallback = try? await providers.yahoo.fetchChart(for: request) {
                return fallback
            }

            if request.stock.market == .unitedStates,
               request.range != .fiveDays,
               request.range != .sinceInception,
               let fallback = try? await providers.nasdaq.fetchChart(for: request) {
                return fallback
            }

            if !(request.stock.market == .unitedStates && request.range == .intraday),
               let fallback = try? await providers.yahoo.fetchChart(for: request) {
                return fallback
            }

            guard !Task.isCancelled else { throw CancellationError() }
            throw StockChartError.serviceUnavailable
        }
    }

    private func shouldUseCachedChart(
        _ snapshot: StockChartSnapshot,
        for key: StockChartCacheKey,
        forceRefresh: Bool,
        now: Date
    ) -> Bool {
        guard !forceRefresh else { return false }
        if StockMarketTradingCalendar.isOpen(key.market, at: now) {
            return now.timeIntervalSince(snapshot.fetchedAt) < key.range.cacheLifetime
        }
        let sessionEnded = StockMarketTradingCalendar.sessionEnded(
            for: key.market,
            between: snapshot.fetchedAt,
            and: now
        )
        guard sessionEnded else { return true }
        guard let sessionEnd = StockMarketTradingCalendar
            .latestCompletedFinalSessionEnd(for: key.market, at: now) else {
            return true
        }
        return lastRefreshSessionEnd[key] == sessionEnd
    }
}

#endif
