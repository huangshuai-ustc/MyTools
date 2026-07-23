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
    @FocusState private var focusedField: Field?
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
                                    dismiss()
                                } else {
                                    error = "Face ID、Touch ID 或设备密码验证失败"
                                }
                            }
                        } label: {
                            Label("使用 Face ID / Touch ID / 设备密码", systemImage: "faceid")
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
        }
    }

    private func requestSetPassword() {
        commitPendingTextInput {
            guard password == confirm, auth.setPassword(password) else {
                error = "密码至少 6 位且两次输入需一致"
                return
            }
            dismiss()
        }
    }

    private func requestUnlock() {
        commitPendingTextInput {
            if auth.unlock(with: password) {
                dismiss()
            } else {
                error = "密码错误"
            }
        }
    }
}
