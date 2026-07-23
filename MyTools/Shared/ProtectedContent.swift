import SwiftUI

struct AdminEditAccessButton: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var showingAuthentication = false
    var onAccessGranted: (() -> Void)? = nil

    var body: some View {
        Button {
            if auth.isAdmin {
                auth.lock()
            } else {
                showingAuthentication = true
            }
        } label: {
            Image(systemName: auth.isAdmin ? "pencil.circle.fill" : "pencil.circle")
                .foregroundStyle(auth.isAdmin ? Color.green : Color.primary)
        }
        .accessibilityLabel(auth.isAdmin ? "退出编辑模式" : "进入编辑模式")
        .help(auth.isAdmin ? "退出编辑模式" : "验证身份后编辑")
        .sheet(isPresented: $showingAuthentication) {
            AuthenticationView().iOSLargeSheet()
        }
        .onChange(of: auth.isAdmin) { wasAdmin, isAdmin in
            if !wasAdmin, isAdmin { onAccessGranted?() }
        }
    }
}

struct ProtectedValueRow: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var showingAuthentication = false
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(displayValue)
                    .fontDesign(auth.isAdmin ? .monospaced : .default)
                    .textSelection(.enabled)
                Button {
                    if auth.isAdmin {
                        auth.lock()
                    } else {
                        showingAuthentication = true
                    }
                } label: {
                    Image(systemName: auth.isAdmin ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(auth.isAdmin ? "隐藏\(title)" : "验证身份后查看\(title)")
            }
        }
        .sheet(isPresented: $showingAuthentication) {
            AuthenticationView().iOSLargeSheet()
        }
    }

    private var displayValue: String {
        guard !value.isEmpty else { return "未填写" }
        return auth.isAdmin ? value : "••••••"
    }
}
