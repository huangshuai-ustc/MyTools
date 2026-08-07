import SwiftUI

#if os(iOS)
import BackgroundTasks
import UIKit
#endif

@MainActor
final class StockRefreshCoordinator {
    static let shared = StockRefreshCoordinator()

#if os(iOS)
    static let taskIdentifier = AppMetadata.stockRefreshTaskIdentifier
#endif

    private weak var store: AppStore?
    private weak var moduleSettings: ToolModuleSettings?
    private var foregroundTask: Task<Void, Never>?
    private var lastAutomaticCheckAt: Date?
    private var lastClosingRefreshAttemptAtByMarket: [StockMarket: Date] = [:]
    private var currentScenePhase: ScenePhase = .inactive
    private var isStocksPageVisible = false

    private init() {}

    func attach(store: AppStore, moduleSettings: ToolModuleSettings? = nil) {
        self.store = store
        if let moduleSettings {
            self.moduleSettings = moduleSettings
            store.attach(moduleSettings: moduleSettings)
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
              store.isInitialDataLoaded,
              hasRefreshableStocks(in: store) else { return false }
        return isStocksPageVisible
            || hasEnabledRefreshableAlert(in: store)
    }

    private func hasRefreshableStocks(in store: AppStore) -> Bool {
        store.stocks.contains(where: \.hasConfiguredSymbol)
    }

    private func hasEnabledRefreshableAlert(in store: AppStore) -> Bool {
        let refreshableStockIDs = Set(
            store.stocks.lazy
                .filter(\.hasConfiguredSymbol)
                .map(\.id)
        )
        return store.stockPriceAlerts.contains {
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
        if lastAutomaticCheckAt == nil {
            // Include the previous day so reopening the app after a market
            // close can perform the one required closing snapshot.
            lastAutomaticCheckAt = Date().addingTimeInterval(-24 * 60 * 60)
        }
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
              store.isInitialDataLoaded,
              !store.isRefreshingQuotes else { return }

        let now = Date()
        let previousCheck = lastAutomaticCheckAt ?? now.addingTimeInterval(-60)
        lastAutomaticCheckAt = now

        let endedMarkets = closingMarketsNeedingRefresh(
            store: store,
            previousCheck: previousCheck,
            now: now
        )
        if !endedMarkets.isEmpty {
            DiagnosticLogger.shared.log(
                .stockQuote,
                "检测到收盘补刷市场：\(endedMarkets.map { $0.rawValue }.sorted().joined(separator: ","))"
            )
        }
        await store.refreshStockQuotes(
            forcedMarkets: endedMarkets,
            allowClosedMissingData: false
        )
    }

    private func closingMarketsNeedingRefresh(
        store: AppStore,
        previousCheck: Date,
        now: Date
    ) -> Set<StockMarket> {
        var result = Set<StockMarket>()
        for market in StockMarket.allCases {
            guard store.stocks.contains(where: { $0.market == market && $0.hasConfiguredSymbol }) else {
                continue
            }

            let latestQuoteAt = store.latestStockQuoteAt(for: market)
            let quoteNeedsClosingRefresh: Bool
            if let latestQuoteAt {
                quoteNeedsClosingRefresh = !StockMarketTradingCalendar.isOpen(market, at: now)
                    && StockMarketTradingCalendar.isOpen(market, at: latestQuoteAt)
                    && StockMarketTradingCalendar.sessionEnded(
                        for: market,
                        between: latestQuoteAt,
                        and: now
                    )
            } else {
                quoteNeedsClosingRefresh = false
            }

            let lastRefresh = store.lastStockRefreshAt(for: market)
            let baseline = max(previousCheck, lastRefresh ?? previousCheck)
            let sessionEndedSinceRefresh = StockMarketTradingCalendar.sessionEnded(
                for: market,
                between: baseline,
                and: now
            )
            guard quoteNeedsClosingRefresh || sessionEndedSinceRefresh else { continue }

            // A provider may still return the same intraday quote after close.
            // Do not turn that into a one-minute retry loop; try again on the
            // next trading day's close instead.
            if let lastAttempt = lastClosingRefreshAttemptAtByMarket[market],
               now.timeIntervalSince(lastAttempt) < 12 * 60 * 60 {
                continue
            }
            lastClosingRefreshAttemptAtByMarket[market] = now
            result.insert(market)
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
            for _ in 0..<20 where !store.isInitialDataLoaded {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else {
                task.setTaskCompleted(success: false)
                return
            }
            await self.refreshAutomatically()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
        }
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
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: StockRefreshCoordinator.taskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                StockRefreshCoordinator.shared.handleBackgroundRefresh(refreshTask)
            }
        }
        return true
    }
}
#endif
