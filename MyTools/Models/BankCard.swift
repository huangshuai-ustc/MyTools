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
        case .securities: return "证券账户"
        case .other: return "其他账户"
        }
    }
}

enum CurrencyCode: String, Codable, CaseIterable, Identifiable {
    case cny = "CNY"
    case hkd = "HKD"
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case aud = "AUD"
    case cad = "CAD"
    case chf = "CHF"
    case sgd = "SGD"
    case nzd = "NZD"
    case mop = "MOP"

    var id: Self { self }

    var title: String {
        switch self {
        case .cny: return "人民币 CNY"
        case .hkd: return "港币 HKD"
        case .usd: return "美元 USD"
        case .eur: return "欧元 EUR"
        case .gbp: return "英镑 GBP"
        case .jpy: return "日元 JPY"
        case .aud: return "澳元 AUD"
        case .cad: return "加元 CAD"
        case .chf: return "瑞郎 CHF"
        case .sgd: return "新加坡元 SGD"
        case .nzd: return "新西兰元 NZD"
        case .mop: return "澳门元 MOP"
        }
    }

    fileprivate static func selections(from legacyText: String) -> Set<CurrencyCode> {
        guard !legacyText.isEmpty else { return [] }
        return Set(allCases.filter { currency in
            legacyText.localizedCaseInsensitiveContains(currency.rawValue)
                || legacyText.contains(currency.title.replacingOccurrences(of: " \(currency.rawValue)", with: ""))
        })
    }
}

struct ForeignSubaccount: Identifiable, Codable, Equatable {
    var id: UUID
    var type: ForeignAccountType
    var name: String
    var accountNumber: String
    var currencies: Set<CurrencyCode>
    fileprivate var legacyIBAN: String

    private enum CodingKeys: String, CodingKey {
        case id, type, name, accountNumber, currencies
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case iban
    }

    init(
        id: UUID = UUID(),
        type: ForeignAccountType = .savings,
        name: String = "",
        accountNumber: String = "",
        currencies: Set<CurrencyCode> = []
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.accountNumber = accountNumber
        self.currencies = currencies
        legacyIBAN = ""
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try values.decodeIfPresent(ForeignAccountType.self, forKey: .type) ?? .other
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        accountNumber = try values.decodeIfPresent(String.self, forKey: .accountNumber) ?? ""
        currencies = try values.decodeIfPresent(Set<CurrencyCode>.self, forKey: .currencies) ?? []
        let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
        legacyIBAN = try legacyValues.decodeIfPresent(String.self, forKey: .iban) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(type, forKey: .type)
        try values.encode(name, forKey: .name)
        try values.encode(accountNumber, forKey: .accountNumber)
        try values.encode(currencies, forKey: .currencies)
    }

    var currencySummary: String {
        CurrencyCode.allCases
            .filter { currencies.contains($0) }
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
        case .closed: return "已销户"
        }
    }
}

struct BankCard: Identifiable, Codable, Equatable {
    var id = UUID()
    var accountID: UUID? = nil
    var bankName = ""
    var branchName = ""
    var openedAt = Date()
    var cardNumber = ""
    var cvv = ""
    var expiryDate = Date()
    var expiryPrecision: CardExpiryPrecision = .yearMonth
    var cardType = "借记卡"
    var status: CardStatus = .normal
    var currencies: Set<CurrencyCode> = []
    var holderName = ""
    var applePay = false
    var defaultPayment = false
    var note = ""

    private enum CodingKeys: String, CodingKey {
        case id, accountID, bankName, branchName, openedAt, cardNumber, cvv
        case expiryDate, expiryPrecision, cardType, status, currencies, holderName, applePay, defaultPayment, note
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        accountID = try values.decodeIfPresent(UUID.self, forKey: .accountID)
        bankName = try values.decodeIfPresent(String.self, forKey: .bankName) ?? ""
        branchName = try values.decodeIfPresent(String.self, forKey: .branchName) ?? ""
        openedAt = try values.decodeIfPresent(Date.self, forKey: .openedAt) ?? Date()
        cardNumber = try values.decodeIfPresent(String.self, forKey: .cardNumber) ?? ""
        cvv = try values.decodeIfPresent(String.self, forKey: .cvv) ?? ""
        expiryDate = try values.decodeIfPresent(Date.self, forKey: .expiryDate) ?? Date()
        expiryPrecision = try values.decodeIfPresent(CardExpiryPrecision.self, forKey: .expiryPrecision) ?? .yearMonth
        cardType = try values.decodeIfPresent(String.self, forKey: .cardType) ?? "借记卡"
        status = try values.decodeIfPresent(CardStatus.self, forKey: .status) ?? .normal
        currencies = try values.decodeIfPresent(Set<CurrencyCode>.self, forKey: .currencies) ?? []
        holderName = try values.decodeIfPresent(String.self, forKey: .holderName) ?? ""
        applePay = try values.decodeIfPresent(Bool.self, forKey: .applePay) ?? false
        defaultPayment = try values.decodeIfPresent(Bool.self, forKey: .defaultPayment) ?? false
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    var currencySummary: String {
        CurrencyCode.allCases
            .filter { currencies.contains($0) }
            .map(\.rawValue)
            .joined(separator: "、")
    }
}

struct BankAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var region: BankRegion = .domestic
    var foreignSubaccounts: [ForeignSubaccount] = []
    var bankName = ""
    var branchName = ""
    var openedAt = Date()
    var name = ""
    var accountType = ""
    var currency = ""
    var accountNumber = ""
    var swift = ""
    var iban = ""
    var status = "正常"
    var note = ""

    private enum CodingKeys: String, CodingKey {
        case id, region, foreignSubaccounts, bankName, branchName, openedAt, name, accountType, currency
        case accountNumber, swift, iban, status, note
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case foreignAccountTypes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bankName = try values.decodeIfPresent(String.self, forKey: .bankName) ?? ""
        branchName = try values.decodeIfPresent(String.self, forKey: .branchName) ?? ""
        openedAt = try values.decodeIfPresent(Date.self, forKey: .openedAt) ?? Date()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        accountType = try values.decodeIfPresent(String.self, forKey: .accountType) ?? ""
        currency = try values.decodeIfPresent(String.self, forKey: .currency) ?? ""
        accountNumber = try values.decodeIfPresent(String.self, forKey: .accountNumber) ?? ""
        swift = try values.decodeIfPresent(String.self, forKey: .swift) ?? ""
        iban = try values.decodeIfPresent(String.self, forKey: .iban) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "正常"
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""

        if let savedRegion = try values.decodeIfPresent(BankRegion.self, forKey: .region) {
            region = savedRegion
        } else {
            region = accountNumber.isEmpty && swift.isEmpty && iban.isEmpty ? .domestic : .overseas
        }

        if values.contains(.foreignSubaccounts) {
            foreignSubaccounts = try values.decodeIfPresent([ForeignSubaccount].self, forKey: .foreignSubaccounts) ?? []
        } else if region == .overseas {
            let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let legacyTypes = try legacyValues.decodeIfPresent(Set<ForeignAccountType>.self, forKey: .foreignAccountTypes) ?? []
            foreignSubaccounts = Self.migrateLegacySubaccounts(
                types: legacyTypes,
                accountNumber: accountNumber,
                currency: currency
            )
        } else {
            foreignSubaccounts = []
        }

        if iban.isEmpty,
           let migratedIBAN = foreignSubaccounts.lazy.map(\.legacyIBAN).first(where: { !$0.isEmpty }) {
            iban = migratedIBAN
        }
        for index in foreignSubaccounts.indices {
            foreignSubaccounts[index].legacyIBAN = ""
        }
    }

    private static func migrateLegacySubaccounts(
        types: Set<ForeignAccountType>,
        accountNumber: String,
        currency: String
    ) -> [ForeignSubaccount] {
        let orderedTypes = ForeignAccountType.allCases.filter { types.contains($0) }
        let currencies = CurrencyCode.selections(from: currency)

        guard !orderedTypes.isEmpty else {
            guard !accountNumber.isEmpty || !currencies.isEmpty else { return [] }
            return [ForeignSubaccount(type: .other, accountNumber: accountNumber, currencies: currencies)]
        }

        return orderedTypes.enumerated().map { index, type in
            ForeignSubaccount(
                type: type,
                accountNumber: index == 0 ? accountNumber : "",
                currencies: currencies
            )
        }
    }
}

struct VaultData: Codable {
    var accounts: [BankAccount] = []
    var cards: [BankCard] = []
}
