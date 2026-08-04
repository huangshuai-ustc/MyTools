import SwiftUI

#if os(iOS)
import BackgroundTasks
import UIKit
#endif

@MainActor
final class StockRefreshCoordinator {
    static let shared = StockRefreshCoordinator()

#if os(iOS)
    static let taskIdentifier = "com.fjwyz.PersonalToolBox.stock-refresh"
#endif

    private weak var store: AppStore?
    private weak var moduleSettings: ToolModuleSettings?
    private var foregroundTask: Task<Void, Never>?
    private var lastAutomaticCheckAt: Date?
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
              store.isInitialDataLoaded else { return false }
        return isStocksPageVisible
            || store.stockPriceAlerts.contains(where: { $0.isEnabled })
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
            lastAutomaticCheckAt = Date()
        }
        foregroundTask = Task { @MainActor [weak self] in
            DiagnosticLogger.shared.log(.lifecycle, "股票前台轮询启动")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { continue }
                guard self.shouldPollInForeground else {
                    self.stopForegroundPolling()
                    return
                }
                await self.refreshAutomatically()
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

        let endedMarkets = Set(
            StockMarket.allCases.filter {
                StockMarketTradingCalendar.sessionEnded(
                    for: $0,
                    between: previousCheck,
                    and: now
                )
            }
        )
        await store.refreshStockQuotes(forcedMarkets: endedMarkets)
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
              store?.stocks.contains(where: { $0.hasConfiguredSymbol }) == true else { return }
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
