import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Binding private var desktopSelection: RootDestination?

    init(desktopSelection: Binding<RootDestination?>) {
        _desktopSelection = desktopSelection
    }

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
            Button("重新读取") {
                store.retryVaultLoadAfterFailure()
            }
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
#if MYTOOLS_FEATURE_STOCKS
        .onAppear {
            StockRefreshCoordinator.shared.update(scenePhase: scenePhase)
        }
#endif
#if MYTOOLS_FEATURE_SPORTS_LOTTERY
        .onAppear {
            SportsLotteryRefreshCoordinator.shared.update(scenePhase: scenePhase)
        }
#endif
        .onAppear {
            retryInitialVaultLoadIfPossible()
        }
#if os(iOS)
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            retryInitialVaultLoadIfPossible()
        }
#endif
        .onChange(of: scenePhase) { _, phase in
#if MYTOOLS_FEATURE_STOCKS
            StockRefreshCoordinator.shared.update(scenePhase: phase)
#endif
#if MYTOOLS_FEATURE_SPORTS_LOTTERY
            SportsLotteryRefreshCoordinator.shared.update(scenePhase: phase)
#endif
            if phase == .background {
                DiagnosticLogger.shared.markEnteredBackground()
                Task {
                    await store.flushPendingPersistence()
                    await DiagnosticLogger.shared.flush()
                }
            } else if phase == .active {
                DiagnosticLogger.shared.markBecameActive()
                retryInitialVaultLoadIfPossible()
            }
        }
    }

    private func retryInitialVaultLoadIfPossible() {
#if os(iOS)
        guard UIApplication.shared.isProtectedDataAvailable else {
            DiagnosticLogger.shared.log(
                .persistence,
                "设备受保护数据尚不可用，暂缓载入本地档案",
                level: .warning
            )
            return
        }
#endif
        store.retryInitialVaultLoadIfNeeded()
    }

    @ViewBuilder
    private var adaptiveMainInterface: some View {
        if usesWideLayout {
            DesktopRootView(selection: $desktopSelection)
        } else {
            ToolboxView()
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

enum RootDestination: Hashable {
    case module(ToolModule)
    case profile
}

private struct DesktopRootView: View {
    @EnvironmentObject private var moduleSettings: ToolModuleSettings
    @Binding var selection: RootDestination?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var visibleModules: [ToolModule] {
        moduleSettings.orderedModules.filter(moduleSettings.isVisible)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                ForEach(visibleModules) { module in
                    Label(module.title, systemImage: module.systemImage)
                        .appFont(.body)
                        .tag(RootDestination.module(module))
                }

                Section {
                    Label("设置", systemImage: "gearshape")
                        .appFont(.body)
                        .tag(RootDestination.profile)
                }
            }
            .appNavigationTitle("工具")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailView
                .appReadableContent(
                    maxWidth: 960,
                    fillsAvailableWidth: columnVisibility == .detailOnly
                )
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .navigationSplitViewStyle(.balanced)
#if os(iOS)
        // `NavigationSplitView` otherwise exposes a second, transient sidebar
        // presentation from the leading-edge gesture. That overlay differs from
        // the toolbar button's balanced two-column layout and leaves floating
        // margins around the sidebar. Keep one predictable presentation model.
        .background {
            SplitViewEdgeGestureConfigurator(allowsPresentationGesture: false)
                .frame(width: 0, height: 0)
        }
#endif
        .onAppear(perform: normalizeSelection)
        .onChange(of: moduleSettings.orderedModules) { _, _ in
            normalizeSelection()
        }
        .onChange(of: moduleSettings.visibilityRevision) { _, _ in
            normalizeSelection()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .module(let module):
            NavigationStack {
                ToolModuleDestination(module: module)
            }
            .environment(\.isSidebarCollapsed, columnVisibility == .detailOnly)
        case .profile:
            ProfileSettingsView()
                .environment(\.isSidebarCollapsed, columnVisibility == .detailOnly)
        case nil:
            ContentUnavailableView("选择一个功能", systemImage: "square.grid.2x2")
        }
    }

    private func normalizeSelection() {
        if selection == .profile {
            return
        }
        if case .module(let module) = selection, visibleModules.contains(module) {
            return
        }
        selection = visibleModules.first.map(RootDestination.module) ?? .profile
    }
}

#if os(iOS)
private struct SplitViewEdgeGestureConfigurator: UIViewControllerRepresentable {
    let allowsPresentationGesture: Bool

    func makeUIViewController(context: Context) -> ConfiguratorViewController {
        ConfiguratorViewController(allowsPresentationGesture: allowsPresentationGesture)
    }

    func updateUIViewController(
        _ viewController: ConfiguratorViewController,
        context: Context
    ) {
        viewController.allowsPresentationGesture = allowsPresentationGesture
        viewController.applyConfigurationWhenAttached()
    }

    final class ConfiguratorViewController: UIViewController {
        var allowsPresentationGesture: Bool

        init(allowsPresentationGesture: Bool) {
            self.allowsPresentationGesture = allowsPresentationGesture
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyConfigurationWhenAttached()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyConfiguration()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyConfiguration()
        }

        func applyConfigurationWhenAttached() {
            // SwiftUI can attach this representable one run-loop turn before its
            // hosting controller is parented into UISplitViewController.
            DispatchQueue.main.async { [weak self] in
                self?.applyConfiguration()
            }
        }

        private func applyConfiguration() {
            guard let rootViewController = view.window?.rootViewController else { return }
            configureSplitViewControllers(in: rootViewController)
        }

        private func configureSplitViewControllers(in viewController: UIViewController) {
            if let splitViewController = viewController as? UISplitViewController {
                splitViewController.presentsWithGesture = allowsPresentationGesture
                // UIKit's automatic policy hides the display-mode button when
                // presentsWithGesture is false. Keep the explicit button usable.
                splitViewController.displayModeButtonVisibility = .always
            }

            for child in viewController.children {
                configureSplitViewControllers(in: child)
            }
            if let presentedViewController = viewController.presentedViewController {
                configureSplitViewControllers(in: presentedViewController)
            }
        }
    }
}
#endif

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
