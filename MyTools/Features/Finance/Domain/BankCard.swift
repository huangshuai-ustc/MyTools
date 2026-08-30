#if MYTOOLS_FEATURE_FINANCE
import Foundation

enum BankRegion: String, Codable, CaseIterable, Identifiable {
    case domestic
    case overseas

    var id: Self { self }

    var title: String {
        switch self {
        case .domestic: return "境内银行"
        case .overseas: return "境外银行"
        }
    }
}

enum DomesticAccountType: String, CaseIterable, Identifiable {
    case savings
    case investment
    case foreignCurrency
    case personalPension
    case socialSecurity
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .savings: return "储蓄账户"
        case .investment: return "投资账户"
        case .foreignCurrency: return "外汇账户"
        case .personalPension: return "个人养老金账户"
        case .socialSecurity: return "社保账户"
        case .other: return "其他账户"
        }
    }

    static func selection(for storedValue: String) -> Self {
        let value = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .savings }
        return allCases.first { $0 != .other && $0.title == value } ?? .other
    }
}

enum ForeignAccountType: String, Codable, CaseIterable, Identifiable {
    case savings
    case current
    case fixedDeposit
    case foreignCurrency
    case securities
    case checking
    case smart
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .savings: return "储蓄账户"
        case .current: return "往来账户"
        case .fixedDeposit: return "定存账户"
        case .foreignCurrency: return "外汇账户"
        case .securities: return "投资账户"
        case .checking: return "支票账户"
        case .smart: return "智能账户"
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

extension CurrencyCode {
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

struct BankLoginFieldTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var isSensitive = false

    init(id: UUID = UUID(), name: String = "", isSensitive: Bool = false) {
        self.id = id
        self.name = name
        self.isSensitive = isSensitive
    }
}

extension BankLoginFieldTemplate {
    static let domesticDefaults = [
        BankLoginFieldTemplate(name: "网银登录网址"),
        BankLoginFieldTemplate(name: "客服电话"),
        BankLoginFieldTemplate(name: "安全问题", isSensitive: true)
    ]

    static let overseasDefaults = [
        BankLoginFieldTemplate(name: "网上银行网址"),
        BankLoginFieldTemplate(name: "客服电话"),
        BankLoginFieldTemplate(name: "安全问题", isSensitive: true)
    ]

    func makeField() -> AdditionalLoginField {
        AdditionalLoginField(name: name, isSensitive: isSensitive)
    }
}

struct BankBranchLocation: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    static let defaultLocation = BankBranchLocation(latitude: 39.9087, longitude: 116.3975)
}

struct BankAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var region: BankRegion = .domestic
    var domesticSubaccounts: [DomesticSubaccount] = []
    var foreignSubaccounts: [ForeignSubaccount] = []
    var bankName = ""
    var branchName = ""
    private var onlineBank: Bool?
    var branchLocation: BankBranchLocation?
    var openedAt = Date()
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

    var isOnlineBank: Bool {
        get { onlineBank ?? false }
        set { onlineBank = newValue }
    }
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
        let hasActiveCard = cards.contains { $0.status != .closed }
        let hasActiveSubaccount: Bool
        switch region {
        case .domestic:
            hasActiveSubaccount = domesticSubaccounts.contains { $0.status == .normal }
        case .overseas:
            hasActiveSubaccount = foreignSubaccounts.contains { $0.status == .normal }
        }
        let hasHistoricalCard = !cards.isEmpty
        return !hasActiveCard
            && !hasActiveSubaccount
            && (hasHistoricalCard || status != .normal)
    }
}

#endif
