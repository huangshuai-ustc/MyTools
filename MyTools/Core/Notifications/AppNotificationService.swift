import Foundation
import OSLog
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class AppNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationService()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let logger = Logger(
        subsystem: AppMetadata.bundleIdentifier,
        category: "Notifications"
    )
    private let statePrefix = "price-alert-state-"

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
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self?.authorizationStatus = status
            }
        }
    }

    func requestAuthorization() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
                if let error {
                    self?.logger.error("请求通知权限失败：\(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
        refreshAuthorizationStatus()
        return granted
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
        center.add(request) { [weak self] error in
            if let error {
                self?.logger.error("添加本地通知失败：\(error.localizedDescription, privacy: .public)")
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

    func clearAllStates() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(statePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
