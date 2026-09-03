import SwiftUI

struct SensitiveAccessView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    @State private var didAttemptBiometrics = false
    @State private var isVerifying = false
    let onVerified: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await verifyBiometrics() }
                    } label: {
                        if isVerifying {
                            HStack {
                                ProgressView()
                                Text("正在验证")
                            }
                        } else {
                            Label("使用 Face ID / Touch ID 或设备密码验证", systemImage: "faceid")
                        }
                    }
                    .disabled(isVerifying)
                } footer: {
                    Text("验证本人身份后查看敏感信息，不会改变任何会话状态。")
                }
            }
            .appNavigationTitle("验证身份")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            guard !didAttemptBiometrics else { return }
            didAttemptBiometrics = true
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
            error = "身份验证未通过，请重试。"
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
