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
    private var cacheGeneration = 0

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
        let generation = cacheGeneration
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
            if !StockMarketTradingCalendar.isSessionActive(stock.market, at: now) {
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
            let scopedSnapshot = snapshotByUpdatingCurrentSession(
                StockMarketTradingCalendar.session(for: stock.market, at: now),
                remote: snapshot,
                cached: cached,
                market: stock.market,
                at: now
            )
            let updatedStore = diskStore.merging(
                scopedSnapshot,
                range: range,
                for: stockKey,
                into: stored
            )
            if generation == cacheGeneration {
                diskStore.save(updatedStore, for: stockKey)
            }
            return diskStore.renderedSnapshot(from: updatedStore, range: range) ?? scopedSnapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    func clearCache() {
        cacheGeneration += 1
        lastRefreshSessionEnd.removeAll()
        diskStore.removeAll()
    }

    private func fetchRemoteChart(
        for request: StockChartRequest
    ) async throws -> StockChartSnapshot {
        do {
            let tencentSnapshot = try await providers.tencent.fetchChart(for: request)
            if request.stock.market == .unitedStates,
               request.range == .intraday,
               (tencentSnapshot.preMarketPoints.isEmpty
                    || tencentSnapshot.postMarketPoints.isEmpty),
               let yahooSnapshot = try? await providers.yahoo.fetchChart(for: request) {
                return yahooSnapshot
            }
            return tencentSnapshot
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
        switch StockMarketTradingCalendar.session(for: key.market, at: now) {
        case .preMarket:
            guard let latest = snapshot.preMarketPoints.last else { return false }
            return now.timeIntervalSince(latest.date) < key.range.cacheLifetime
        case .regular:
            let calendar = StockChartSeriesProcessor.marketCalendar(key.market)
            let hasTodayRegularPoint = snapshot.points.contains {
                calendar.isDate($0.date, inSameDayAs: now)
            }
            return hasTodayRegularPoint
                && now.timeIntervalSince(snapshot.fetchedAt) < key.range.cacheLifetime
        case .postMarket:
            guard let latest = snapshot.postMarketPoints.last else { return false }
            return now.timeIntervalSince(latest.date) < key.range.cacheLifetime
        case .closed:
            break
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

    private func snapshotByUpdatingCurrentSession(
        _ session: StockMarketSession,
        remote: StockChartSnapshot,
        cached: StockChartSnapshot?,
        market: StockMarket,
        at now: Date
    ) -> StockChartSnapshot {
        let calendar = StockChartSeriesProcessor.marketCalendar(market)
        let currentDayPoints: ([StockChartPoint]) -> [StockChartPoint] = { points in
            points.filter { calendar.isDate($0.date, inSameDayAs: now) }
        }
        let hasCached = cached != nil
        let regularPoints: [StockChartPoint]
        let preMarketPoints: [StockChartPoint]
        let postMarketPoints: [StockChartPoint]
        let indicatorPoints: [StockChartPoint]?

        switch session {
        case .preMarket:
            regularPoints = cached?.points ?? remote.points
            indicatorPoints = cached?.indicatorPoints ?? remote.indicatorPoints
            preMarketPoints = currentDayPoints(remote.preMarketPoints)
            postMarketPoints = hasCached
                ? currentDayPoints(cached?.postMarketPoints ?? [])
                : []
        case .regular:
            regularPoints = remote.points
            indicatorPoints = remote.indicatorPoints
            preMarketPoints = hasCached
                ? currentDayPoints(cached?.preMarketPoints ?? [])
                : currentDayPoints(remote.preMarketPoints)
            postMarketPoints = hasCached
                ? currentDayPoints(cached?.postMarketPoints ?? [])
                : []
        case .postMarket:
            regularPoints = cached?.points ?? remote.points
            indicatorPoints = cached?.indicatorPoints ?? remote.indicatorPoints
            preMarketPoints = currentDayPoints(
                cached?.preMarketPoints ?? remote.preMarketPoints
            )
            postMarketPoints = currentDayPoints(remote.postMarketPoints)
        case .closed:
            regularPoints = remote.points
            indicatorPoints = remote.indicatorPoints
            preMarketPoints = remote.preMarketPoints
            postMarketPoints = remote.postMarketPoints
        }

        let updatedAt: Date
        switch session {
        case .preMarket:
            updatedAt = preMarketPoints.last?.date ?? remote.quoteUpdatedAt
        case .postMarket:
            updatedAt = postMarketPoints.last?.date ?? remote.quoteUpdatedAt
        case .regular, .closed:
            updatedAt = remote.quoteUpdatedAt
        }
        return StockChartSnapshot(
            symbol: remote.symbol,
            name: remote.name,
            currencyCode: remote.currencyCode,
            previousClose: remote.previousClose,
            points: regularPoints,
            preMarketPoints: preMarketPoints,
            postMarketPoints: postMarketPoints,
            indicatorPoints: indicatorPoints,
            quoteUpdatedAt: updatedAt,
            fetchedAt: remote.fetchedAt,
            source: remote.source,
            supportsCandlesticks: remote.supportsCandlesticks
        )
    }
}

#endif
