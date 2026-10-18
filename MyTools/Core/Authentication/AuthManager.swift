import Foundation
import LocalAuthentication

@MainActor
final class AuthManager: ObservableObject {
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
}

/// Editors show sensitive values in plain text, so opening one while the
/// content is locked must verify the owner first (AUDIT-007).
enum SensitiveEditAccess {
    @MainActor
    static func isGranted(isUnlocked: Bool, verify: () async -> Bool) async -> Bool {
        if isUnlocked { return true }
        return await verify()
    }
}
