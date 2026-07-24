import SwiftUI

struct ToolboxView: View {
    @EnvironmentObject private var store: AppStore
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
                Text(module.title).font(.headline)
                Text(module.subtitle).font(.subheadline).foregroundStyle(.secondary)
                Text(moduleSummary(module)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func destination(for module: ToolModule) -> some View {
        switch module {
        case .personalFinance: HomeView()
        case .myStocks: StocksView()
        case .currencyExchange: CurrencyExchangeView()
        case .healthRecords: HealthRecordsView()
        }
    }

    private func moduleSummary(_ module: ToolModule) -> String {
        switch module {
        case .personalFinance:
            return "\(store.currentBankCount) 家银行 · \(store.currentCardCount) 张卡"
        case .myStocks:
            return "\(store.stocks.count) 只股票 · \(store.openStockCount) 只持仓"
        case .currencyExchange:
            let count = store.currencyExchangeRecords.count
            return count == 0 ? "暂无记录 · 等待首次换汇" : "\(count) 笔记录 · 自动计算损耗"
        case .healthRecords:
            let count = store.medicalRecords.count
            guard count > 0 else { return "暂无记录 · 建立健康档案" }
            let year = Calendar(identifier: .gregorian).component(.year, from: Date())
            let selfPay = store.medicalRecords
                .filter { Calendar(identifier: .gregorian).component(.year, from: $0.date) == year }
                .reduce(Decimal.zero) { $0 + $1.selfPayCost }
            return "\(count) 次就诊 · 本年自费 \(MedicalValueFormatter.money(selfPay))"
        }
    }
}
