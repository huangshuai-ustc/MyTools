import Foundation
import LocalAuthentication
import CryptoKit
import Security

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isAdmin = false
    @Published private(set) var hasPassword: Bool
    @Published private(set) var isAuthenticationPresented = false
    private let defaults = UserDefaults.standard
    private let passwordKey = "admin-password-hash"
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.fjwyz.PersonalToolBox"
    private let keychainAccount = "admin-password-backup"
    private var sessionPassword: String?

    init() { hasPassword = defaults.string(forKey: passwordKey) != nil }

    var isEditSessionReady: Bool {
        isAdmin && !isAuthenticationPresented
    }

    func beginAuthenticationPresentation() {
        isAuthenticationPresented = true
    }

    func endAuthenticationPresentation() {
        isAuthenticationPresented = false
    }

    func setPassword(_ password: String) -> Bool {
        guard password.count >= 8 else { return false }
        savePasswordHash(password)
        sessionPassword = password
        savePasswordToKeychain(password)
        hasPassword = true
        isAdmin = true
        return true
    }

    func unlock(with password: String) -> Bool {
        guard verify(password: password) else { return false }
        sessionPassword = password
        savePasswordToKeychain(password)
        isAdmin = true
        return true
    }

    func unlockWithBiometrics() async -> Bool {
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return false }
        do { let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "验证本人身份后进入编辑模式")
            if success {
                sessionPassword = loadPasswordFromKeychain()
                isAdmin = true
            }
            return success
        } catch { return false }
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
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }

    func lock() {
        isAdmin = false
        isAuthenticationPresented = false
        sessionPassword = nil
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
        guard status == errSecItemNotFound else { return }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func loadPasswordFromKeychain() -> String? {
        var query = keychainLookupQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
