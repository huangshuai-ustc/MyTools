import SwiftUI

struct AuthenticationView: View {
    private enum Field: Hashable {
        case password, confirmation
    }

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var error = ""
    @State private var didAttemptBiometrics = false
    @FocusState private var focusedField: Field?
    let onAuthenticated: (() -> Void)?

    init(onAuthenticated: (() -> Void)? = nil) {
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        NavigationStack {
            Form {
                if !auth.hasPassword {
                    Section("设置管理员密码") {
                        SecureField("至少 6 位", text: $password)
                            .focused($focusedField, equals: .password)
                            .onSubmit { focusedField = .confirmation }
                        SecureField("再次输入", text: $confirm)
                            .focused($focusedField, equals: .confirmation)
                        Button("保存并进入", action: requestSetPassword)
                    }
                } else {
                    Section("密码验证") {
                        SecureField("管理员密码", text: $password)
                            .focused($focusedField, equals: .password)
                        Button("验证", action: requestUnlock)
                    }
                    Section {
                        Button {
                            Task {
                                if await auth.unlockWithBiometrics() {
                                    finishAuthentication()
                                } else {
                                    error = "面容或指纹验证未通过，请输入管理员密码。"
                                }
                            }
                        } label: {
                            Label("重新使用 Face ID / Touch ID", systemImage: "faceid")
                        }
                    }
                }
                if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("管理员认证")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await attemptBiometricUnlock() }
        }
    }

    private func attemptBiometricUnlock() async {
        guard auth.hasPassword, !auth.isAdmin, !didAttemptBiometrics else { return }
        didAttemptBiometrics = true
        if await auth.unlockWithBiometrics() {
            finishAuthentication()
        } else {
            error = "面容或指纹验证未通过，请输入管理员密码。"
            focusedField = .password
        }
    }

    private func requestSetPassword() {
        commitPendingTextInput {
            guard password == confirm, auth.setPassword(password) else {
                error = "密码至少 6 位且两次输入需一致"
                return
            }
            finishAuthentication()
        }
    }

    private func requestUnlock() {
        commitPendingTextInput {
            if auth.unlock(with: password) {
                finishAuthentication()
            } else {
                error = "密码错误"
            }
        }
    }

    @MainActor
    private func finishAuthentication() {
        // 先关闭认证页，再由仍持有原 StateObject 草稿的编辑页执行保存。
        // 这样管理员会话在切到后台后失效，也不会因认证状态变化而重建空表单。
        dismiss()
        guard let onAuthenticated else { return }
        Task { @MainActor in
            await Task.yield()
            onAuthenticated()
        }
    }
}
