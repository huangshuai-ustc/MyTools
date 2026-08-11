import Foundation
import OSLog
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ScheduledLocalNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
}

@MainActor
protocol LocalNotificationScheduling {
    func replaceScheduledNotifications(
        _ notifications: [ScheduledLocalNotification],
        identifierPrefix: String
    )
}

@MainActor
struct DisabledLocalNotificationScheduler: LocalNotificationScheduling {
    func replaceScheduledNotifications(
        _ notifications: [ScheduledLocalNotification],
        identifierPrefix: String
    ) {}
}

@MainActor
final class AppNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate,
    LocalNotificationScheduling {
    static let shared = AppNotificationService()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let logger = Logger(
        subsystem: AppMetadata.bundleIdentifier,
        category: "Notifications"
    )
    private let statePrefix = "price-alert-state-"
    private var scheduledReplacementTasks: [String: Task<Void, Never>] = [:]
    private var scheduledReplacementTokens: [String: UUID] = [:]

    private override init() {
        super.init()
        center.delegate = self
        refreshAuthorizationStatus()
    }

    var statusTitle: String {
        switch authorizationStatus {
        case .notDetermined: return "尚未请求权限"
        case .denied: return "已关闭"
        case .authorized: return "已允许"
        case .provisional: return "临时允许"
#if os(iOS)
        case .ephemeral: return "临时允许"
#endif
        @unknown default: return "未知状态"
        }
    }

    var canNotify: Bool {
        switch authorizationStatus {
        case .authorized, .provisional:
            return true
#if os(iOS)
        case .ephemeral:
            return true
#endif
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func refreshAuthorizationStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            refreshAuthorizationStatus()
            return granted
        } catch {
            logger.error("请求通知权限失败：\(error.localizedDescription, privacy: .public)")
            refreshAuthorizationStatus()
            return false
        }
    }

    func openSystemSettings() {
#if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#elseif os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") else { return }
        NSWorkspace.shared.open(url)
#endif
    }

    func send(title: String, body: String, ruleID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let identifier = "price-alert-\(ruleID.uuidString)-\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await center.add(request)
            } catch {
                logger.error("添加本地通知失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Returns true only when a rule has just entered its matching range.
    func shouldSend(for ruleID: UUID, condition: Bool) -> Bool {
        let key = statePrefix + ruleID.uuidString
        let wasActive = defaults.bool(forKey: key)
        defaults.set(condition, forKey: key)
        return condition && !wasActive
    }

    func clearState(for ruleID: UUID) {
        defaults.removeObject(forKey: statePrefix + ruleID.uuidString)
    }

    func replaceScheduledNotifications(
        _ notifications: [ScheduledLocalNotification],
        identifierPrefix: String
    ) {
        let previousTask = scheduledReplacementTasks[identifierPrefix]
        let token = UUID()
        scheduledReplacementTokens[identifierPrefix] = token
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            let pending = await center.pendingNotificationRequests()
            let staleIdentifiers = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) }
            if !staleIdentifiers.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
            }

            let calendar = Calendar.autoupdatingCurrent
            for notification in notifications where notification.fireDate > Date() {
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = .default
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: notification.fireDate
                )
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: notification.identifier,
                    content: content,
                    trigger: trigger
                )
                do {
                    try await center.add(request)
                } catch {
                    logger.error("添加预约通知失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            if scheduledReplacementTokens[identifierPrefix] == token {
                scheduledReplacementTokens[identifierPrefix] = nil
                scheduledReplacementTasks[identifierPrefix] = nil
            }
        }
        scheduledReplacementTasks[identifierPrefix] = task
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
