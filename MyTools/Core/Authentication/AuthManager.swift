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
