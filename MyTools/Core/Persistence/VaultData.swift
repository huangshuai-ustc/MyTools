import Foundation

struct VaultData: Codable, @unchecked Sendable {
    var accounts: [BankAccount] = []
    var cards: [BankCard] = []
    var stocks: [StockHolding] = []
    var currencyExchangeRecords: [CurrencyExchangeRecord] = []
    var medicalRecords: [MedicalRecord] = []
    var hospitalProfiles: [HospitalProfile] = []
    var currencyRateAlerts: [CurrencyRateAlert] = []
    var stockPriceAlerts: [StockPriceAlert] = []

    init(
        accounts: [BankAccount] = [],
        cards: [BankCard] = [],
        stocks: [StockHolding] = [],
        currencyExchangeRecords: [CurrencyExchangeRecord] = [],
        medicalRecords: [MedicalRecord] = [],
        hospitalProfiles: [HospitalProfile] = [],
        currencyRateAlerts: [CurrencyRateAlert] = [],
        stockPriceAlerts: [StockPriceAlert] = []
    ) {
        self.accounts = accounts
        self.cards = cards
        self.stocks = stocks
        self.currencyExchangeRecords = currencyExchangeRecords
        self.medicalRecords = medicalRecords
        self.hospitalProfiles = hospitalProfiles
        self.currencyRateAlerts = currencyRateAlerts
        self.stockPriceAlerts = stockPriceAlerts
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        case cards
        case stocks
        case currencyExchangeRecords
        case medicalRecords
        case hospitalProfiles
        case currencyRateAlerts
        case stockPriceAlerts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([BankAccount].self, forKey: .accounts) ?? []
        cards = try container.decodeIfPresent([BankCard].self, forKey: .cards) ?? []
        stocks = try container.decodeIfPresent([StockHolding].self, forKey: .stocks) ?? []
        currencyExchangeRecords = try container.decodeIfPresent(
            [CurrencyExchangeRecord].self,
            forKey: .currencyExchangeRecords
        ) ?? []
        medicalRecords = try container.decodeIfPresent([MedicalRecord].self, forKey: .medicalRecords) ?? []
        hospitalProfiles = try container.decodeIfPresent([HospitalProfile].self, forKey: .hospitalProfiles) ?? []
        currencyRateAlerts = try container.decodeIfPresent(
            [CurrencyRateAlert].self,
            forKey: .currencyRateAlerts
        ) ?? []
        stockPriceAlerts = try container.decodeIfPresent(
            [StockPriceAlert].self,
            forKey: .stockPriceAlerts
        ) ?? []
    }

    var currentCardCount: Int {
        cards.lazy.filter { $0.status != .closed }.count
    }

    var currentBankCount: Int {
        let cardsByAccountID = Dictionary(grouping: cards) { $0.accountID }
        return accounts.lazy.filter { account in
            let linkedCards = cardsByAccountID[account.id] ?? []
            return !account.isInactiveFinanceArchive(cards: linkedCards)
        }.count
    }
}
