import SwiftUI

struct ToolModuleDestination: View {
    let module: ToolModule
    @EnvironmentObject private var store: AppStore

    @ViewBuilder
    var body: some View {
        if store.unavailableModules.contains(module) {
            ContentUnavailableView("此模块的数据暂时无法读取", systemImage: "exclamationmark.shield", description: Text("原始资料已保留，此模块的编辑和同步已暂停。其他功能仍可正常使用。请勿通过清空数据处理此问题。"))
        } else {
            destination
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch module {
        case .personalFinance:
#if MYTOOLS_FEATURE_FINANCE
            HomeView()
#else
            unavailableModule(module)
#endif
        case .myStocks:
#if MYTOOLS_FEATURE_STOCKS
            StocksView()
#else
            unavailableModule(module)
#endif
        case .currencyExchange:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
            CurrencyExchangeView()
#else
            unavailableModule(module)
#endif
        case .healthRecords:
#if MYTOOLS_FEATURE_HEALTH
            HealthRecordsView()
#else
            unavailableModule(module)
#endif
        case .foodMap:
            unavailableModule(module)
        case .secrets:
#if MYTOOLS_FEATURE_SECRETS
            SecretVaultView()
#else
            unavailableModule(module)
#endif
        case .documents:
#if MYTOOLS_FEATURE_DOCUMENTS
            DocumentsView()
#else
            unavailableModule(module)
#endif
        case .bills:
#if MYTOOLS_FEATURE_BILLS
            BillsView()
#else
            unavailableModule(module)
#endif
        case .partnership:
            unavailableModule(module)
        case .sportsLottery:
#if MYTOOLS_FEATURE_SPORTS_LOTTERY
            SportsLotteryView()
#else
            unavailableModule(module)
#endif
        }
    }

    private func unavailableModule(_ module: ToolModule) -> some View {
        ContentUnavailableView(
            "功能未编译",
            systemImage: module.systemImage,
            description: Text("当前构建不包含“\(module.title)”。")
        )
    }
}
