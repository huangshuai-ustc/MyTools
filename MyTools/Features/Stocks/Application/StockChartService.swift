#if MYTOOLS_FEATURE_STOCKS
import Foundation

/// A consumer can stop waiting even when a third-party producer ignores
/// cancellation. Late results cannot resume a completed continuation twice.
private final class StockChartResultWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<StockChartSnapshot, Error>?
    private var continuation: CheckedContinuation<StockChartSnapshot, Error>?

    func value() async throws -> StockChartSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Result<StockChartSnapshot, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private actor StockChartRemoteRequestGate {
    /// Keep a generous ceiling to protect the process from accidental request
    /// storms while still allowing a market-sized watchlist to use the device
    /// and network concurrently. US intraday requests may fan out to two
    /// providers inside one permit.
    private let limit: Int
    private var occupied = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(limit: Int = 24) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if occupied < limit {
            occupied += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    func release() {
        if waiters.isEmpty {
            occupied = max(0, occupied - 1)
        } else {
            waiters.removeFirst().1.resume()
        }
    }
}

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

    /// Returns true when the on-disk chart data for a stock is older than
    /// the market's latest completed final session — i.e. a closing refresh
    /// is actually needed. This reads only the local disk cache and makes no
    /// network requests, so it is safe to call before deciding whether to
    /// trigger a refresh.
    func isChartStale(for stock: StockHolding) async -> Bool

    /// Removes in-memory and on-disk chart data for a single stock.
    func clearCache(for stock: StockHolding) async
}

actor StockChartService: StockChartServing {
    static let shared = StockChartService()

    private var diskStore: StockChartDiskStore
    private let remoteRequestGate = StockChartRemoteRequestGate()
    private let providers: StockChartProviders
    private var lastRefreshSessionEnd: [StockChartCacheKey: Date] = [:]
    private var cacheGeneration = 0
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
        var consumers: [UUID: StockChartResultWaiter] = [:]
    }
    private var flights: [StockChartCacheKey: Flight] = [:]
    private struct RenderedEntry {
        let day: Date
        let snapshot: StockChartSnapshot
    }
    private var renderedCache: [StockChartCacheKey: RenderedEntry] = [:]
    private var lastAttempt: [StockChartCacheKey: Date] = [:]
    private static let requestTimeout: Duration = .seconds(12)
    private let flightTimeout: Duration

    init(
        diskStore: StockChartDiskStore = StockChartDiskStore(),
        providers: StockChartProviders = StockChartProviders(),
        flightTimeout: Duration = .seconds(18)
    ) {
        self.diskStore = diskStore
        self.providers = providers
        self.flightTimeout = flightTimeout
    }

    func cachedChart(
        for stock: StockHolding,
        range: StockChartRange
    ) async -> StockChartSnapshot? {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { return nil }
        let key = StockChartStoreKey(market: stock.market, symbol: symbol)
        let cacheKey = StockChartCacheKey(market: stock.market, symbol: symbol, range: range)
        let day = StockChartSeriesProcessor.marketCalendar(stock.market).startOfDay(for: Date())
        if let cached = renderedCache[cacheKey], cached.day == day { return cached.snapshot }
        guard let store = diskStore.load(for: key) else { return nil }
        if range == .fiveDays, !diskStore.hasRequestedCoverage(in: store, for: range) { return nil }
        guard let snapshot = diskStore.renderedSnapshot(from: store, range: range) else { return nil }
        if renderedCache.count >= 128 { renderedCache.removeAll(keepingCapacity: true) }
        renderedCache[cacheKey] = RenderedEntry(day: day, snapshot: snapshot)
        return snapshot
    }

    func fetchChart(
        for stock: StockHolding, range: StockChartRange, forceRefresh: Bool = false
    ) async throws -> StockChartSnapshot {
        try Task.checkCancellation()
        let key = StockChartCacheKey(market: stock.market,
            symbol: StockHolding.normalizedSymbol(stock.symbol, market: stock.market),
            range: range.isKLineRange ? .dayK : range)
        let consumerID = UUID()
        let waiter = StockChartResultWaiter()
        let flightID: UUID
        if let existing = flights[key] {
            flightID = existing.id
        } else {
            flightID = UUID()
            let task = Task {
                let result: Result<StockChartSnapshot, Error>
                do { result = .success(try await self.fetchAndCommitChart(for: stock, range: key.range, forceRefresh: forceRefresh)) }
                catch { result = .failure(error) }
                self.finishFlight(key, id: flightID, result: result)
            }
            let timeout = flightTimeout
            let deadline = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                self.finishFlight(key, id: flightID, result: .failure(URLError(.timedOut)))
            }
            flights[key] = Flight(id: flightID, task: task, deadline: deadline)
        }
        flights[key]?.consumers[consumerID] = waiter
        let snapshot = try await withTaskCancellationHandler {
            try await waiter.value()
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
            Task { await self.cancelConsumer(consumerID, key: key, flightID: flightID) }
        }
        try Task.checkCancellation()
        if range != key.range, let derived = await cachedChart(for: stock, range: range) { return derived }
        return snapshot
    }

    private func finishFlight(_ key: StockChartCacheKey, id: UUID, result: Result<StockChartSnapshot, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        flight.deadline.cancel()
        flight.task.cancel()
        for waiter in flight.consumers.values { waiter.finish(result) }
    }

    private func cancelConsumer(_ id: UUID, key: StockChartCacheKey, flightID: UUID) {
        guard flights[key]?.id == flightID else { return }
        flights[key]?.consumers[id] = nil
        if flights[key]?.consumers.isEmpty == true {
            lastAttempt[key] = nil
            finishFlight(key, id: flightID, result: .failure(CancellationError()))
        }
    }

    private func fetchAndCommitChart(
        for stock: StockHolding,
        range: StockChartRange,
        forceRefresh: Bool
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
        // Re-entering a page after a failed/incomplete response must not hammer
        // its provider. Explicit refresh bypasses this short retry window.
        if !forceRefresh, let attempted = lastAttempt[cacheKey], now.timeIntervalSince(attempted) < 60 {
            if let cached { return cached }
            throw StockChartError.noData
        }
        if let cached,
           let stored,
           localCacheIsComplete(
                stored,
                snapshot: cached,
                for: cacheKey,
                forceRefresh: forceRefresh,
                now: now
           ) {
            return cached
        }

        do {
            lastAttempt[cacheKey] = now
            // Daily bars are the sole persisted/network source for every
            // K-line tab. Week/month/quarter/year are always rebuilt locally
            // by StockChartDiskStore; never issue a provider request for a
            // presentation aggregation.
            let sourceRange: StockChartRange = range.isKLineRange ? .dayK : range
            let request = StockChartRequest(
                stock: stock,
                symbol: symbol,
                range: sourceRange
            )
            let remoteSnapshot = try await fetchRemoteChartWithPermit(for: request)
            try Task.checkCancellation()
            let processingStarted = Date()
            guard let snapshot = StockChartSeriesProcessor.normalizedSnapshot(
                remoteSnapshot,
                range: sourceRange,
                market: stock.market,
                at: now
            ) else {
                throw StockChartError.noData
            }
            // Providers may publish the closing minutes incrementally. Merge
            // useful partial data; isChartStale still requires the closing bar.
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
               let warmupSnapshot = try? await fetchRemoteChartWithPermit(
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
            try Task.checkCancellation()
            let mergeStarted = Date()
            let updatedStore = diskStore.merging(
                scopedSnapshot,
                range: sourceRange,
                for: stockKey,
                into: diskStore.load(for: stockKey)
            )
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=合并指标 id=\(stock.id) ms=\(Int(Date().timeIntervalSince(mergeStarted) * 1000))")
            try Task.checkCancellation()
            if generation == cacheGeneration {
                let writeStarted = Date()
                diskStore.save(updatedStore, for: stockKey)
                DiagnosticLogger.shared.log(.stockQuote, "图表阶段=写盘 id=\(stock.id) ms=\(Int(Date().timeIntervalSince(writeStarted) * 1000))")
                renderedCache = renderedCache.filter { $0.key.market != stockKey.market || $0.key.symbol != stockKey.symbol }
                if range.isKLineRange
                    || !StockMarketTradingCalendar.isSessionActive(stock.market, at: now) {
                    let sessionEnd = StockMarketTradingCalendar
                        .latestCompletedFinalSessionEnd(for: stock.market, at: now)
                    lastRefreshSessionEnd[canonicalRefreshKey(for: cacheKey)] = sessionEnd
                }
            }
            let renderStarted = Date()
            let rendered = diskStore.renderedSnapshot(from: updatedStore, range: range) ?? scopedSnapshot
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=快照 id=\(stock.id) ms=\(Int(Date().timeIntervalSince(renderStarted) * 1000)) postProviderMs=\(Int(Date().timeIntervalSince(processingStarted) * 1000))")
            return rendered
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if !forceRefresh, let cached { return cached }
            throw error
        }
    }

    func refreshAfterFinalSession(for stock: StockHolding) async throws {
        var firstError: Error?
        // These are the canonical source series. The presentation layer
        // recalculates every MA/BOLL/MACD/RSI from them, while the disk store
        // derives weekly/monthly/quarterly/yearly K-lines from the daily set.
        for range in [StockChartRange.intraday, .dayK] {
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

    func isChartStale(for stock: StockHolding) async -> Bool {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { return false }
        guard let sessionEnd = StockMarketTradingCalendar
            .latestCompletedFinalSessionEnd(for: stock.market) else { return false }
        let key = StockChartStoreKey(market: stock.market, symbol: symbol)
        guard let stored = diskStore.load(for: key) else { return true }
        // The former `max(intradayFetchedAt, dayKFetchedAt)` check let a fresh
        // minute response hide a stale daily source. Verify both canonical
        // sources against the completed trading day instead; app-launch
        // catch-up can then repair whichever close pass was missed.
        let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
        let dailyPoints = stored.series[StockChartSeriesKind.daily.rawValue] ?? []
        let minutePoints = stored.series[StockChartSeriesKind.intraday.rawValue] ?? []
        let hasCompletedDailyBar = dailyPoints.contains {
            calendar.isDate($0.date, inSameDayAs: sessionEnd)
        }
        let completedDayMinutes = minutePoints.filter {
            calendar.isDate($0.date, inSameDayAs: sessionEnd)
        }
        let hasCompletedMinuteSession = StockChartSeriesProcessor
            .hasCompletedRegularSession(completedDayMinutes, market: stock.market)
        return !hasCompletedDailyBar || !hasCompletedMinuteSession
    }

    func clearCache() {
        cacheGeneration += 1
        renderedCache.removeAll()
        lastAttempt.removeAll()
        for (key, flight) in Array(flights) {
            finishFlight(key, id: flight.id, result: .failure(CancellationError()))
        }
        lastRefreshSessionEnd.removeAll()
        diskStore.removeAll()
    }

    func clearCache(for stock: StockHolding) {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { return }
        let key = StockChartStoreKey(market: stock.market, symbol: symbol)
        renderedCache = renderedCache.filter { $0.key.market != key.market || $0.key.symbol != key.symbol }
        lastAttempt = lastAttempt.filter { $0.key.market != key.market || $0.key.symbol != key.symbol }
        for flightKey in Array(flights.keys) where flightKey.market == key.market && flightKey.symbol == key.symbol {
            if let flight = flights[flightKey] {
                finishFlight(flightKey, id: flight.id, result: .failure(CancellationError()))
            }
        }
        lastRefreshSessionEnd = lastRefreshSessionEnd.filter { $0.key.market != stock.market || $0.key.symbol != symbol }
        diskStore.remove(for: key)
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
        if request.stock.market == .unitedStates,
           request.range == .intraday {
            // The two providers are independent. Starting Yahoo only after
            // Tencent returned doubled every US row's latency and amplified it
            // across a watchlist. Fetch both at once, then merge whichever
            // successful coverage is available.
            async let tencentResult = providerResult(
                providers.tencent,
                request: request
            )
            async let yahooResult = providerResult(
                providers.yahoo,
                request: request
            )
            let (tencent, yahoo) = await (tencentResult, yahooResult)
            switch (tencent, yahoo) {
            case let (.success(primary), .success(fallback)):
                return preferredUSIntradaySnapshot(
                    primary: primary,
                    fallback: fallback
                )
            case let (.success(snapshot), .failure):
                return snapshot
            case let (.failure, .success(snapshot)):
                return snapshot
            case let (.failure(firstError), .failure):
                guard !Task.isCancelled else { throw CancellationError() }
                if let fallback = try? await providers.nasdaq.fetchChart(for: request) {
                    return fallback
                }
                throw firstError
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

    private func providerResult(
        _ provider: any StockChartProvider,
        request: StockChartRequest
    ) async -> Result<StockChartSnapshot, Error> {
        do {
            return .success(try await provider.fetchChart(for: request))
        } catch {
            return .failure(error)
        }
    }

    /// Provider requests use a bounded high-concurrency pool. Actor reentrancy
    /// lets independent URLSession work proceed together; per-stock cache
    /// merging and disk commits remain actor-isolated and therefore ordered.
    private func fetchRemoteChartWithPermit(
        for request: StockChartRequest
    ) async throws -> StockChartSnapshot {
        try await remoteRequestGate.acquire()
        do {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=provider开始 symbol=\(request.symbol) range=\(request.range.rawValue)")
            let snapshot = try await withThrowingTaskGroup(of: StockChartSnapshot.self) { group in
                defer { group.cancelAll() }
                group.addTask { try await self.fetchRemoteChart(for: request) }
                group.addTask {
                    try await Task.sleep(for: Self.requestTimeout)
                    throw URLError(.timedOut)
                }
                guard let result = try await group.next() else { throw StockChartError.serviceUnavailable }
                group.cancelAll()
                return result
            }
            let elapsed = started.duration(to: .now).components
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=provider结束 symbol=\(request.symbol) range=\(request.range.rawValue) ms=\(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)")
            await remoteRequestGate.release()
            return snapshot
        } catch {
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=provider失败 symbol=\(request.symbol) range=\(request.range.rawValue) error=\(DiagnosticLogger.errorCode(error))", level: .warning)
            await remoteRequestGate.release()
            throw error
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
            points: preservingOfficialClose(
                in: denserMinuteSeries(primary.points, fallback.points),
                from: fallback.points
            ),
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
            ).map {
                preservingOfficialClose(
                    in: $0,
                    from: fallback.indicatorPoints ?? []
                )
            },
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

    /// Tencent often has denser regular-session coverage, while Yahoo carries
    /// the finalized exchange close. Preserve the dense series for history,
    /// then patch only its final regular-session bar with Yahoo's authoritative
    /// close so the chart agrees with the quote and official settlement value.
    private func preservingOfficialClose(
        in points: [StockChartPoint],
        from authoritativePoints: [StockChartPoint]
    ) -> [StockChartPoint] {
        guard var latest = points.last,
              let authoritative = authoritativePoints.last,
              StockChartSeriesProcessor.marketCalendar(.unitedStates)
                .isDate(latest.date, inSameDayAs: authoritative.date),
              authoritative.date >= latest.date else {
            return points
        }
        latest = StockChartPoint(
            date: latest.date,
            open: latest.open,
            high: max(latest.high, authoritative.close),
            low: min(latest.low, authoritative.close),
            close: authoritative.close,
            volume: latest.volume
        )
        var result = points
        result[result.count - 1] = latest
        return result
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
        switch session {
        case .preMarket:
            guard !snapshot.preMarketPoints.isEmpty else { return false }
            guard now.timeIntervalSince(snapshot.fetchedAt) < key.range.cacheLifetime else {
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
            guard !snapshot.postMarketPoints.isEmpty else { return false }
            guard now.timeIntervalSince(snapshot.fetchedAt) < key.range.cacheLifetime else {
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

    /// A K-line cache is complete when its canonical daily source covers the
    /// latest regular session that has actually finished. During the next
    /// pre-market or regular session that remains yesterday, so opening a K
    /// chart never turns into a real-time request. Once today's close passes,
    /// the missing daily bar makes this false and the closing catch-up fetches
    /// dayK once, which rebuilds every derived period locally.
    private func localCacheIsComplete(
        _ store: StockChartPersistedStore,
        snapshot: StockChartSnapshot,
        for key: StockChartCacheKey,
        forceRefresh: Bool,
        now: Date
    ) -> Bool {
        guard !forceRefresh else { return false }
        guard diskStore.hasRequestedCoverage(in: store, for: key.range),
              !needsMinuteTechnicalWarmup(
                  in: store,
                  range: key.range,
                  market: key.market
              ) else {
            return false
        }
        guard key.range.isKLineRange else {
            return shouldUseCachedChart(
                snapshot,
                for: key,
                forceRefresh: forceRefresh,
                now: now
            )
        }
        guard !needsDailyTechnicalSupport(
            in: store,
            now: now,
            refreshingRange: key.range
        ) else {
            return false
        }
        guard let completedClose = StockMarketTradingCalendar
            .latestCompletedFinalSessionEnd(for: key.market, at: now) else {
            return true
        }
        let calendar = StockChartSeriesProcessor.marketCalendar(key.market)
        return (store.series[StockChartSeriesKind.daily.rawValue] ?? []).contains {
            calendar.isDate($0.date, inSameDayAs: completedClose)
        }
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
