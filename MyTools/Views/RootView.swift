import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
func commitPendingTextInput(then action: @escaping @MainActor () -> Void) {
#if os(iOS)
    // 先让当前输入控件结束编辑，使拼音等带候选词的组合输入完整写回绑定。
    // 调用方不能提前清除 FocusState，否则最后一段 marked text 可能被丢弃。
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
#elseif os(macOS)
    NSApp.keyWindow?.makeFirstResponder(nil)
#endif
    Task { @MainActor in
        await Task.yield()
        await Task.yield()
        action()
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: CardStore
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

enum ToolModule: String, CaseIterable, Identifiable {
    case personalFinance
    case myStocks

    var id: Self { self }

    var title: String {
        switch self {
        case .personalFinance: return "个人金融"
        case .myStocks: return "我的股票"
        }
    }

    var subtitle: String {
        switch self {
        case .personalFinance: return "银行账户与银行卡"
        case .myStocks: return "A 股与美股持仓"
        }
    }

    var systemImage: String {
        switch self {
        case .personalFinance: return "building.columns.fill"
        case .myStocks: return "chart.line.uptrend.xyaxis"
        }
    }

    var tint: Color {
        switch self {
        case .personalFinance: return .blue
        case .myStocks: return .green
        }
    }

    var visibilityKey: String { "tool-module-\(rawValue)-visible" }
}

@MainActor
final class ToolModuleSettings: ObservableObject {
    @Published private var visibility: [String: Bool] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for module in ToolModule.allCases where defaults.object(forKey: module.visibilityKey) != nil {
            visibility[module.rawValue] = defaults.bool(forKey: module.visibilityKey)
        }
    }

    func isVisible(_ module: ToolModule) -> Bool {
        visibility[module.rawValue] ?? true
    }

    func setVisible(_ isVisible: Bool, for module: ToolModule) {
        visibility[module.rawValue] = isVisible
        defaults.set(isVisible, forKey: module.visibilityKey)
    }
}

private struct ToolboxView: View {
    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var moduleSettings: ToolModuleSettings

    private var visibleModules: [ToolModule] {
        ToolModule.allCases.filter(moduleSettings.isVisible)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("工具") {
                    ForEach(visibleModules) { module in
                        NavigationLink {
                            destination(for: module)
                        } label: {
                            moduleRow(module)
                        }
                    }
                }
            }
            .overlay {
                if visibleModules.isEmpty {
                    ContentUnavailableView("暂无已启用功能", systemImage: "square.grid.2x2")
                }
            }
            .navigationTitle("我的工具箱")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.insetGrouped)
#endif
        }
    }

    private func moduleRow(_ module: ToolModule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: module.systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(module.tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title)
                    .font(.headline)
                Text(module.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(moduleSummary(module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func destination(for module: ToolModule) -> some View {
        switch module {
        case .personalFinance:
            HomeView()
        case .myStocks:
            StocksView()
        }
    }

    private func moduleSummary(_ module: ToolModule) -> String {
        switch module {
        case .personalFinance:
            return "\(store.currentBankCount) 家银行 · \(store.currentCardCount) 张卡"
        case .myStocks:
            return "\(store.stocks.count) 只股票 · \(store.openStockCount) 只持仓"
        }
    }
}

extension View {
    func iOSLabeledBackButton(_ title: String) -> some View {
        modifier(IOSLabeledBackButtonModifier(title: title))
    }

    @ViewBuilder
    func iOSLargeSheet() -> some View {
#if os(iOS)
        presentationDetents([.large])
            .presentationDragIndicator(.visible)
#else
        self
#endif
    }
}

private struct IOSLabeledBackButtonModifier: ViewModifier {
    let title: String

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        content
            // 使用系统返回按钮才能保留 iPhone 左侧边缘的交互式滑动返回。
            // 系统会根据 NavigationStack 中上一页的标题显示返回层级名称。
            .navigationBarBackButtonHidden(false)
#else
        content
#endif
    }
}
