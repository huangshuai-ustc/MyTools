import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var moduleSettings: ToolModuleSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var desktopSelection: RootDestination? = .module(.personalFinance)

    var body: some View {
        ZStack {
            adaptiveMainInterface

            if !store.isInitialDataLoaded {
                InitialDataLoadingView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.isInitialDataLoaded)
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
        .alert("本地档案保存失败", isPresented: Binding(
            get: { store.persistenceError != nil },
            set: { isPresented in
                if !isPresented { store.dismissPersistenceError() }
            }
        )) {
            Button("知道了", role: .cancel) {
                store.dismissPersistenceError()
            }
        } message: {
            Text(store.persistenceError ?? "请从“我的－设置－调试”导出诊断日志。")
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

    @ViewBuilder
    private var adaptiveMainInterface: some View {
        if usesWideLayout {
            DesktopRootView(selection: $desktopSelection)
        } else {
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
        }
    }

    private var usesWideLayout: Bool {
#if os(macOS)
        true
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }
}

private enum RootDestination: Hashable {
    case module(ToolModule)
    case profile
}

private struct DesktopRootView: View {
    @EnvironmentObject private var moduleSettings: ToolModuleSettings
    @Binding var selection: RootDestination?

    private var visibleModules: [ToolModule] {
        moduleSettings.orderedModules.filter(moduleSettings.isVisible)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("工具") {
                    ForEach(visibleModules) { module in
                        Label(module.title, systemImage: module.systemImage)
                            .tag(RootDestination.module(module))
                    }
                }

                Section {
                    Label("我的", systemImage: "person.crop.circle")
                        .tag(RootDestination.profile)
                }
            }
            .navigationTitle("我的工具箱")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailView
                .appReadableContent(maxWidth: 960)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear(perform: normalizeSelection)
        .onChange(of: moduleSettings.orderedModules) { _, _ in
            normalizeSelection()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .module(let module):
            NavigationStack {
                destination(for: module)
            }
        case .profile:
            ProfileView()
        case nil:
            ContentUnavailableView("选择一个功能", systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder
    private func destination(for module: ToolModule) -> some View {
        switch module {
        case .personalFinance: HomeView()
        case .myStocks: StocksView()
        case .currencyExchange: CurrencyExchangeView()
        case .healthRecords: HealthRecordsView()
        case .secrets: SecretVaultView()
        }
    }

    private func normalizeSelection() {
        if case .module(let module) = selection, visibleModules.contains(module) {
            return
        }
        selection = visibleModules.first.map(RootDestination.module) ?? .profile
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
