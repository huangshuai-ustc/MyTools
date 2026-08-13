import SwiftUI

struct ToolModuleDestination: View {
    let module: ToolModule

    @ViewBuilder
    var body: some View {
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
#if MYTOOLS_FEATURE_FOOD_MAP
            FoodMapView()
#else
            unavailableModule(module)
#endif
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
