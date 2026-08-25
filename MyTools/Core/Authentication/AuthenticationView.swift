import SwiftUI

struct AuthenticationView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var error = ""
    @State private var didAttemptBiometrics = false
    let onAuthenticated: (() -> Void)?

    init(onAuthenticated: (() -> Void)? = nil) {
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        IdentityVerificationForm(
            mode: auth.hasPassword ? .verify : .setPassword,
            password: $password,
            confirmation: $confirm,
            error: error,
            passwordAction: auth.hasPassword ? requestUnlock : requestSetPassword,
            biometricAction: {
                Task {
                    if await auth.unlockWithBiometrics() {
                        finishAuthentication()
                    } else {
                        error = "面容或指纹验证未通过，请输入管理员密码。"
                    }
                }
            },
            onCancel: { dismiss() }
        )
        .task { await attemptBiometricUnlock() }
    }

    private func attemptBiometricUnlock() async {
        guard auth.hasPassword, !auth.isAdmin, !didAttemptBiometrics else { return }
        didAttemptBiometrics = true
        if await auth.unlockWithBiometrics() {
            finishAuthentication()
        } else {
            error = "面容或指纹验证未通过，请输入管理员密码。"
        }
    }

    private func requestSetPassword() {
        commitPendingTextInput {
            guard password == confirm, auth.setPassword(password) else {
                error = "密码至少 8 位且两次输入需一致"
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
        // 这样不会因认证状态变化而重建空表单；后台锁定由管理员会话策略统一处理。
        dismiss()
        guard let onAuthenticated else { return }
        Task { @MainActor in
            await Task.yield()
            onAuthenticated()
        }
    }
}

struct IdentityVerificationForm: View {
    enum Mode: Equatable {
        case setPassword
        case verify
    }

    private enum Field: Hashable {
        case password
        case confirmation
    }

    let mode: Mode
    @Binding var password: String
    @Binding var confirmation: String
    let error: String
    let isVerifying: Bool
    let passwordAction: () -> Void
    let biometricAction: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: Field?

    init(
        mode: Mode,
        password: Binding<String>,
        confirmation: Binding<String> = .constant(""),
        error: String,
        isVerifying: Bool = false,
        passwordAction: @escaping () -> Void,
        biometricAction: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        _password = password
        _confirmation = confirmation
        self.error = error
        self.isVerifying = isVerifying
        self.passwordAction = passwordAction
        self.biometricAction = biometricAction
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            verificationContent
                .appNavigationTitle("验证身份")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                }
        }
    }

    @ViewBuilder
    private var verificationContent: some View {
#if os(macOS)
        macOSVerificationContent
#else
        Form {
            nativeFormSections
        }
#endif
    }

    @ViewBuilder
    private var nativeFormSections: some View {
                Section {
                    SecureField(
                        mode == .setPassword ? "至少 8 位" : "管理员密码",
                        text: $password
                    )
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        if mode == .setPassword {
                            focusedField = .confirmation
                        } else {
                            passwordAction()
                        }
                    }

                    if mode == .setPassword {
                        SecureField("再次输入", text: $confirmation)
                            .focused($focusedField, equals: .confirmation)
                            .onSubmit(passwordAction)
                    }

                    Button(mode == .setPassword ? "保存并进入" : "验证", action: passwordAction)
                        .disabled(isVerifying)
                } header: {
                    Text(mode == .setPassword ? "设置管理员密码" : "密码验证")
                } footer: {
                    Text(
                        mode == .setPassword
                            ? "管理员密码也会作为导出和导入备份的默认密码。"
                            : "请输入管理员密码，或使用 Face ID / Touch ID 验证。"
                    )
                }

                if mode == .verify {
                    Section {
                        Button(action: biometricAction) {
                            if isVerifying {
                                HStack {
                                    ProgressView()
                                    Text("正在验证")
                                }
                            } else {
                                Label("重新使用 Face ID / Touch ID", systemImage: "faceid")
                            }
                        }
                        .disabled(isVerifying)
                    }
                }

                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
    }

#if os(macOS)
    private var macOSVerificationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(mode == .setPassword ? "设置管理员密码" : "密码验证")
                    .appFont(.title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 14) {
                    SecureField(
                        mode == .setPassword ? "至少 8 位" : "管理员密码",
                        text: $password
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        if mode == .setPassword {
                            focusedField = .confirmation
                        } else {
                            passwordAction()
                        }
                    }

                    if mode == .setPassword {
                        SecureField("再次输入", text: $confirmation)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .focused($focusedField, equals: .confirmation)
                            .onSubmit(passwordAction)
                    }

                    Button(
                        mode == .setPassword ? "保存并进入" : "验证",
                        action: passwordAction
                    )
                    .controlSize(.large)
                    .disabled(isVerifying)
                }

                Text(
                    mode == .setPassword
                        ? "管理员密码也会作为导出和导入备份的默认密码。"
                        : "请输入管理员密码，或使用 Face ID / Touch ID 验证。"
                )
                .appFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if mode == .verify {
                    Divider()
                    Button(action: biometricAction) {
                        if isVerifying {
                            HStack {
                                ProgressView()
                                Text("正在验证")
                            }
                        } else {
                            Label("重新使用 Face ID / Touch ID", systemImage: "faceid")
                        }
                    }
                    .controlSize(.large)
                    .disabled(isVerifying)
                }

                if !error.isEmpty {
                    Text(error)
                        .appFont(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
#endif
}
