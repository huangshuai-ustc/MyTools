#if MYTOOLS_FEATURE_SPORTS_LOTTERY
import SwiftUI

#if os(iOS)
import BackgroundTasks
import UIKit
#endif

@MainActor
final class SportsLotteryRefreshCoordinator {
    static let shared = SportsLotteryRefreshCoordinator()

#if os(iOS)
    static let taskIdentifier = AppMetadata.sportsLotteryRefreshTaskIdentifier
#endif

    private var foregroundTask: Task<Void, Never>?
    private var currentScenePhase: ScenePhase = .inactive
    /// 首页隐藏体彩后，前台定时检查与系统后台刷新都停止，避免继续联网。
    private(set) var isModuleVisible = true
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func updateModuleVisibility(_ isVisible: Bool) {
        isModuleVisible = isVisible
        if isVisible {
            if currentScenePhase == .active { startForegroundChecks() }
        } else {
            stopForegroundChecks()
#if os(iOS)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
#endif
        }
    }

    func update(scenePhase: ScenePhase) {
        currentScenePhase = scenePhase
        switch scenePhase {
        case .active:
            startForegroundChecks()
#if os(iOS)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
#endif
        case .background:
            stopForegroundChecks()
            scheduleBackgroundRefresh()
        case .inactive:
            stopForegroundChecks()
        @unknown default:
            break
        }
    }

    private func startForegroundChecks() {
        guard isModuleVisible, foregroundTask == nil else { return }
        foregroundTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshIfDue()
            while !Task.isCancelled {
                let next = SportsLotteryService.nextAutomaticRefreshDate(after: Date())
                let seconds = max(next.timeIntervalSinceNow, 60)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self.refreshIfDue()
            }
        }
    }

    private func stopForegroundChecks() {
        foregroundTask?.cancel()
        foregroundTask = nil
    }

    private func refreshIfDue() async {
        guard isModuleVisible else { return }
        let leagues = SportsLotteryLeaguePreferences.load(from: defaults)
        guard !leagues.isEmpty else { return }
        do {
            _ = try await SportsLotteryService.shared.fetchSnapshot(leagues: leagues, forceRefresh: false)
        } catch {
            DiagnosticLogger.logError(.lifecycle, operation: "体彩自动刷新失败", error: error)
        }
    }

    private func scheduleBackgroundRefresh() {
#if os(iOS)
        guard isModuleVisible else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = SportsLotteryService.nextAutomaticRefreshDate(after: Date())
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            DiagnosticLogger.logError(.lifecycle, operation: "预约体彩后台刷新失败", error: error)
        }
#endif
    }

#if os(iOS)
    func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor [weak self] in
            await self?.refreshIfDue()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: .main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            SportsLotteryRefreshCoordinator.shared.handleBackgroundRefresh(refreshTask)
        }
    }
#endif
}

#endif
