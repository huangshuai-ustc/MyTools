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

    /// Manual refresh also repairs closed-market quotes and minute data.
    /// A supplied stock ID keeps the request scoped to the current chart.
    func refreshManually(
        for requestedMarket: StockMarket? = nil,
        prioritizedStockID: UUID? = nil,
        refreshMarketCharts: Bool = false,
        at now: Date = Date()
    ) async {
        guard let store, isStockModuleVisible, store.isDataLoaded else { return }
        let markets = requestedMarket.map { [$0] } ?? StockMarket.allCases
        for market in markets {
            let session = StockMarketTradingCalendar.session(for: market, at: now)
            if session != .closed {
                // 持仓列表只刷新批量报价；看盘列表额外刷新当前市场全部分钟
                // 缓存，让迷你图通过同一缓存广播立即重绘。单股看盘/详情仍只刷新
                // 目标股票。港股保持分时在前，让延迟报价可用本轮末点修正。
                let shouldRefreshCharts = refreshMarketCharts || prioritizedStockID != nil
                if market == .hongKong, shouldRefreshCharts {
                    await store.refreshIntradayCharts(
                        for: market,
                        stockID: prioritizedStockID,
                        forceRefresh: true
                    )
                    await store.refreshQuotes(
                        for: market,
                        stockID: prioritizedStockID,
                        forceRefresh: true
                    )
                } else {
                    async let quotes: Void = store.refreshQuotes(
                        for: market,
                        stockID: prioritizedStockID,
                        forceRefresh: true
                    )
                    if shouldRefreshCharts {
                        await store.refreshIntradayCharts(
                            for: market,
                            stockID: prioritizedStockID,
                            forceRefresh: true
                        )
                    }
                    await quotes
                }
                continue
            }
            // Inspect quote and minute coverage independently. Completed data
            // never creates traffic just because the user taps Refresh again.
            let targets = store.stocks.filter {
                $0.market == market && $0.hasConfiguredSymbol && !$0.isArchived
                    && (prioritizedStockID == nil || $0.id == prioritizedStockID)
            }
            var chartIDs: Set<UUID> = []
            for stock in targets {
                guard !Task.isCancelled else { return }
                let snapshot = await chartService.cachedChart(for: stock, range: .intraday)
                if Self.needsClosedChartRefresh(stock: stock, snapshot: snapshot, at: now) {
                    chartIDs.insert(stock.id)
                }
            }
            if !chartIDs.isEmpty {
                await store.refreshIntradayCharts(for: market, stockIDs: chartIDs, forceRefresh: true)
            }
            let targetIDs = Set(targets.map(\.id))
            let quoteIDs = Set(store.stocks.filter {
                targetIDs.contains($0.id) && Self.needsClosedQuoteRefresh(stock: $0, at: now)
            }.map(\.id))
            if !quoteIDs.isEmpty {
                await store.refreshQuotes(for: market, stockIDs: quoteIDs, forceRefresh: true)
            }
            DiagnosticLogger.shared.log(.stockQuote, "休市手动检查 market=\(market.rawValue) targets=\(targets.count) charts=\(chartIDs.count) quotes=\(quoteIDs.count)")
        }
        lastRefreshCompletedAt = Date()
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
                        guard !Task.isCancelled, await chartService.isChartStale(for: stock) else { return nil }
                        do {
                            try await chartService.refreshAfterFinalSession(for: stock)
                            return stock.id
                        } catch {
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
            guard store.stocks.contains(where: { $0.market == market && $0.hasConfiguredSymbol }) else {
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
                DiagnosticLogger.shared.log(.lifecycle, "股票后台刷新达到时间预算，未完成标的保留到下次重试", level: .warning)
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
final class StockRefreshAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.supportedOrientations
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
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
#if MYTOOLS_FEATURE_SPORTS_LOTTERY
        SportsLotteryRefreshCoordinator.registerBackgroundTask()
#endif
        return true
    }
}
#endif

#endif
