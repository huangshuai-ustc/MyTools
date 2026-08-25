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

    /// Refreshes every source series needed after a market's final regular
    /// session. Derived K-lines and technical indicators are rebuilt from the
    /// refreshed minute/daily inputs rather than treating K-lines specially.
    func refreshAfterFinalSession(for stock: StockHolding) async throws
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
           (range == .intraday || !needsDailyTechnicalSupport(
               in: stored,
               now: now,
               refreshingRange: range
           )),
           !needsMinuteTechnicalWarmup(
                in: stored,
                range: range,
                market: stock.market
           ),
           shouldUseCachedChart(
                cached,
                for: cacheKey,
                forceRefresh: forceRefresh,
                now: now
           ) {
            return cached
        }

        do {
            let request = StockChartRequest(
                stock: stock,
                symbol: symbol,
                range: range
            )
            let remoteSnapshot = try await fetchRemoteChart(for: request)
            guard let snapshot = StockChartSeriesProcessor.normalizedSnapshot(
                remoteSnapshot,
                range: range,
                market: stock.market,
                at: now
            ) else {
                throw StockChartError.noData
            }
            if range == .intraday,
               StockMarketTradingCalendar.session(for: stock.market, at: now) != .regular,
               let latestRegularPoint = snapshot.points.max(by: { $0.date < $1.date }),
               StockChartSeriesProcessor.marketCalendar(stock.market)
                   .isDate(latestRegularPoint.date, inSameDayAs: now),
               !StockChartSeriesProcessor.hasCompletedRegularSession(
                   snapshot.points,
                   market: stock.market
               ) {
                // A same-day partial regular response is not a successful
                // closing snapshot. Keep the previous cache and let the
                // coordinator retry after its cooldown.
                throw StockChartError.noData
            }
            var scopedSnapshot = snapshotByUpdatingCurrentSession(
                StockMarketTradingCalendar.session(for: stock.market, at: now),
                remote: snapshot,
                cached: cached,
                market: stock.market,
                at: now
            )
            if range == .intraday,
               needsMinuteTechnicalWarmup(
                    in: scopedSnapshot,
                    range: range,
                    market: stock.market
               ),
               let warmupSnapshot = try? await fetchRemoteChart(
                    for: StockChartRequest(
                        stock: stock,
                        symbol: symbol,
                        range: .fiveDays
                    )
               ) {
                scopedSnapshot = snapshotByAddingMinuteIndicatorHistory(
                    warmupSnapshot,
                    to: scopedSnapshot,
                    market: stock.market
                )
            }
            var updatedStore = diskStore.merging(
                scopedSnapshot,
                range: range,
                for: stockKey,
                into: stored
            )
            if range != .intraday,
               needsDailyTechnicalSupport(
                   in: updatedStore,
                   now: now,
                   refreshingRange: range
               ),
               let dailyRange = dailyTechnicalRange(for: range),
               let dailySnapshot = try? await fetchRemoteChart(
                   for: StockChartRequest(
                       stock: stock,
                       symbol: symbol,
                       range: dailyRange
                   )
               ),
               !dailySnapshot.points.isEmpty {
                updatedStore = diskStore.merging(
                    dailySnapshot,
                    // The supplemental request contains raw daily bars.
                    // Merge it through the canonical daily source rather
                    // than an old display-only range.
                    range: .dayK,
                    for: stockKey,
                    into: updatedStore
                )
            }
            if generation == cacheGeneration {
                diskStore.save(updatedStore, for: stockKey)
                if range.isKLineRange
                    || !StockMarketTradingCalendar.isSessionActive(stock.market, at: now) {
                    let sessionEnd = StockMarketTradingCalendar
                        .latestCompletedFinalSessionEnd(for: stock.market, at: now)
                    lastRefreshSessionEnd[canonicalRefreshKey(for: cacheKey)] = sessionEnd
                }
            }
            return diskStore.renderedSnapshot(from: updatedStore, range: range) ?? scopedSnapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !forceRefresh, let cached { return cached }
            throw error
        }
    }

    func refreshAfterFinalSession(for stock: StockHolding) async throws {
        var firstError: Error?
        // These are the canonical source series. The presentation layer
        // recalculates every MA/BOLL/MACD/RSI from them, while the disk store
        // derives weekly/monthly/quarterly/yearly K-lines from the daily set.
        for range in [StockChartRange.intraday, .fiveDays, .dayK] {
            do {
                _ = try await fetchChart(
                    for: stock,
                    range: range,
                    forceRefresh: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
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
        // Tencent's US historical endpoint can return a shorter ETF history
        // even when a large point limit is requested. K-line and inception
        // requests must use providers with explicit complete-history support
        // so older listings such as VOO are not truncated.
        if request.stock.market == .unitedStates,
           request.range.isKLineRange {
            if let yahooSnapshot = try? await providers.yahoo.fetchChart(for: request) {
                return yahooSnapshot
            }
            if let nasdaqSnapshot = try? await providers.nasdaq.fetchChart(for: request) {
                return nasdaqSnapshot
            }
        }
        do {
            let tencentSnapshot = try await providers.tencent.fetchChart(for: request)
            let needsCompletedRegularSession = request.range == .intraday
                && StockMarketTradingCalendar.session(for: request.stock.market) != .regular
                && !StockChartSeriesProcessor.hasCompletedRegularSession(
                    tencentSnapshot.points,
                    market: request.stock.market
                )
            if request.stock.market == .unitedStates,
               request.range == .intraday,
               (needsCompletedRegularSession
                    || tencentSnapshot.preMarketPoints.isEmpty
                    || tencentSnapshot.postMarketPoints.isEmpty),
               let yahooSnapshot = try? await providers.yahoo.fetchChart(for: request) {
                return preferredUSIntradaySnapshot(
                    primary: tencentSnapshot,
                    fallback: yahooSnapshot
                )
            }
            if request.stock.market != .unitedStates,
               needsCompletedRegularSession,
               let eastmoneySnapshot = try? await providers.eastmoney.fetchChart(for: request) {
                return eastmoneySnapshot
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

    /// Tencent and Yahoo can expose different extended-hours coverage for the
    /// same US symbol. Keep the denser series for each session independently;
    /// otherwise a sparse Yahoo pre-market response can replace a complete
    /// Tencent one just because Yahoo supplied another field.
    private func preferredUSIntradaySnapshot(
        primary: StockChartSnapshot,
        fallback: StockChartSnapshot
    ) -> StockChartSnapshot {
        StockChartSnapshot(
            symbol: primary.symbol,
            name: primary.name,
            currencyCode: primary.currencyCode,
            previousClose: primary.previousClose ?? fallback.previousClose,
            points: denserMinuteSeries(primary.points, fallback.points),
            preMarketPoints: denserMinuteSeries(
                primary.preMarketPoints,
                fallback.preMarketPoints
            ),
            postMarketPoints: denserMinuteSeries(
                primary.postMarketPoints,
                fallback.postMarketPoints
            ),
            indicatorPoints: preferredIndicatorPoints(
                primary.indicatorPoints,
                fallback.indicatorPoints
            ),
            dailyIndicatorPoints: primary.dailyIndicatorPoints
                ?? fallback.dailyIndicatorPoints,
            quoteUpdatedAt: max(primary.quoteUpdatedAt, fallback.quoteUpdatedAt),
            fetchedAt: max(primary.fetchedAt, fallback.fetchedAt),
            source: [primary.source, fallback.source]
                .filter { !$0.isEmpty }
                .joined(separator: " / "),
            supportsCandlesticks: primary.supportsCandlesticks
                || fallback.supportsCandlesticks
        )
    }

    private func preferredIndicatorPoints(
        _ primary: [StockChartPoint]?,
        _ fallback: [StockChartPoint]?
    ) -> [StockChartPoint]? {
        guard let primary else { return fallback }
        guard let fallback else { return primary }
        return denserMinuteSeries(primary, fallback)
    }

    private func denserMinuteSeries(
        _ primary: [StockChartPoint],
        _ fallback: [StockChartPoint]
    ) -> [StockChartPoint] {
        guard !primary.isEmpty else { return fallback }
        guard !fallback.isEmpty else { return primary }
        let primaryScore = minuteDensityScore(primary)
        let fallbackScore = minuteDensityScore(fallback)
        let fallbackHasComparableCoverage = primaryScore.count < 3
            || fallbackScore.count >= max(3, primaryScore.count / 2)
        if fallbackHasComparableCoverage,
           fallbackScore.cadence < primaryScore.cadence {
            return fallback
        }
        if fallbackHasComparableCoverage,
           fallbackScore.cadence == primaryScore.cadence,
           fallbackScore.count > primaryScore.count {
            return fallback
        }
        return primary
    }

    private func minuteDensityScore(
        _ points: [StockChartPoint]
    ) -> (cadence: TimeInterval, count: Int) {
        let sortedDates = points.map(\.date).sorted()
        guard sortedDates.count > 1 else {
            return (.infinity, sortedDates.count)
        }
        let gaps = zip(sortedDates, sortedDates.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 > 0 }
            .sorted()
        guard !gaps.isEmpty else { return (.infinity, sortedDates.count) }
        return (gaps[gaps.count / 2], sortedDates.count)
    }

    private func shouldUseCachedChart(
        _ snapshot: StockChartSnapshot,
        for key: StockChartCacheKey,
        forceRefresh: Bool,
        now: Date
    ) -> Bool {
        guard !forceRefresh else { return false }
        let session = StockMarketTradingCalendar.session(for: key.market, at: now)
        if key.range.isKLineRange {
            // K-lines follow the regular-session cadence while the market is
            // open. Extended-hours sessions belong only to the intraday chart;
            // keep the last regular K-line cache until the final close pass.
            switch session {
            case .preMarket, .postMarket:
                return true
            case .regular:
                return false
            case .closed:
                break
            }
        }
        switch session {
        case .preMarket:
            guard let latest = snapshot.preMarketPoints.last else { return false }
            guard now.timeIntervalSince(latest.date) < key.range.cacheLifetime else {
                return false
            }
            return regularChartCacheIsUsable(snapshot, key: key, now: now)
        case .regular:
            let calendar = StockChartSeriesProcessor.marketCalendar(key.market)
            let hasTodayRegularPoint = snapshot.points.contains {
                calendar.isDate($0.date, inSameDayAs: now)
            }
            return hasTodayRegularPoint
                && now.timeIntervalSince(snapshot.fetchedAt) < key.range.cacheLifetime
        case .postMarket:
            guard let latest = snapshot.postMarketPoints.last else { return false }
            guard now.timeIntervalSince(latest.date) < key.range.cacheLifetime else {
                return false
            }
            return regularChartCacheIsUsable(snapshot, key: key, now: now)
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
        return lastRefreshSessionEnd[canonicalRefreshKey(for: key)] == sessionEnd
            && regularChartCacheIsUsable(snapshot, key: key, now: now)
    }

    private func canonicalRefreshKey(
        for key: StockChartCacheKey
    ) -> StockChartCacheKey {
        guard key.range.isKLineRange else { return key }
        return StockChartCacheKey(
            market: key.market,
            symbol: key.symbol,
            range: .dayK
        )
    }

    private func regularChartCacheIsUsable(
        _ snapshot: StockChartSnapshot,
        key: StockChartCacheKey,
        now: Date
    ) -> Bool {
        guard key.range == .intraday else { return true }
        if StockChartSeriesProcessor.hasCompletedRegularSession(
            snapshot.points,
            market: key.market
        ) {
            return true
        }
        // Keep an incomplete response briefly so an unavailable fallback does
        // not turn foreground polling into a tight retry loop.
        return now.timeIntervalSince(snapshot.fetchedAt) < 5 * 60
    }

    /// Minute charts display only the latest session(s), but their technical
    /// indicators need enough prior minute bars to warm up. Keep this check
    /// at the service/cache boundary so a short first intraday response gets
    /// one historical five-day supplement instead of producing empty lines.
    private func needsMinuteTechnicalWarmup(
        in store: StockChartPersistedStore,
        range: StockChartRange,
        market: StockMarket
    ) -> Bool {
        guard range.isMinuteRange else { return false }
        let kind = StockChartSeriesProcessor.seriesKind(for: range)
        return needsMinuteTechnicalWarmup(
            points: store.series[kind.rawValue] ?? [],
            market: market
        )
    }

    private func needsMinuteTechnicalWarmup(
        points: [StockChartPoint],
        market: StockMarket
    ) -> Bool {
        return StockChartSeriesProcessor.needsMinuteTechnicalWarmup(
            points,
            market: market
        )
    }

    private func needsMinuteTechnicalWarmup(
        in snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket
    ) -> Bool {
        guard range.isMinuteRange else { return false }
        return needsMinuteTechnicalWarmup(
            points: snapshot.indicatorPoints ?? snapshot.points,
            market: market
        )
    }

    private func snapshotByAddingMinuteIndicatorHistory(
        _ warmup: StockChartSnapshot,
        to snapshot: StockChartSnapshot,
        market: StockMarket
    ) -> StockChartSnapshot {
        let existing = snapshot.indicatorPoints ?? snapshot.points
        let supplemental = warmup.indicatorPoints ?? warmup.points
        let merged = StockChartSeriesProcessor.mergedPoints(
            existing,
            with: supplemental,
            kind: .intraday,
            market: market
        )
        return StockChartSnapshot(
            symbol: snapshot.symbol,
            name: snapshot.name,
            currencyCode: snapshot.currencyCode,
            previousClose: snapshot.previousClose,
            points: snapshot.points,
            preMarketPoints: snapshot.preMarketPoints,
            postMarketPoints: snapshot.postMarketPoints,
            indicatorPoints: merged.isEmpty ? snapshot.indicatorPoints : merged,
            dailyIndicatorPoints: snapshot.dailyIndicatorPoints,
            quoteUpdatedAt: snapshot.quoteUpdatedAt,
            fetchedAt: snapshot.fetchedAt,
            source: snapshot.source,
            supportsCandlesticks: snapshot.supportsCandlesticks
        )
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
        let regularPoints: [StockChartPoint] = session == .regular
            ? remote.points
            : preferredRegularPoints(
                remote: remote.points,
                cached: cached?.points,
                market: market
            )
        let preMarketPoints: [StockChartPoint]
        let postMarketPoints: [StockChartPoint]
        let indicatorPoints: [StockChartPoint]? = session == .regular
            ? remote.indicatorPoints
            : mergedIndicatorPoints(
                remote: remote.indicatorPoints,
                cached: cached?.indicatorPoints,
                market: market
            )

        switch session {
        case .preMarket:
            preMarketPoints = currentDayPoints(remote.preMarketPoints)
            postMarketPoints = hasCached
                ? currentDayPoints(cached?.postMarketPoints ?? [])
                : []
        case .regular:
            preMarketPoints = hasCached
                ? currentDayPoints(cached?.preMarketPoints ?? [])
                : currentDayPoints(remote.preMarketPoints)
            postMarketPoints = hasCached
                ? currentDayPoints(cached?.postMarketPoints ?? [])
                : []
        case .postMarket:
            preMarketPoints = currentDayPoints(
                cached?.preMarketPoints ?? remote.preMarketPoints
            )
            postMarketPoints = currentDayPoints(remote.postMarketPoints)
        case .closed:
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
            dailyIndicatorPoints: remote.dailyIndicatorPoints,
            quoteUpdatedAt: updatedAt,
            fetchedAt: remote.fetchedAt,
            source: remote.source,
            supportsCandlesticks: remote.supportsCandlesticks
        )
    }

    private func preferredRegularPoints(
        remote: [StockChartPoint],
        cached: [StockChartPoint]?,
        market: StockMarket
    ) -> [StockChartPoint] {
        guard let cached, !cached.isEmpty else { return remote }
        return StockChartSeriesProcessor.mergedPoints(
            cached,
            with: remote,
            kind: .intraday,
            market: market
        )
    }

    private func mergedIndicatorPoints(
        remote: [StockChartPoint]?,
        cached: [StockChartPoint]?,
        market: StockMarket
    ) -> [StockChartPoint]? {
        let merged = StockChartSeriesProcessor.mergedPoints(
            cached ?? [],
            with: remote ?? [],
            kind: .intraday,
            market: market
        )
        return merged.isEmpty ? nil : merged
    }

    private func needsDailyTechnicalSupport(
        in store: StockChartPersistedStore,
        now: Date,
        refreshingRange: StockChartRange? = nil
    ) -> Bool {
        let dailyPoints = store.series[StockChartSeriesKind.daily.rawValue] ?? []
        guard dailyPoints.count >= 60 else { return true }
        if let refreshingRange {
            let visibleKind = StockChartSeriesProcessor.seriesKind(for: refreshingRange)
            let isDailyVisibleRange = visibleKind == .daily
            let earliestDailyDate = dailyPoints.map(\.date).min()
            if refreshingRange.isKLineRange,
               !isDailyVisibleRange,
               let visibleSeries = store.series[visibleKind.rawValue],
               let visibleStartDate = visibleSeries.map(\.date).min(),
               let earliestDailyDate,
               earliestDailyDate > visibleStartDate {
                return true
            }
            if !isDailyVisibleRange,
               let requiredStartDate = dailyTechnicalStartDate(
                   for: refreshingRange,
                   endingAt: now,
                   market: store.market
               ),
               let earliestDailyDate {
                if earliestDailyDate > requiredStartDate {
                    return true
                }
            }
            if isDailyVisibleRange {
                return false
            }
        }

        let dailyMetadata = store.rangeMetadata[StockChartRange.dayK.rawValue]
        guard let dailyMetadata else { return true }
        if dailyMetadata.dailyIndicatorPointCount != nil {
            return false
        }
        return now.timeIntervalSince(dailyMetadata.fetchedAt)
            >= StockChartRange.dayK.cacheLifetime
    }

    private func dailyTechnicalRange(for range: StockChartRange) -> StockChartRange? {
        guard range != .intraday else { return nil }
        return .dayK
    }

    private func dailyTechnicalStartDate(
        for range: StockChartRange,
        endingAt endDate: Date,
        market: StockMarket
    ) -> Date? {
        let calendar = StockChartSeriesProcessor.marketCalendar(market)
        switch range {
        case .fiveDays:
            return calendar.date(byAdding: .month, value: -2, to: endDate)
        case .weekK:
            return calendar.date(byAdding: .month, value: -30, to: endDate)
        case .monthK:
            return calendar.date(byAdding: .year, value: -7, to: endDate)
        case .quarterK:
            return calendar.date(byAdding: .year, value: -12, to: endDate)
        case .intraday, .dayK, .yearK:
            return nil
        }
    }
}

#endif
