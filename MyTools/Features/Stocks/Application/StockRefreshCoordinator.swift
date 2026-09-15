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
    private var lastClosingRefreshSessionEndByMarket: [StockMarket: Date] = [:]
    private var lastClosingRefreshAttemptAtByMarket: [StockMarket: Date] = [:]
    private var lastClosingChartRefreshAttemptAtByMarket: [StockMarket: Date] = [:]
    // Markets whose last closing-chart refresh ended with noData are skipped
    // until the next session boundary so a permanent "no data" state (e.g. a
    // delisted symbol or a holiday with no data yet published) does not drive
    // a tight retry loop.
    private var closingChartNoDataSessionEndByMarket: [StockMarket: Date] = [:]
    private var isAutomaticRefreshRunning = false
    private var currentScenePhase: ScenePhase = .inactive
    private var isStocksPageVisible = false
    private let chartService: any StockChartServing

    /// Bumped whenever an automatic refresh cycle completes, regardless of
    /// whether it changed anything. Observers that only read disk-cached data
    /// (e.g. the portfolio value history) use this instead of running their
    /// own polling timer, so there is a single refresh cadence to reason about.
    @Published private(set) var lastRefreshCompletedAt: Date?

    private init(chartService: any StockChartServing = StockChartService.shared) {
        self.chartService = chartService
    }

    func attach(store: StockStore, isModuleVisible: Bool = true) {
        self.store = store
        self.isStockModuleVisible = isModuleVisible
        reconcileForegroundPolling()
    }

    func updateModuleVisibility(_ isVisible: Bool) {
        isStockModuleVisible = isVisible
        setStocksPageVisible(isStocksPageVisible && isVisible)
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
    func setStocksPageVisible(_ isVisible: Bool) {
        isStocksPageVisible = isVisible && isStockModuleVisible
        reconcileForegroundPolling()
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

    private var shouldPollInForeground: Bool {
        guard currentScenePhase == .active,
              isStockModuleVisible,
              let store,
              store.isDataLoaded,
              hasRefreshableStocks(in: store) else { return false }
        return isStocksPageVisible
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
                await self.refreshAutomatically()
                try? await Task.sleep(for: .seconds(60))
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

        let closingChartSessions = closingChartSessionsNeedingRefresh(
            store: store,
            now: now
        )
        if !closingChartSessions.isEmpty {
            await refreshClosingData(
                in: store,
                sessions: closingChartSessions
            )
        }

        await refreshExtendedHoursIntradayIfNeeded(in: store, now: now)
        await refreshIntradayDuringSessionIfNeeded(in: store, now: now)

        guard !store.isRefreshingQuotes else { return }
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
        let previousQuoteRefreshDates = closingQuoteMarkets.reduce(
            into: [StockMarket: Date]()
        ) { dates, market in
            if let refreshedAt = store.lastRefreshAt(for: market) {
                dates[market] = refreshedAt
            }
        }
        await store.refreshQuotes(
            forcedMarkets: closingQuoteMarkets,
            allowClosedMissingData: false
        )
        for (market, sessionEnd) in closingQuoteSessions
        where store.lastRefreshAt(for: market) != previousQuoteRefreshDates[market] {
            lastClosingRefreshSessionEndByMarket[market] = sessionEnd
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
            guard session == .closed,
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
            // A previous attempt for this session ended with noData — the
            // data source has nothing for this session yet. Skip until the
            // next session boundary rather than retrying every 5 minutes.
            if closingChartNoDataSessionEndByMarket[market] == sessionEnd {
                continue
            }
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
            var allFailedWithNoData = true
            var stalStockCount = 0
            for stock in stocks where stock.market == market {
                guard !Task.isCancelled else { return }
                // Skip stocks whose on-disk chart is already up to date for
                // this session — avoids redundant network requests after a
                // partial run or an app restart.
                let isStale = await chartService.isChartStale(for: stock)
                guard isStale else {
                    allFailedWithNoData = false
                    continue
                }
                stalStockCount += 1
                do {
                    _ = try await chartService.refreshAfterFinalSession(for: stock)
                    allFailedWithNoData = false
                } catch is CancellationError {
                    return
                } catch StockChartError.noData {
                    DiagnosticLogger.shared.log(
                        .stockQuote,
                        "收市完整行情补刷 \(stock.symbol)：数据源暂无数据，跳过本次收市补刷",
                        level: .warning
                    )
                } catch {
                    allFailedWithNoData = false
                    DiagnosticLogger.logError(
                        .stockQuote,
                        operation: "收市完整行情补刷 \(stock.symbol)",
                        error: error
                    )
                }
            }
            let marketStocks = stocks.filter { $0.market == market }
            if stalStockCount > 0 {
                DiagnosticLogger.shared.log(
                    .stockQuote,
                    "收市完整行情补刷：\(market.rawValue) 待刷 \(stalStockCount)/\(marketStocks.count) 只"
                )
            } else {
                DiagnosticLogger.shared.log(
                    .stockQuote,
                    "收市完整行情补刷：\(market.rawValue) 数据已最新，跳过"
                )
            }
            if let sessionEnd = sessions[market] {
                if allFailedWithNoData && !marketStocks.isEmpty && stalStockCount > 0 {
                    closingChartNoDataSessionEndByMarket[market] = sessionEnd
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

    /// Refreshes the intraday chart for US stocks during pre/post-market sessions.
    /// shouldUseCachedChart's 20 s cacheLifetime acts as the network throttle —
    /// no separate timer is needed here.
    private func refreshExtendedHoursIntradayIfNeeded(in store: StockStore, now: Date) async {
        let session = StockMarketTradingCalendar.session(for: .unitedStates, at: now)
        guard session == .preMarket || session == .postMarket else { return }
        let stocks = store.stocks.filter {
            $0.market == .unitedStates && $0.hasConfiguredSymbol && !$0.isArchived
        }
        guard !stocks.isEmpty else { return }
        for stock in stocks {
            guard !Task.isCancelled else { return }
            do {
                _ = try await chartService.fetchChart(for: stock, range: .intraday, forceRefresh: false)
            } catch is CancellationError {
                return
            } catch {
                DiagnosticLogger.logError(.stockQuote, operation: "延伸时段分时图 \(stock.symbol)", error: error)
            }
        }
    }

    /// Keeps the local minute chart cache current while a regular market is
    /// open. Portfolio history consumes this same cache for intraday and
    /// five-day ranges, so quote-only polling would otherwise leave it on the
    /// previous trading day's data.
    private func refreshIntradayDuringSessionIfNeeded(in store: StockStore, now: Date) async {
        let activeMarkets = Set(StockMarket.allCases.filter {
            StockMarketTradingCalendar.session(for: $0, at: now) == .regular
        })
        let stocks = store.stocks.filter {
            activeMarkets.contains($0.market) && $0.hasConfiguredSymbol && !$0.isArchived
        }
        for stock in stocks {
            guard !Task.isCancelled else { return }
            do {
                _ = try await chartService.fetchChart(for: stock, range: .intraday, forceRefresh: false)
            } catch is CancellationError {
                return
            } catch {
                DiagnosticLogger.logError(.stockQuote, operation: "盘中分时图 \(stock.symbol)", error: error)
            }
        }
    }

    private func stopForegroundPolling() {
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
            guard !Task.isCancelled else {
                task.setTaskCompleted(success: false)
                return
            }
            await self.refreshAutomatically()
            task.setTaskCompleted(success: !Task.isCancelled)
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
