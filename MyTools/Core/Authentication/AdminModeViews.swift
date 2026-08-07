import SwiftUI

struct AdminEditAccessButton: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var showingAuthentication = false

    var body: some View {
        Button {
            if auth.isAdmin {
                auth.lock()
            } else {
                auth.beginAuthenticationPresentation()
                showingAuthentication = true
            }
        } label: {
            AdminModeIcon(isActive: auth.isAdmin)
        }
        .accessibilityLabel(auth.isAdmin ? "退出编辑模式" : "进入编辑模式")
        .help(auth.isAdmin ? "退出编辑模式" : "验证身份后编辑")
        .sheet(isPresented: $showingAuthentication, onDismiss: {
            auth.endAuthenticationPresentation()
        }) {
            AuthenticationView().iOSAuthenticationSheet()
        }
    }
}

struct AdminModeIndicator: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        if auth.isAdmin {
            Button { auth.lock() } label: {
                AdminModeIcon(isActive: true)
            }
            .accessibilityLabel("管理员模式已开启，点按退出")
            .help("退出管理员模式")
        }
    }
}

private struct AdminModeIcon: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: isActive ? "pencil.circle.fill" : "pencil.circle")
            .foregroundStyle(isActive ? Color.green : Color.primary)
    }
}

private struct AdminModeIndicatorModifier: ViewModifier {
    @EnvironmentObject private var auth: AuthManager

    func body(content: Content) -> some View {
        content.toolbar {
            if auth.isAdmin {
                ToolbarItem(placement: .primaryAction) {
                    AdminModeIndicator()
                }
            }
        }
    }
}

extension View {
    func adminModeIndicator() -> some View {
        modifier(AdminModeIndicatorModifier())
    }
}
