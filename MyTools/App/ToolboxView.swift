import SwiftUI

struct ToolboxView: View {
    @EnvironmentObject private var moduleSettings: ToolModuleSettings

    private var visibleModules: [ToolModule] {
        moduleSettings.orderedModules.filter(moduleSettings.isVisible)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("工具") {
                    ForEach(visibleModules) { module in
                        NavigationLink { destination(for: module) } label: { moduleRow(module) }
                            .appListRowStyle()
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
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text(module.title).font(.headline)
                Text(module.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
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
}
