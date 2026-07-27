import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var copyToast = CopyToastCenter.shared

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
        .overlay {
            GeometryReader { proxy in
                if copyToast.isVisible {
                    Label("已复制到剪贴板", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                        .position(
                            x: proxy.size.width / 2,
                            y: proxy.size.height * 0.8
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .zIndex(10)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
        .alert("本地档案读取失败", isPresented: Binding(
            get: { store.isVaultLoadFailurePresented },
            set: { isPresented in
                if !isPresented { store.dismissVaultLoadFailure() }
            }
        )) {
            Button("知道了", role: .cancel) {
                store.dismissVaultLoadFailure()
            }
        } message: {
            Text("原始档案仍然保留，App 已暂停写入以防止空数据覆盖。请从“我的－设置－调试”导出诊断日志。")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                DiagnosticLogger.shared.markEnteredBackground()
                if auth.isAdmin { auth.lock() }
                Task {
                    await store.flushPendingPersistence()
                    await DiagnosticLogger.shared.flush()
                }
            } else if phase == .active {
                DiagnosticLogger.shared.markBecameActive()
            }
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
