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
final class StockRefreshCoordinator {
    static let shared = StockRefreshCoordinator()

#if os(iOS)
    static let taskIdentifier = AppMetadata.stockRefreshTaskIdentifier
#endif

    private weak var store: StockStore?
    private weak var moduleSettings: ToolModuleSettings?
    private var foregroundTask: Task<Void, Never>?
    private var lastClosingRefreshSessionEndByMarket: [StockMarket: Date] = [:]
    private var lastClosingChartRefreshSessionEndByMarket: [StockMarket: Date] = [:]
    private var lastClosingRefreshAttemptAtByMarket: [StockMarket: Date] = [:]
    private var lastClosingChartRefreshAttemptAtByMarket: [StockMarket: Date] = [:]
    private var isAutomaticRefreshRunning = false
    private var currentScenePhase: ScenePhase = .inactive
    private var isStocksPageVisible = false
    private let chartService: any StockChartServing

    private init(chartService: any StockChartServing = StockChartService.shared) {
        self.chartService = chartService
    }

    func attach(store: StockStore, moduleSettings: ToolModuleSettings? = nil) {
        self.store = store
        if let moduleSettings {
            self.moduleSettings = moduleSettings
        }
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

    private var isStockModuleVisible: Bool {
        moduleSettings?.isVisible(.myStocks) ?? true
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
        defer { isAutomaticRefreshRunning = false }

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
            guard session != .regular,
                  store.stocks.contains(where: {
                      $0.market == market
                          && $0.hasConfiguredSymbol
                          && !$0.isArchived
                  }),
                  let sessionEnd = StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
                      for: market,
                      at: now
                  ),
                  lastClosingChartRefreshSessionEndByMarket[market] != sessionEnd else {
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
        DiagnosticLogger.shared.log(
            .stockQuote,
            "检测到收市完整行情补刷标的：\(stocks.count)"
        )
        for market in StockMarket.displayOrder where sessions[market] != nil {
            var didRefreshAllStocks = true
            for stock in stocks where stock.market == market {
                guard !Task.isCancelled else { return }
                do {
                    _ = try await chartService.refreshAfterFinalSession(for: stock)
                } catch is CancellationError {
                    return
                } catch {
                    didRefreshAllStocks = false
                    DiagnosticLogger.logError(
                        .stockQuote,
                        operation: "收市完整行情补刷 \(stock.symbol)",
                        error: error
                    )
                }
            }
            if didRefreshAllStocks,
               let sessionEnd = sessions[market] {
                lastClosingChartRefreshSessionEndByMarket[market] = sessionEnd
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
