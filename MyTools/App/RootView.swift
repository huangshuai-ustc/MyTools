import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ToolboxView()
                .tabItem { Label("工具箱", systemImage: "square.grid.2x2") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
#if os(iOS)
        .tint(.blue)
        .toolbarBackground(.visible, for: .tabBar)
#endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, auth.isAdmin { auth.lock() }
        }
        .onChange(of: auth.isAdmin) { _, isAdmin in
            if isAdmin { store.loadEncryptedVaultAfterAuthentication() }
        }
    }
}
