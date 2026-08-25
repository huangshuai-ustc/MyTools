import Foundation
import LocalAuthentication
import CryptoKit
import Security

enum AdminSessionDuration: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case custom
    case permanent

    var id: Self { self }

    var title: String {
        switch self {
        case .fifteenMinutes: return "15 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .twoHours: return "2 小时"
        case .fourHours: return "4 小时"
        case .custom: return "自定义"
        case .permanent: return "永久"
        }
    }

    var presetInterval: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .custom, .permanent: return nil
        }
    }
}

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isAdmin = false
    @Published private(set) var hasPassword: Bool
    @Published private(set) var isAuthenticationPresented = false
    @Published private(set) var sessionDuration: AdminSessionDuration
    @Published private(set) var customSessionDurationMinutes: Int
    @Published private(set) var lockOnBackground: Bool
    private let defaults: UserDefaults
    private enum LegacyDefaultsKey {
        static let sessionPolicy = "admin-session-policy"
        static let sessionDuration = "admin-session-duration"
    }
    private let passwordKey = "admin-password-hash"
    private let sessionDurationKey = "admin-session-duration-option"
    private let customSessionDurationKey = "admin-session-duration-custom-minutes"
    private let lockOnBackgroundKey = "admin-session-lock-on-background"
    private let keychainService = AppMetadata.bundleIdentifier
    private let keychainAccount = "admin-password-backup"
    private var sessionPassword: String?
    private var sessionExpiresAt: Date?
    private var expirationTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasPassword = defaults.string(forKey: passwordKey) != nil
        let storedCustomMinutes = defaults.integer(forKey: customSessionDurationKey)
        customSessionDurationMinutes = storedCustomMinutes == 0
            ? 30
            : min(max(storedCustomMinutes, 1), 7 * 24 * 60)
        let hasLegacySessionSettings = defaults.string(
            forKey: LegacyDefaultsKey.sessionPolicy
        ) != nil || defaults.object(forKey: LegacyDefaultsKey.sessionDuration) != nil
        let resolvedSessionDuration: AdminSessionDuration
        let shouldPersistSessionDuration: Bool
        if let rawValue = defaults.string(forKey: sessionDurationKey),
           let duration = AdminSessionDuration(rawValue: rawValue) {
            resolvedSessionDuration = duration
            shouldPersistSessionDuration = false
        } else {
            resolvedSessionDuration = Self.migratedDuration(from: defaults)
            shouldPersistSessionDuration = hasLegacySessionSettings
        }
        let resolvedLockOnBackground: Bool
        let shouldPersistLockOnBackground: Bool
        if defaults.object(forKey: lockOnBackgroundKey) != nil {
            resolvedLockOnBackground = defaults.bool(forKey: lockOnBackgroundKey)
            shouldPersistLockOnBackground = false
        } else {
            resolvedLockOnBackground = Self.migratedLockOnBackground(from: defaults)
            shouldPersistLockOnBackground = hasLegacySessionSettings
        }
        sessionDuration = resolvedSessionDuration
        lockOnBackground = resolvedLockOnBackground
        if shouldPersistSessionDuration {
            defaults.set(resolvedSessionDuration.rawValue, forKey: sessionDurationKey)
        }
        if shouldPersistLockOnBackground {
            defaults.set(resolvedLockOnBackground, forKey: lockOnBackgroundKey)
        }
        if hasLegacySessionSettings {
            defaults.removeObject(forKey: LegacyDefaultsKey.sessionPolicy)
            defaults.removeObject(forKey: LegacyDefaultsKey.sessionDuration)
        }
    }

    var isEditSessionReady: Bool {
        isAdmin && !isAuthenticationPresented
    }

    func beginAuthenticationPresentation() {
        isAuthenticationPresented = true
    }

    func endAuthenticationPresentation() {
        isAuthenticationPresented = false
    }

    func updateSessionDuration(_ duration: AdminSessionDuration) {
        sessionDuration = duration
        defaults.set(duration.rawValue, forKey: sessionDurationKey)
        guard isAdmin else { return }
        configureActiveSession()
    }

    func updateCustomSessionDurationMinutes(_ minutes: Int) {
        let clamped = min(max(minutes, 1), 7 * 24 * 60)
        customSessionDurationMinutes = clamped
        defaults.set(clamped, forKey: customSessionDurationKey)
        guard isAdmin, sessionDuration == .custom else { return }
        configureActiveSession()
    }

    func updateLockOnBackground(_ lockOnBackground: Bool) {
        self.lockOnBackground = lockOnBackground
        defaults.set(lockOnBackground, forKey: lockOnBackgroundKey)
    }

    func setPassword(_ password: String) -> Bool {
        guard password.count >= 8 else { return false }
        savePasswordHash(password)
        sessionPassword = password
        savePasswordToKeychain(password)
        hasPassword = true
        beginAdminSession()
        return true
    }

    func unlock(with password: String) -> Bool {
        guard verify(password: password) else { return false }
        sessionPassword = password
        savePasswordToKeychain(password)
        beginAdminSession()
        return true
    }

    func unlockWithBiometrics() async -> Bool {
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if let error {
                DiagnosticLogger.logError(.authentication, operation: "管理员生物识别不可用", error: error)
            }
            return false
        }
        do { let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "验证本人身份后进入编辑模式")
            if success {
                sessionPassword = loadPasswordFromKeychain()
                beginAdminSession()
            }
            return success
        } catch {
            DiagnosticLogger.logError(.authentication, operation: "管理员生物识别失败", error: error)
            return false
        }
    }

    func verify(password: String) -> Bool {
        let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        return hash == defaults.string(forKey: passwordKey)
    }

    func changePassword(_ password: String, confirmation: String) -> Bool {
        guard isAdmin, password.count >= 8, password == confirmation else { return false }
        savePasswordHash(password)
        sessionPassword = password
        savePasswordToKeychain(password)
        hasPassword = true
        return true
    }

    var defaultBackupPassword: String? {
        guard isAdmin else { return nil }
        return sessionPassword ?? loadPasswordFromKeychain()
    }

    func rememberPasswordForBackup(_ password: String) {
        guard isAdmin, verify(password: password) else { return }
        sessionPassword = password
        savePasswordToKeychain(password)
    }

    func verifyWithBiometrics(reason: String = "验证本人身份后查看敏感信息") async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error {
                DiagnosticLogger.logError(.authentication, operation: "敏感信息身份验证不可用", error: error)
            }
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            DiagnosticLogger.logError(.authentication, operation: "敏感信息身份验证失败", error: error)
            return false
        }
    }

    /// Called when the app enters the background. The default policy keeps the
    /// existing automatic lock behavior; persistent and timed sessions remain
    /// active until their explicit policy says otherwise.
    func applicationDidEnterBackground() {
        expireIfNeeded()
        guard isAdmin, lockOnBackground else { return }
        lock()
    }

    /// Re-checks a timed session after the app becomes active. This is needed
    /// because suspended apps do not guarantee that the expiration task runs
    /// at the exact deadline.
    func applicationDidBecomeActive() {
        expireIfNeeded()
    }

    func lock() {
        expirationTask?.cancel()
        expirationTask = nil
        sessionExpiresAt = nil
        isAdmin = false
        isAuthenticationPresented = false
        sessionPassword = nil
    }

    private func beginAdminSession() {
        isAdmin = true
        configureActiveSession()
    }

    private func configureActiveSession() {
        expirationTask?.cancel()
        expirationTask = nil
        sessionExpiresAt = nil

        guard isAdmin,
              let interval = configuredSessionInterval else { return }
        let expiration = Date().addingTimeInterval(interval)
        sessionExpiresAt = expiration
        let nanoseconds = UInt64(interval * 1_000_000_000)
        expirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.expireIfNeeded()
        }
    }

    private func expireIfNeeded() {
        guard isAdmin,
              let sessionExpiresAt,
              Date() >= sessionExpiresAt else { return }
        lock()
    }

    private var configuredSessionInterval: TimeInterval? {
        if let presetInterval = sessionDuration.presetInterval {
            return presetInterval
        }
        guard sessionDuration == .custom else { return nil }
        return TimeInterval(customSessionDurationMinutes * 60)
    }

    private static func migratedDuration(from defaults: UserDefaults) -> AdminSessionDuration {
        switch defaults.string(forKey: "admin-session-policy") {
        case "persistent", "standard", nil:
            return .permanent
        case "timed":
            switch defaults.integer(forKey: "admin-session-duration") {
            case 900: return .fifteenMinutes
            case 1800: return .thirtyMinutes
            case 3600: return .oneHour
            case 7200: return .twoHours
            case 14400: return .fourHours
            default: return .custom
            }
        default:
            return .permanent
        }
    }

    private static func migratedLockOnBackground(from defaults: UserDefaults) -> Bool {
        switch defaults.string(forKey: "admin-session-policy") {
        case "persistent", "timed": return false
        case "standard", nil: return true
        default: return true
        }
    }

    private func savePasswordHash(_ password: String) {
        defaults.set(
            SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined(),
            forKey: passwordKey
        )
    }

    private var keychainLookupQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private func savePasswordToKeychain(_ password: String) {
        let data = Data(password.utf8)
        let query = keychainLookupQuery
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            DiagnosticLogger.shared.log(
                .authentication,
                "管理员密码未能更新系统安全存储 status=\(status)",
                level: .warning
            )
            return
        }
        guard status == errSecItemNotFound else { return }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            DiagnosticLogger.shared.log(
                .authentication,
                "管理员密码未能写入系统安全存储 status=\(addStatus)",
                level: .warning
            )
            return
        }
    }

    private func loadPasswordFromKeychain() -> String? {
        var query = keychainLookupQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            if status != errSecItemNotFound {
                DiagnosticLogger.shared.log(
                    .authentication,
                    "无法读取管理员备份密码 status=\(status)",
                    level: .warning
                )
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
