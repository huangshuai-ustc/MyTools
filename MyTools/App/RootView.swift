import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
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

            if !store.isInitialDataLoaded {
                InitialDataLoadingView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.isInitialDataLoaded)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if auth.isAdmin { auth.lock() }
                Task { await store.flushPendingPersistence() }
            }
        }
        .onChange(of: auth.isAdmin) { _, isAdmin in
            if isAdmin { store.loadEncryptedVaultAfterAuthentication() }
        }
    }
}

private struct InitialDataLoadingView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在载入本地数据")
    }
}
