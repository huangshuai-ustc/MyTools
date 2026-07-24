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
    let title: String
    let value: String
    let concealedValue: String
    let isRevealed: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(displayValue)
                    .fontDesign(isRevealed ? .monospaced : .default)
                    .multilineTextAlignment(.trailing)
                    .copyableText(isRevealed ? value : nil)
            }
        }
    }

    private var displayValue: String {
        guard !value.isEmpty else { return "未填写" }
        return isRevealed ? value : concealedValue
    }
}

struct CopyableValueRow: View {
    let title: String
    let value: String
    var emptyValue = "未填写"

    var body: some View {
        LabeledContent(title) {
            Text(value.isEmpty ? emptyValue : value)
                .multilineTextAlignment(.trailing)
                .copyableText(value.isEmpty ? nil : value)
        }
    }
}

private struct CopyableTextModifier: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value, !value.isEmpty {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

extension View {
    func copyableText(_ value: String?) -> some View {
        modifier(CopyableTextModifier(value: value))
    }
}
