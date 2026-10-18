#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

#if os(iOS)
import BackgroundTasks
import UIKit

private enum StockBackgroundTaskCallbacks {
    static func expirationHandler(for work: Task<Void, Never>) -> () -> Void {
        { work.cancel() }
    }
}
#endif

@MainActor
final class StockRefreshCoordinator: ObservableObject {
    static let shared = StockRefreshCoordinator()

#if os(iOS)
    static let taskIdentifier = AppMetadata.stockRefreshTaskIdentifier
#endif

    private weak var store: StockStore?
    private var isStockModuleVisible: Bool = true
    private var foregroundTask: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var lastClosingRefreshSessionEndByMarket: [StockMarket: Date] = [:]
    private var lastClosingRefreshAttemptAtByMarket: [StockMarket: Date] = [:]
    private var lastClosingChartRefreshAttemptAtByMarket: [StockMarket: Date] = [:]
    /// 每个市场每个收盘时点的补刷次数。停牌等永远补不齐的股票不能每 5 分钟
    /// 强刷到下一个交易日（AUDIT-056）。按 5 分钟冷却，上限覆盖收盘后约 1 小时。
    private var closingQuoteAttempts: [StockMarket: (sessionEnd: Date, count: Int)] = [:]
    private var closingChartAttempts: [StockMarket: (sessionEnd: Date, count: Int)] = [:]
    static let maxClosingRefreshAttempts = 12

    /// 记一次补刷；同一收盘时点超过上限后返回 false。
    private static func recordClosingAttempt(
        _ attempts: inout [StockMarket: (sessionEnd: Date, count: Int)],
        market: StockMarket,
        sessionEnd: Date
    ) -> Bool {
        let count = attempts[market].map { $0.sessionEnd == sessionEnd ? $0.count : 0 } ?? 0
        guard count < maxClosingRefreshAttempts else { return false }
        attempts[market] = (sessionEnd, count + 1)
        return true
    }
    private var isAutomaticRefreshRunning = false
    private var currentScenePhase: ScenePhase = .inactive
    /// Each visible stock screen owns a token. A single Boolean was insufficient:
    /// pushing detail used to overwrite the list's visibility and multi-window
    /// scenes could stop each other's polling.
    private var visibleScreenTokens: Set<UUID> = []
    private var chartStockIDsByScreen: [UUID: Set<UUID>] = [:]
    private let chartService: any StockChartServing

    /// Bumped whenever an automatic refresh cycle completes, regardless of
    /// whether it changed anything. Observers that only read disk-cached data
    /// (e.g. the portfolio value history) use this instead of running their
    /// own polling timer, so there is a single refresh cadence to reason about.
    @Published private(set) var lastRefreshCompletedAt: Date?

    init(chartService: any StockChartServing = StockChartService.shared) {
        self.chartService = chartService
    }

    func attach(store: StockStore, isModuleVisible: Bool = true) {
        self.store = store
        self.isStockModuleVisible = isModuleVisible
        reconcileForegroundPolling()
    }

    func updateModuleVisibility(_ isVisible: Bool) {
        isStockModuleVisible = isVisible
        reconcileForegroundPolling()
    }

    func update(scenePhase: ScenePhase) {
        currentScenePhase = scenePhase
        switch scenePhase {
        case .active:
            reconcileForegroundPolling()
#if os(iOS)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
#endif
        case .background:
            stopForegroundPolling()
            scheduleBackgroundRefresh()
        case .inactive:
            stopForegroundPolling()
        @unknown default:
            break
        }
    }

    /// Foreground quote polling is useful while the stock page is visible. If
    /// the user is elsewhere, keep it running only when a stock alert needs
    /// background evaluation; otherwise updates would invalidate every page in
    /// the navigation stack once per minute.
    func setStockScreen(
        _ token: UUID,
        isVisible: Bool,
        chartStockIDs: Set<UUID> = []
    ) {
        if isVisible {
            visibleScreenTokens.insert(token)
            chartStockIDsByScreen[token] = chartStockIDs
        } else {
            visibleScreenTokens.remove(token)
            chartStockIDsByScreen[token] = nil
        }
        reconcileForegroundPolling()
    }

    private var focusedChartStockIDs: Set<UUID> {
        chartStockIDsByScreen.values.reduce(into: Set<UUID>()) {
            $0.formUnion($1)
        }
    }

    func refreshEligibilityChanged() {
        if !isStockModuleVisible {
#if os(iOS)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
#endif
        }
        reconcileForegroundPolling()
    }

    /// Triggers a closing-data refresh check immediately, outside the regular
    /// polling interval. Intended for call sites that become visible after a
    /// long absence, such as the stocks list on app launch or page entry.
    func triggerClosingRefreshIfNeeded() {
        Task { @MainActor [weak self] in
            await self?.refreshAutomatically()
        }
    }

    /// The only page-facing minute refresh entry. It feeds the same Store
    /// queue, per-stock throttle and cache-update broadcast as polling/manual
    /// refreshes; views never call StockChartService for minute networking.
    func refreshChart(
        for stockID: UUID,
        range: StockChartRange = .intraday,
        forceRefresh: Bool = false
    ) async {
        guard let store,
              let stock = store.stocks.first(where: { $0.id == stockID }) else {
            return
        }
        if range == .fiveDays {
            await store.refreshFiveDayHistory(for: stockID, forceRefresh: forceRefresh)
            return
        }
        // A cold cache must be repairable after close too. Merely opening a
        // cached chart never reaches this method.
        await store.refreshIntradayCharts(
            for: stock.market,
            stockID: stockID,
            forceRefresh: forceRefresh
        )
    }

    /// Manual refresh covers only the stocks on the calling page (`stockIDs`,
    /// or the single `prioritizedStockID`). All markets are batched into one
    /// intraday and one quote request so they run in parallel. Open markets
    /// force intraday first, then five-day history; closed markets only repair
    /// what the local cache is missing, so a complete close creates no traffic.
    func refreshManually(
        for requestedMarket: StockMarket? = nil,
        stockIDs requestedIDs: Set<UUID>? = nil,
        prioritizedStockID: UUID? = nil,
        refreshMarketCharts: Bool = false,
        refreshFiveDayCharts: Bool = false,
        at now: Date = Date()
    ) async {
        guard let store, isStockModuleVisible, store.isDataLoaded else { return }
        let scope = prioritizedStockID.map { Set([$0]) } ?? requestedIDs
        let targets = store.stocks.filter {
            $0.hasConfiguredSymbol && !$0.isArchived
                && (requestedMarket == nil || $0.market == requestedMarket)
                && (scope?.contains($0.id) ?? true)
        }
        let isOpen = Dictionary(uniqueKeysWithValues: StockMarket.allCases.map {
            ($0, StockMarketTradingCalendar.session(for: $0, at: now) != .closed)
        })
        let openTargets = targets.filter { isOpen[$0.market] == true }
        let closedTargets = targets.filter { isOpen[$0.market] != true }
        let shouldRefreshCharts = refreshMarketCharts || refreshFiveDayCharts || prioritizedStockID != nil

        var chartIDs = shouldRefreshCharts ? Set(openTargets.map(\.id)) : []
        for stock in closedTargets {
            guard !Task.isCancelled else { return }
            let snapshot = await chartService.cachedChart(for: stock, range: .intraday)
            if Self.needsClosedChartRefresh(stock: stock, snapshot: snapshot, at: now) {
                chartIDs.insert(stock.id)
            }
        }
        // Hong Kong quotes are corrected from the live minute tail, so they
        // wait for intraday; other open markets fetch quotes alongside it.
        let earlyQuoteIDs = Set(openTargets.filter {
            !shouldRefreshCharts || $0.market != .hongKong
        }.map(\.id))
        var lateQuoteIDs = Set(openTargets.map(\.id)).subtracting(earlyQuoteIDs)
        lateQuoteIDs.formUnion(closedTargets.filter {
            Self.needsClosedQuoteRefresh(stock: $0, at: now)
        }.map(\.id))

        async let earlyQuotes: Void = Self.refreshQuotes(earlyQuoteIDs, in: store)
        if !chartIDs.isEmpty {
            await store.refreshIntradayCharts(stockIDs: chartIDs, forceRefresh: true)
        }
        async let lateQuotes: Void = Self.refreshQuotes(lateQuoteIDs, in: store)
        var fiveDayIDs: Set<UUID> = []
        if refreshFiveDayCharts, !Task.isCancelled {
            fiveDayIDs = Set(openTargets.map(\.id))
            // Checked after the intraday repair: both ranges share one minute
            // series, so a just-repaired close may already cover five days.
            for stock in closedTargets {
                let snapshot = await chartService.cachedChart(for: stock, range: .fiveDays)
                if Self.needsClosedFiveDayRefresh(stock: stock, snapshot: snapshot, at: now) {
                    fiveDayIDs.insert(stock.id)
                }
            }
            // The chart service bounds provider concurrency. Each successful
            // commit broadcasts its stock ID; failures never undo intraday.
            await withTaskGroup(of: Void.self) { group in
                for stockID in fiveDayIDs {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        await store.refreshFiveDayHistory(for: stockID, forceRefresh: true)
                    }
                }
            }
        }
        await lateQuotes
        await earlyQuotes
        DiagnosticLogger.shared.log(.stockQuote, "手动刷新 targets=\(targets.count) closed=\(closedTargets.count) charts=\(chartIDs.count) quotes=\(earlyQuoteIDs.count + lateQuoteIDs.count) fiveDays=\(fiveDayIDs.count)")
        guard !Task.isCancelled else { return }
        lastRefreshCompletedAt = Date()
    }

    private static func refreshQuotes(_ stockIDs: Set<UUID>, in store: StockStore) async {
        guard !stockIDs.isEmpty else { return }
        await store.refreshQuotes(stockIDs: stockIDs, forceRefresh: true)
    }

    static func needsClosedQuoteRefresh(stock: StockHolding, at now: Date) -> Bool {
        guard let end = StockMarketTradingCalendar.latestCompletedRegularSessionEnd(for: stock.market, at: now),
              let timestamp = stock.lastQuoteAt, timestamp >= end, timestamp <= now.addingTimeInterval(300),
              let price = stock.latestPrice, price > 0,
              let previousClose = stock.previousClose, previousClose > 0 else { return true }
        return false
    }

    static func needsClosedChartRefresh(stock: StockHolding, snapshot: StockChartSnapshot?, at now: Date) -> Bool {
        guard let snapshot,
              let end = StockMarketTradingCalendar.latestCompletedRegularSessionEnd(for: stock.market, at: now) else { return true }
        let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
        let startStamped = StockMarketTradingCalendar.postMarketMinuteRange(for: stock.market) != nil
        let requiredRegular = startStamped ? end.addingTimeInterval(-60) : end
        let regularComplete = snapshot.points.contains {
            calendar.isDate($0.date, inSameDayAs: end) && $0.date >= requiredRegular
                && $0.date <= end && $0.close > 0
        }
        guard regularComplete else { return true }
        if let postMarket = StockMarketTradingCalendar.postMarketMinuteRange(for: stock.market),
           let extendedEnd = calendar.date(byAdding: .minute, value: postMarket.end, to: calendar.startOfDay(for: end)),
           extendedEnd <= now {
            return !snapshot.postMarketPoints.contains {
                $0.date >= extendedEnd.addingTimeInterval(-60) && $0.date <= extendedEnd && $0.close > 0
            }
        }
        return false
    }

    /// `cachedChart(.fiveDays)` is nil until five trading days are covered.
    /// The latest day shares the intraday series, whose closing minutes are
    /// repaired by `needsClosedChartRefresh`, so only its presence is checked.
    static func needsClosedFiveDayRefresh(stock: StockHolding, snapshot: StockChartSnapshot?, at now: Date) -> Bool {
        guard let snapshot,
              let end = StockMarketTradingCalendar.latestCompletedRegularSessionEnd(for: stock.market, at: now) else { return true }
        let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
        return !snapshot.points.contains { calendar.isDate($0.date, inSameDayAs: end) && $0.close > 0 }
    }

    private var shouldPollInForeground: Bool {
        guard currentScenePhase == .active,
              isStockModuleVisible,
              let store,
              store.isDataLoaded,
              hasRefreshableStocks(in: store) else { return false }
        return !visibleScreenTokens.isEmpty
            || hasEnabledRefreshableAlert(in: store)
    }

    private func hasRefreshableStocks(in store: StockStore) -> Bool {
        store.stocks.contains { $0.hasConfiguredSymbol && !$0.isArchived }
    }

    private func hasEnabledRefreshableAlert(in store: StockStore) -> Bool {
        let refreshableStockIDs = Set(
            store.stocks.lazy
                .filter { $0.hasConfiguredSymbol && !$0.isArchived }
                .map(\.id)
        )
        return store.priceAlerts.contains {
            $0.isEnabled && $0.stockID.map(refreshableStockIDs.contains) == true
        } || store.returnAlerts.contains {
            $0.isEnabled && $0.stockID.map(refreshableStockIDs.contains) == true
        }
    }

    private func reconcileForegroundPolling() {
        if shouldPollInForeground {
            startForegroundPolling()
        } else {
            stopForegroundPolling()
        }
    }

    private func startForegroundPolling() {
        guard foregroundTask == nil else { return }
        foregroundTask = Task { @MainActor [weak self] in
            DiagnosticLogger.shared.log(.lifecycle, "股票前台轮询启动")
            while !Task.isCancelled {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.shouldPollInForeground else {
                    self.stopForegroundPolling()
                    return
                }
                let started = ContinuousClock.now
                await self.refreshAutomatically()
                let remaining = Duration.seconds(60) - started.duration(to: .now)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
            }
        }
    }

    private func refreshAutomatically() async {
        guard let store,
              isStockModuleVisible,
              store.isDataLoaded,
              !isAutomaticRefreshRunning else { return }
        isAutomaticRefreshRunning = true
        defer {
            isAutomaticRefreshRunning = false
            lastRefreshCompletedAt = Date()
        }

        let now = Date()

        // 活跃市场优先。原先先串行补刷所有已收市市场，午夜打开美股页面时，
        // A/港股的日 K 补刷会挡在美股报价之前，看起来就像刷新完全失效。
        let closingQuoteSessions = closingQuoteSessionsNeedingRefresh(
            store: store,
            now: now
        )
        let closingQuoteMarkets = Set(closingQuoteSessions.keys)
        if !closingQuoteMarkets.isEmpty {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "检测到收盘报价补刷市场：\(closingQuoteMarkets.map { $0.rawValue }.sorted().joined(separator: ","))"
            )
        }
        // One set request reaches the Store's concurrent worker pool. The
        // former per-ID await accidentally serialized every minute provider.
        async let minuteRefresh: Void = refreshFocusedIntradayIfNeeded(in: store, now: now)
        await store.refreshQuotes(
            forcedMarkets: closingQuoteMarkets,
            allowClosedMissingData: false
        )
        for (market, sessionEnd) in closingQuoteSessions {
            let targets = store.stocks.filter { $0.market == market && $0.hasConfiguredSymbol && !$0.isArchived }
            if !targets.isEmpty, targets.allSatisfy({ ($0.lastQuoteAt ?? .distantPast) >= sessionEnd }) {
                lastClosingRefreshSessionEndByMarket[market] = sessionEnd
            }
        }
        await minuteRefresh
        guard !Task.isCancelled else { return }

        guard closingTask == nil else { return }
        let closingChartSessions = closingChartSessionsNeedingRefresh(
            store: store,
            now: now
        )
        if !closingChartSessions.isEmpty {
            if currentScenePhase == .active {
                if closingTask == nil {
                    closingTask = Task { [weak self] in
                        guard let self else { return }
                        await self.refreshClosingData(in: store, sessions: closingChartSessions)
                        self.closingTask = nil
                    }
                }
            } else {
                await refreshClosingData(in: store, sessions: closingChartSessions)
            }
        }
    }

    private func closingChartSessionsNeedingRefresh(
        store: StockStore,
        now: Date
    ) -> [StockMarket: Date] {
        var result: [StockMarket: Date] = [:]
        for market in StockMarket.allCases {
            let session = StockMarketTradingCalendar.session(for: market, at: now)
            // The complete source refresh is keyed to the final regular-session
            // close. For US stocks it can run during post-market while the
            // completed regular-session data is already available.
            // Daily/K-line aggregation can start as soon as the final regular
            // session closes. US post-market remains live for minute updates,
            // but it must not postpone the completed regular day's daily bar.
            guard (session == .closed
                    || (market == .unitedStates && session == .postMarket)),
                  store.stocks.contains(where: {
                      $0.market == market
                          && $0.hasConfiguredSymbol
                          && !$0.isArchived
                  }),
                  let sessionEnd = StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
                      for: market,
                      at: now
                  ) else {
                continue
            }
            // Empty provider responses can be transient just after close.
            // Retry after the cooldown instead of suppressing the entire day.
            if let attemptedAt = lastClosingChartRefreshAttemptAtByMarket[market],
               now.timeIntervalSince(attemptedAt) < 5 * 60 {
                continue
            }
            guard Self.recordClosingAttempt(
                &closingChartAttempts, market: market, sessionEnd: sessionEnd
            ) else { continue }
            lastClosingChartRefreshAttemptAtByMarket[market] = now
            result[market] = sessionEnd
        }
        return result
    }

    private func refreshClosingData(
        in store: StockStore,
        sessions: [StockMarket: Date]
    ) async {
        let stocks = store.stocks.filter {
            sessions[$0.market] != nil
                && $0.hasConfiguredSymbol
                && !$0.isArchived
        }
        for market in StockMarket.displayOrder where sessions[market] != nil {
            await withTaskGroup(of: UUID?.self) { group in
                for stock in stocks where stock.market == market {
                    group.addTask { [chartService] in
                        // `stocks` 是开始时的快照；跳过之后被删除或存档的股票（AUDIT-051）。
                        let isCurrent = await MainActor.run {
                            store.stocks.contains { $0.id == stock.id && !$0.isArchived }
                        }
                        guard isCurrent, !Task.isCancelled,
                              await chartService.isChartStale(for: stock) else { return nil }
                        do {
                            try await chartService.refreshAfterFinalSession(for: stock)
                            return stock.id
                        } catch is CancellationError {
                            return nil
                        } catch {
                            guard !Task.isCancelled else { return nil }
                            DiagnosticLogger.logError(.stockQuote, operation: "收盘数据补齐", error: error)
                            return nil
                        }
                    }
                }
                for await id in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let id, store.stocks.contains(where: { $0.id == id && !$0.isArchived }) {
                        await store.chartCacheDidUpdate(for: [id], includesDailyBars: true)
                    }
                }
            }
        }
    }

    private func closingQuoteSessionsNeedingRefresh(
        store: StockStore,
        now: Date
    ) -> [StockMarket: Date] {
        var result: [StockMarket: Date] = [:]
        for market in StockMarket.allCases {
            // The post-market interval belongs to the chart's extended-hours
            // stream. Do not force a regular quote refresh until it has ended.
            guard StockMarketTradingCalendar.session(for: market, at: now) == .closed else {
                continue
            }
            guard store.stocks.contains(where: {
                $0.market == market && $0.hasConfiguredSymbol && !$0.isArchived
            }) else {
                continue
            }

            // A provider may still return the same intraday quote after close.
            // De-duplicate by the actual final session, so a lunch break cannot
            // consume the closing refresh for the same trading day.
            guard let sessionEnd = StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
                for: market,
                at: now
            ) else { continue }
            if lastClosingRefreshSessionEndByMarket[market] == sessionEnd {
                continue
            }
            if let attemptedAt = lastClosingRefreshAttemptAtByMarket[market],
               now.timeIntervalSince(attemptedAt) < 5 * 60 {
                continue
            }
            guard Self.recordClosingAttempt(
                &closingQuoteAttempts, market: market, sessionEnd: sessionEnd
            ) else { continue }
            lastClosingRefreshAttemptAtByMarket[market] = now
            result[market] = sessionEnd
        }
        return result
    }

    /// Automatic minute traffic follows actual chart focus. The quote service
    /// remains the batch producer for list rows; opening one chart adds only
    /// that stock to the minute producer. StockStore applies the per-stock
    /// 60-second throttle and broadcasts successful cache writes.
    private func refreshFocusedIntradayIfNeeded(
        in store: StockStore,
        now: Date
    ) async {
        var ids = currentScenePhase == .active ? focusedChartStockIDs : []
        // Session changes and OS background launches have no page callback.
        // Held US positions still need the extended-hours price producer.
        for stock in store.stocks where stock.market == .unitedStates && stock.currentShares > 0 {
            let session = StockMarketTradingCalendar.session(for: stock.market, at: now)
            if session == .preMarket || session == .postMarket { ids.insert(stock.id) }
        }
        let activeIDs = Set(store.stocks.filter {
            ids.contains($0.id) && !$0.isArchived
                && StockMarketTradingCalendar.session(for: $0.market, at: now) != .closed
        }.map(\.id))
        guard !activeIDs.isEmpty else { return }
        await store.refreshIntradayCharts(stockIDs: activeIDs, forceRefresh: false)
    }

    private func stopForegroundPolling() {
        closingTask?.cancel()
        closingTask = nil
        guard foregroundTask != nil else { return }
        foregroundTask?.cancel()
        foregroundTask = nil
        DiagnosticLogger.shared.log(.lifecycle, "股票前台轮询停止")
    }

    private func scheduleBackgroundRefresh() {
#if os(iOS)
        guard isStockModuleVisible,
              store.map(hasRefreshableStocks(in:)) == true else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            DiagnosticLogger.logError(.stockQuote, operation: "预约股票后台刷新失败", error: error)
        }
#endif
    }

#if os(iOS)
    func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        DiagnosticLogger.shared.log(.lifecycle, "系统投递股票后台刷新")
        guard isStockModuleVisible else {
            task.setTaskCompleted(success: true)
            return
        }
        scheduleBackgroundRefresh()
        let work = Task { @MainActor [weak self] in
            guard let self, let store = self.store else {
                task.setTaskCompleted(success: false)
                return
            }
            for _ in 0..<20 where !store.isDataLoaded {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, store.isDataLoaded else {
                task.setTaskCompleted(success: false)
                return
            }
            var completed = false
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { group.cancelAll() }
                    group.addTask { await self.refreshAutomatically() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(25))
                        throw CancellationError()
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
                completed = true
            } catch is CancellationError {
                DiagnosticLogger.shared.log(.lifecycle, "股票后台刷新达到时间预算，未完成标的保留到下次重试")
            } catch {
                DiagnosticLogger.logError(.stockQuote, operation: "股票后台刷新", error: error)
            }
            DiagnosticLogger.shared.log(.lifecycle, "股票后台刷新结束 cancelled=\(Task.isCancelled)")
            task.setTaskCompleted(success: completed && !Task.isCancelled)
        }
        task.expirationHandler = StockBackgroundTaskCallbacks.expirationHandler(for: work)
    }
#endif
}

#if os(iOS)
extension StockRefreshCoordinator {
    /// Called by the App delegate at launch.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: StockRefreshCoordinator.taskIdentifier,
            // UIApplicationDelegate and StockRefreshCoordinator are MainActor-isolated.
            // Register on the main queue so BackgroundTasks does not invoke this
            // closure on its default background queue and trip Swift's executor check.
            using: .main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            StockRefreshCoordinator.shared.handleBackgroundRefresh(refreshTask)
        }
    }
}
#endif

#endif
