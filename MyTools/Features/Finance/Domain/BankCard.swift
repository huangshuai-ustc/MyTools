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
    case providentFund
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .savings: return "储蓄账户"
        case .investment: return "投资账户"
        case .foreignCurrency: return "外汇账户"
        case .personalPension: return "个人养老金账户"
        case .socialSecurity: return "社保账户"
        case .providentFund: return "公积金账户"
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

// Accounts and cards share the same lifecycle; encoded raw values are unchanged.
typealias AccountStatus = CardStatus

extension CurrencyCode {
    static func preferredFinanceCases(for region: BankRegion) -> [CurrencyCode] {
        [.cny, .hkd, .usd]
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
        case .jcb: return "吉士美/JCB"
        case .americanExpress: return "美国运通/American Express"
        case .dinersClub: return "大莱/Diners Club"
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

struct BankCardCredential: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var cardNumber = ""
    var networks: Set<CardNetwork> = []
    var cvv = ""
    var expiryDate = Date()
    var currencies: Set<CurrencyCode> = []
    var holderName = ""
    var status: CardStatus = .normal

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "附加卡号" : trimmedName
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        cardNumber: String = "",
        networks: Set<CardNetwork> = [],
        cvv: String = "",
        expiryDate: Date = Date(),
        currencies: Set<CurrencyCode> = [],
        holderName: String = "",
        status: CardStatus = .normal
    ) {
        self.id = id
        self.name = name
        self.cardNumber = cardNumber
        self.networks = networks
        self.cvv = cvv
        self.expiryDate = expiryDate
        self.currencies = currencies
        self.holderName = holderName
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cardNumber, networks, network, cvv, expiryDate, currencies, holderName, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        cardNumber = try container.decodeIfPresent(String.self, forKey: .cardNumber) ?? ""
        networks = try container.decodeIfPresent(Set<CardNetwork>.self, forKey: .networks) ?? []
        if networks.isEmpty,
           let legacyNetwork = try container.decodeIfPresent(CardNetwork.self, forKey: .network) {
            networks = [legacyNetwork]
        }
        cvv = try container.decodeIfPresent(String.self, forKey: .cvv) ?? ""
        expiryDate = try container.decodeIfPresent(Date.self, forKey: .expiryDate) ?? Date()
        currencies = try container.decodeIfPresent(Set<CurrencyCode>.self, forKey: .currencies) ?? []
        holderName = try container.decodeIfPresent(String.self, forKey: .holderName) ?? ""
        status = try container.decodeIfPresent(CardStatus.self, forKey: .status) ?? .normal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(cardNumber, forKey: .cardNumber)
        try container.encode(networks, forKey: .networks)
        try container.encode(cvv, forKey: .cvv)
        try container.encode(expiryDate, forKey: .expiryDate)
        try container.encode(currencies, forKey: .currencies)
        try container.encode(holderName, forKey: .holderName)
        try container.encode(status, forKey: .status)
    }
}

struct BankCard: Identifiable, Codable, Equatable {
    var id = UUID()
    var accountID: UUID? = nil
    /// accountID remains the institution envelope; these are actual financial accounts.
    var linkedFinancialAccountIDs: Set<UUID>?
    var isVirtual: Bool?
    var isArchived: Bool?
    var replacedByCardID: UUID?
    var openingDateKnown: Bool?
    var expiryDateKnown: Bool?
    var openedAt = Date()
    var cardNumber = ""
    var cvv = ""
    var expiryDate = Date()
    var expiryPrecision: CardExpiryPrecision = .yearMonth
    var cardType = ""
    var kind: BankCardKind = .debit
    var branchName: String?
    var branchLocation: BankBranchLocation?
    var networks: Set<CardNetwork> = []
    var status: CardStatus = .normal
    var currencies: Set<CurrencyCode> = []
    var holderName = ""
    var statements: [CreditCardStatement] = []
    /// Additional numbers belonging to the same card product. Optional keeps older backups
    /// decodable without a migration step; the legacy top-level fields remain the primary number.
    var additionalCardCredentials: [BankCardCredential]?

    var additionalCredentials: [BankCardCredential] {
        get { additionalCardCredentials ?? [] }
        set { additionalCardCredentials = newValue.isEmpty ? nil : newValue }
    }

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

    init(
        id: UUID = UUID(),
        name: String = "",
        isSensitive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isSensitive = isSensitive
    }
}

extension BankLoginFieldTemplate {
    static let standardDefaults = [
        BankLoginFieldTemplate(name: "绑定手机号"),
        BankLoginFieldTemplate(name: "登录账号"),
        BankLoginFieldTemplate(name: "登录密码", isSensitive: true)
    ]

    static let domesticDefaults = standardDefaults + [
        BankLoginFieldTemplate(name: "网银登录网址"),
        BankLoginFieldTemplate(name: "客服电话"),
        BankLoginFieldTemplate(name: "安全问题", isSensitive: true)
    ]

    static let overseasDefaults = standardDefaults + [
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

struct BankBranchReference: Equatable, Sendable {
    var name: String
    var location: BankBranchLocation?

    var hasValue: Bool {
        !name.isEmpty || location != nil
    }
}

extension BankCard {
    func resolvedOpeningBranch(for account: FinancialInstitution) -> BankBranchReference {
        guard account.kind == .bank, !account.isOnlineBank else { return BankBranchReference(name: account.isOnlineBank ? "网络银行" : "", location: nil) }
        if account.region == .overseas { return BankBranchReference(name: account.branchName, location: account.branchLocation) }
        let explicit = BankBranchReference(name: branchName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", location: branchLocation)
        return explicit.hasValue ? explicit : BankBranchReference(name: account.branchName, location: account.branchLocation)
    }
    mutating func applyDefaultOpeningBranch(from account: FinancialInstitution) {
        guard account.kind == .bank, account.region == .domestic, !account.isOnlineBank, branchName?.isEmpty != false, branchLocation == nil else { return }
        let branch = resolvedOpeningBranch(for: account)
        branchName = branch.name.isEmpty ? nil : branch.name
        branchLocation = branch.location
    }
}
#endif
