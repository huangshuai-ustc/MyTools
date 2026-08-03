import Foundation

enum BankRegion: String, Codable, CaseIterable, Identifiable {
    case domestic
    case overseas

    var id: Self { self }

    var title: String {
        switch self {
        case .domestic: return "国内银行"
        case .overseas: return "境外银行"
        }
    }
}

enum DomesticAccountType: String, CaseIterable, Identifiable {
    case personalPension
    case socialSecurity
    case housingProvidentFund
    case foreignCurrency
    case savings
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .personalPension: return "个人养老金账户"
        case .socialSecurity: return "社保账户"
        case .housingProvidentFund: return "公积金账户"
        case .foreignCurrency: return "外汇账户"
        case .savings: return "储蓄账户"
        case .other: return "其他账户"
        }
    }

    static func selection(for storedValue: String) -> Self {
        let value = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .personalPension }
        return allCases.first { $0 != .other && $0.title == value } ?? .other
    }
}

enum ForeignAccountType: String, Codable, CaseIterable, Identifiable {
    case savings
    case current
    case fixedDeposit
    case foreignCurrency
    case securities
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .savings: return "储蓄账户"
        case .current: return "往来账户"
        case .fixedDeposit: return "定期存款账户"
        case .foreignCurrency: return "外汇账户"
        case .securities: return "投资账户"
        case .other: return "其他账户"
        }
    }
}

enum AccountStatus: String, Codable, CaseIterable, Identifiable {
    case normal
    case abnormal
    case closed

    var id: Self { self }

    var title: String {
        switch self {
        case .normal: return "正常"
        case .abnormal: return "异常"
        case .closed: return "销户"
        }
    }
}

enum CurrencyCode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cny = "CNY"
    case hkd = "HKD"
    case cad = "CAD"
    case chf = "CHF"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case nzd = "NZD"
    case sgd = "SGD"
    case thb = "THB"
    case usd = "USD"
    case aud = "AUD"

    private static let supportedCases = Set(allCases)

    static var selectableCases: [CurrencyCode] {
        displayOrdered(supportedCases)
    }

    static func preferredFinanceCases(for region: BankRegion) -> [CurrencyCode] {
        switch region {
        case .domestic:
            return [.cny, .hkd, .usd]
        case .overseas:
            return [.cny, .hkd, .usd, .eur, .gbp, .jpy]
        }
    }

    static func additionalFinanceCases(
        for region: BankRegion,
        including current: Set<CurrencyCode>
    ) -> [CurrencyCode] {
        let preferred = Set(preferredFinanceCases(for: region))
        return selectableCases(including: current).filter { !preferred.contains($0) }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .cny: return "人民币 CNY"
        case .hkd: return "港币 HKD"
        case .cad: return "加拿大元 CAD"
        case .chf: return "瑞士法郎 CHF"
        case .eur: return "欧元 EUR"
        case .gbp: return "英镑 GBP"
        case .jpy: return "日元 JPY"
        case .nzd: return "新西兰元 NZD"
        case .sgd: return "新加坡元 SGD"
        case .thb: return "泰国铢 THB"
        case .usd: return "美元 USD"
        case .aud: return "澳大利亚元 AUD"
        }
    }

    private var chineseName: String {
        title.replacingOccurrences(of: " \(rawValue)", with: "")
    }

    /// 中国银行外汇牌价页使用的货币名称；新增币种时在这里补充映射即可。
    var bankOfChinaName: String? {
        switch self {
        case .cny: return nil
        case .hkd: return "港币"
        case .cad: return "加拿大元"
        case .chf: return "瑞士法郎"
        case .eur: return "欧元"
        case .gbp: return "英镑"
        case .jpy: return "日元"
        case .nzd: return "新西兰元"
        case .sgd: return "新加坡元"
        case .thb: return "泰国铢"
        case .usd: return "美元"
        case .aud: return "澳大利亚元"
        }
    }

    static func selectableCases(including current: CurrencyCode) -> [CurrencyCode] {
        displayOrdered(supportedCases.union([current]))
    }

    static func selectableCases(including current: Set<CurrencyCode>) -> [CurrencyCode] {
        displayOrdered(supportedCases.union(current))
    }

    static func displayOrdered(_ currencies: Set<CurrencyCode>) -> [CurrencyCode] {
        let fixedPriority: [CurrencyCode: Int] = [.cny: 0, .hkd: 1, .usd: 2]
        let locale = Locale(identifier: "zh_Hans_CN")

        return currencies.sorted { lhs, rhs in
            let lhsPriority = fixedPriority[lhs] ?? Int.max
            let rhsPriority = fixedPriority[rhs] ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            let comparison = lhs.chineseName.compare(
                rhs.chineseName,
                options: [],
                range: nil,
                locale: locale
            )
            return comparison == .orderedSame
                ? lhs.rawValue < rhs.rawValue
                : comparison == .orderedAscending
        }
    }
}

struct ForeignSubaccount: Identifiable, Codable, Equatable {
    var id: UUID
    var type: ForeignAccountType
    var name: String
    var accountNumber: String
    var currencies: Set<CurrencyCode>
    var status: AccountStatus
    var customType: String?

    init(
        id: UUID = UUID(),
        type: ForeignAccountType = .savings,
        name: String = "",
        accountNumber: String = "",
        currencies: Set<CurrencyCode> = [],
        status: AccountStatus = .normal,
        customType: String? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.accountNumber = accountNumber
        self.currencies = currencies
        self.status = status
        self.customType = customType
    }

    var currencySummary: String {
        CurrencyCode.displayOrdered(currencies)
            .map(\.rawValue)
            .joined(separator: "、")
    }

    var typeTitle: String {
        guard type == .other else { return type.title }
        let customTitle = customType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return customTitle.isEmpty ? type.title : customTitle
    }
}

struct DomesticSubaccount: Identifiable, Codable, Equatable {
    var id: UUID
    var type: String
    var name: String
    var accountNumber: String
    var currencies: Set<CurrencyCode>
    var status: AccountStatus

    init(
        id: UUID = UUID(),
        type: String = "",
        name: String = "",
        accountNumber: String = "",
        currencies: Set<CurrencyCode> = [.cny],
        status: AccountStatus = .normal
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.accountNumber = accountNumber
        self.currencies = currencies
        self.status = status
    }

    var currencySummary: String {
        CurrencyCode.displayOrdered(currencies)
            .map(\.rawValue)
            .joined(separator: "、")
    }
}

enum CardExpiryPrecision: String, Codable, CaseIterable, Identifiable {
    case yearMonth
    case fullDate

    var id: Self { self }

    var title: String {
        switch self {
        case .yearMonth: return "年月"
        case .fullDate: return "年月日"
        }
    }
}

enum CardStatus: String, Codable, CaseIterable, Identifiable {
    case normal
    case abnormal
    case closed

    var id: Self { self }

    var title: String {
        switch self {
        case .normal: return "正常"
        case .abnormal: return "异常"
        case .closed: return "销户"
        }
    }
}

enum BankCardKind: String, Codable, CaseIterable, Identifiable {
    case debit
    case credit

    var id: Self { self }

    var title: String {
        switch self {
        case .debit: return "借记卡"
        case .credit: return "信用卡"
        }
    }
}

enum CardNetwork: String, Codable, CaseIterable, Identifiable {
    case unionPay
    case visa
    case mastercard
    case jcb
    case americanExpress
    case dinersClub
    case discover

    var id: Self { self }

    var title: String {
        switch self {
        case .unionPay: return "银联/UnionPay"
        case .visa: return "维萨/Visa"
        case .mastercard: return "万事达/Mastercard"
        case .jcb: return "日财卡/JCB"
        case .americanExpress: return "美国运通/American Express"
        case .dinersClub: return "大来/Diners Club"
        case .discover: return "发现卡/Discover"
        }
    }
}

struct CreditCardStatement: Identifiable, Codable, Equatable {
    var id = UUID()
    var statementDate = Date()
    var attachment: FileAttachment?
    var note = ""
    var createdAt = Date()
}

struct BankCard: Identifiable, Codable, Equatable {
    var id = UUID()
    var accountID: UUID? = nil
    var openedAt = Date()
    var cardNumber = ""
    var cvv = ""
    var expiryDate = Date()
    var expiryPrecision: CardExpiryPrecision = .yearMonth
    var cardType = ""
    var kind: BankCardKind = .debit
    var networks: Set<CardNetwork> = []
    var status: CardStatus = .normal
    var currencies: Set<CurrencyCode> = []
    var holderName = ""
    var statements: [CreditCardStatement] = []

    var currencySummary: String {
        CurrencyCode.displayOrdered(currencies)
            .map(\.rawValue)
            .joined(separator: "、")
    }
}

struct AdditionalLoginField: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var value = ""
    var isSensitive = false

    init(
        id: UUID = UUID(),
        name: String = "",
        value: String = "",
        isSensitive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.isSensitive = isSensitive
    }
}

struct BankAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var region: BankRegion = .domestic
    var domesticSubaccounts: [DomesticSubaccount] = []
    var foreignSubaccounts: [ForeignSubaccount] = []
    var bankName = ""
    var branchName = ""
    var openedAt = Date()
    var name = ""
    var swift = ""
    var iban = ""
    var boundPhoneNumber = ""
    var loginAccount = ""
    var loginPassword = ""
    var additionalLoginFields: [AdditionalLoginField] = []
    var correspondenceAddressChinese = ""
    var correspondenceAddressEnglish = ""
    var residentialAddressChinese = ""
    var residentialAddressEnglish = ""
    var remittanceBankName = ""
    var remittanceBankAddress = ""
    var remittanceInstructions = ""
    var status: AccountStatus = .normal
    var note = ""
}

extension BankAccount {
    var activeSubaccountCount: Int {
        switch region {
        case .domestic:
            domesticSubaccounts.filter { $0.status != .closed }.count
        case .overseas:
            foreignSubaccounts.filter { $0.status != .closed }.count
        }
    }

    var closedSubaccountCount: Int {
        switch region {
        case .domestic:
            domesticSubaccounts.filter { $0.status == .closed }.count
        case .overseas:
            foreignSubaccounts.filter { $0.status == .closed }.count
        }
    }

    func isInactiveFinanceArchive(cards: [BankCard]) -> Bool {
        let hasNormalDebitCard = cards.contains {
            $0.kind == .debit && $0.status == .normal
        }
        let hasActiveSubaccount: Bool
        switch region {
        case .domestic:
            hasActiveSubaccount = domesticSubaccounts.contains { $0.status == .normal }
        case .overseas:
            hasActiveSubaccount = foreignSubaccounts.contains { $0.status == .normal }
        }
        let hasHistoricalDebitCard = cards.contains { $0.kind == .debit }
        return !hasNormalDebitCard
            && !hasActiveSubaccount
            && (hasHistoricalDebitCard || status != .normal)
    }
}

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
