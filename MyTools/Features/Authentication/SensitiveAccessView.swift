import SwiftUI

struct SensitiveAccessView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error = ""
    @State private var didAttemptBiometrics = false
    @State private var isVerifying = false
    let onVerified: () -> Void

    var body: some View {
        IdentityVerificationForm(
            mode: .verify,
            password: $password,
            error: error,
            isVerifying: isVerifying,
            passwordAction: verifyPassword,
            biometricAction: { Task { await verifyBiometrics() } },
            onCancel: { dismiss() }
        )
        .task {
            guard !didAttemptBiometrics else { return }
            didAttemptBiometrics = true
            // 等待验证页完成呈现，避免系统认证与 sheet 转场同时发生而偶发无响应。
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await verifyBiometrics()
        }
    }

    @MainActor
    private func verifyBiometrics() async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        if await auth.verifyWithBiometrics() {
            finish()
        } else {
            error = "系统身份验证未通过，请输入管理员密码。"
        }
    }

    private func verifyPassword() {
        commitPendingTextInput {
            if auth.verify(password: password) {
                finish()
            } else {
                error = "密码错误"
            }
        }
    }

    @MainActor
    private func finish() {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            onVerified()
        }
    }
}
