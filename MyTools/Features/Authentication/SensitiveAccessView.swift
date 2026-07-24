import SwiftUI

struct SensitiveAccessView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error = ""
    @State private var didAttemptBiometrics = false
    @State private var isVerifying = false
    @FocusState private var passwordFocused: Bool
    let onVerified: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("本次验证只显示当前页面的敏感信息，不会进入管理员编辑模式。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("密码验证") {
                    SecureField("管理员密码", text: $password)
                        .focused($passwordFocused)
                    Button("验证并查看", action: verifyPassword)
                        .disabled(isVerifying)
                }
                Section {
                    Button { Task { await verifyBiometrics() } } label: {
                        if isVerifying {
                            HStack {
                                ProgressView()
                                Text("正在验证")
                            }
                        } else {
                            Label("使用 Face ID / Touch ID / 设备密码", systemImage: "faceid")
                        }
                    }
                    .disabled(isVerifying)
                }
                if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("查看敏感信息")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                guard !didAttemptBiometrics else { return }
                didAttemptBiometrics = true
                // 等待验证页完成呈现，避免系统认证与 sheet 转场同时发生而偶发无响应。
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await verifyBiometrics()
            }
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
            passwordFocused = true
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
