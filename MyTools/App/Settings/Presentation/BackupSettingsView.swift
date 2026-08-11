import SwiftUI

enum BackupPasswordMode: Int, Identifiable {
    case export
    case restore

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .export: return "设置备份密码"
        case .restore: return "输入备份密码"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .export: return "继续导出"
        case .restore: return "解密并导入"
        }
    }
}

struct AdminPasswordChangeView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("至少 8 位", text: $password)
                    SecureField("再次输入", text: $confirmation)
                } header: {
                    Text("新管理员密码")
                } footer: {
                    Text("修改后原管理员密码立即失效，导出和导入备份的默认密码也会同步更新。")
                }

                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("修改管理员密码")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                }
            }
        }
    }

    private func save() {
        commitPendingTextInput {
            guard auth.changePassword(password, confirmation: confirmation) else {
                error = "密码至少 8 位且两次输入需一致"
                return
            }
            dismiss()
        }
    }
}

struct BackupPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    let mode: BackupPasswordMode
    let defaultPassword: String?
    let onSubmit: (String) async -> String?
    @State private var password: String
    @State private var confirmation: String
    @State private var error = ""
    @State private var isSubmitting = false
    @FocusState private var inputFocused: Bool

    init(
        mode: BackupPasswordMode,
        defaultPassword: String?,
        onSubmit: @escaping (String) async -> String?
    ) {
        self.mode = mode
        self.defaultPassword = defaultPassword
        self.onSubmit = onSubmit
        _password = State(initialValue: defaultPassword ?? "")
        _confirmation = State(initialValue: defaultPassword ?? "")
    }

    private var canSubmit: Bool {
        let effectivePassword = password.isEmpty ? defaultPassword : password
        guard let effectivePassword, effectivePassword.count >= 8 else { return false }
        return mode == .restore || password.isEmpty || password == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        SecureField("备份密码", text: $password)
                            .focused($inputFocused)
                        Button {
                            password = ""
                            confirmation = ""
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .disabled(password.isEmpty && confirmation.isEmpty)
                        .accessibilityLabel("清除备份密码")
                    }
                    if mode == .export {
                        SecureField("再次输入", text: $confirmation)
                            .focused($inputFocused)
                    }
                }

                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(mode.title)
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: requestSubmit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(mode.confirmationTitle)
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func requestSubmit() {
        commitPendingTextInput {
            guard !isSubmitting else { return }
            isSubmitting = true
            let submittedPassword = password
            Task { @MainActor in
                if let message = await onSubmit(submittedPassword) {
                    error = message
                    isSubmitting = false
                } else {
                    dismiss()
                }
            }
        }
    }
}
