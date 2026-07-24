import Foundation
import LocalAuthentication
import CryptoKit

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isAdmin = false
    @Published private(set) var hasPassword: Bool
    private let defaults = UserDefaults.standard
    private let passwordKey = "admin-password-hash"

    init() { hasPassword = defaults.string(forKey: passwordKey) != nil }

    func setPassword(_ password: String) -> Bool {
        guard password.count >= 6 else { return false }
        defaults.set(SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined(), forKey: passwordKey)
        hasPassword = true; isAdmin = true; return true
    }

    func unlock(with password: String) -> Bool {
        let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        guard hash == defaults.string(forKey: passwordKey) else { return false }
        isAdmin = true; return true
    }

    func unlockWithBiometrics() async -> Bool {
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return false }
        do { let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "验证本人身份后进入编辑模式")
            if success { isAdmin = true }; return success
        } catch { return false }
    }

    func verify(password: String) -> Bool {
        let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        return hash == defaults.string(forKey: passwordKey)
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

    func lock() { isAdmin = false }
}
