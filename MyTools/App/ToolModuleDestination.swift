import SwiftUI

struct ToolModuleDestination: View {
    let module: ToolModule

    @ViewBuilder
    var body: some View {
        switch module {
        case .personalFinance: HomeView()
        case .myStocks: StocksView()
        case .currencyExchange: CurrencyExchangeView()
        case .healthRecords: HealthRecordsView()
        case .secrets: SecretVaultView()
        }
    }
}
