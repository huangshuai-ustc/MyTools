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
    case cad = "CAD"
    case chf = "CHF"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case nzd = "NZD"
    case sgd = "SGD"
    case thb = "THB"
    case usd = "USD"
    // 仅用于读取旧版档案，不再出现在新建数据的币种选项中。
    case aud = "AUD"
    case mop = "MOP"

    static let selectableCases: [CurrencyCode] = [
        .cny, .hkd, .usd, .cad, .chf, .eur, .gbp, .jpy, .nzd, .sgd, .thb
    ]

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
        case .aud: return "澳元 AUD"
        case .mop: return "澳门元 MOP"
        }
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
        case .mop: return "澳门元"
        }
    }

    static func selectableCases(including current: CurrencyCode) -> [CurrencyCode] {
        selectableCases.contains(current) ? selectableCases : selectableCases + [current]
    }

    static func selectableCases(including current: Set<CurrencyCode>) -> [CurrencyCode] {
        selectableCases + allCases.filter { !selectableCases.contains($0) && current.contains($0) }
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

struct DomesticSubaccount: Identifiable, Codable, Equatable {
    var id: UUID
    var type: String
    var name: String
    var accountNumber: String
    var currencies: Set<CurrencyCode>

    private enum CodingKeys: String, CodingKey {
        case id, type, name, accountNumber, currencies
    }

    init(
        id: UUID = UUID(),
        type: String = "",
        name: String = "",
        accountNumber: String = "",
        currencies: Set<CurrencyCode> = [.cny]
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.accountNumber = accountNumber
        self.currencies = currencies
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        accountNumber = try values.decodeIfPresent(String.self, forKey: .accountNumber) ?? ""
        currencies = try values.decodeIfPresent(Set<CurrencyCode>.self, forKey: .currencies) ?? [.cny]
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

enum BankCardKind: String, Codable, CaseIterable, Identifiable {
    case debit
    case credit

    var id: Self { self }

    var title: String {
        switch self {
        case .debit: return "借记卡"
        case .credit: return "贷记卡"
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
        case .unionPay: return "银联"
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case .jcb: return "JCB"
        case .americanExpress: return "美国运通"
        case .dinersClub: return "大来卡"
        case .discover: return "Discover"
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
    var cardType = ""
    var kind: BankCardKind = .debit
    var networks: Set<CardNetwork> = []
    var status: CardStatus = .normal
    var currencies: Set<CurrencyCode> = []
    var holderName = ""
    var applePay = false
    var defaultPayment = false
    var note = ""

    private enum CodingKeys: String, CodingKey {
        case id, accountID, bankName, branchName, openedAt, cardNumber, cvv
        case expiryDate, expiryPrecision, cardType, kind, networks, status, currencies, holderName, applePay, defaultPayment, note
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
        cardType = try values.decodeIfPresent(String.self, forKey: .cardType) ?? ""
        if let savedKind = try values.decodeIfPresent(BankCardKind.self, forKey: .kind) {
            kind = savedKind
        } else {
            let legacyType = cardType.trimmingCharacters(in: .whitespacesAndNewlines)
            kind = legacyType.contains("贷记") || legacyType.contains("信用") ? .credit : .debit
            if ["借记卡", "贷记卡", "信用卡"].contains(legacyType) {
                cardType = ""
            }
        }
        networks = try values.decodeIfPresent(Set<CardNetwork>.self, forKey: .networks) ?? []
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
    var domesticSubaccounts: [DomesticSubaccount] = []
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
    var boundPhoneNumber = ""
    var loginAccount = ""
    var loginPassword = ""
    var correspondenceAddressChinese = ""
    var correspondenceAddressEnglish = ""
    var residentialAddressChinese = ""
    var residentialAddressEnglish = ""
    var remittanceBankName = ""
    var remittanceBankAddress = ""
    var remittanceSwiftCode = ""
    var remittanceInstructions = ""
    var status = "正常"
    var note = ""

    private enum CodingKeys: String, CodingKey {
        case id, region, domesticSubaccounts, foreignSubaccounts, bankName, branchName, openedAt, name, accountType, currency
        case accountNumber, swift, iban, boundPhoneNumber, loginAccount, loginPassword
        case correspondenceAddressChinese, correspondenceAddressEnglish
        case residentialAddressChinese, residentialAddressEnglish
        case remittanceBankName, remittanceBankAddress, remittanceSwiftCode, remittanceInstructions
        case status, note
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
        boundPhoneNumber = try values.decodeIfPresent(String.self, forKey: .boundPhoneNumber) ?? ""
        loginAccount = try values.decodeIfPresent(String.self, forKey: .loginAccount) ?? ""
        loginPassword = try values.decodeIfPresent(String.self, forKey: .loginPassword) ?? ""
        correspondenceAddressChinese = try values.decodeIfPresent(String.self, forKey: .correspondenceAddressChinese) ?? ""
        correspondenceAddressEnglish = try values.decodeIfPresent(String.self, forKey: .correspondenceAddressEnglish) ?? ""
        residentialAddressChinese = try values.decodeIfPresent(String.self, forKey: .residentialAddressChinese) ?? ""
        residentialAddressEnglish = try values.decodeIfPresent(String.self, forKey: .residentialAddressEnglish) ?? ""
        remittanceBankName = try values.decodeIfPresent(String.self, forKey: .remittanceBankName) ?? ""
        remittanceBankAddress = try values.decodeIfPresent(String.self, forKey: .remittanceBankAddress) ?? ""
        remittanceSwiftCode = try values.decodeIfPresent(String.self, forKey: .remittanceSwiftCode) ?? ""
        remittanceInstructions = try values.decodeIfPresent(String.self, forKey: .remittanceInstructions) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "正常"
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""

        if let savedRegion = try values.decodeIfPresent(BankRegion.self, forKey: .region) {
            region = savedRegion
        } else {
            region = accountNumber.isEmpty && swift.isEmpty && iban.isEmpty ? .domestic : .overseas
        }

        if values.contains(.domesticSubaccounts) {
            domesticSubaccounts = try values.decodeIfPresent([DomesticSubaccount].self, forKey: .domesticSubaccounts) ?? []
        } else if region == .domestic {
            domesticSubaccounts = Self.migrateLegacyDomesticSubaccounts(
                accountType: accountType,
                accountNumber: accountNumber,
                currency: currency
            )
            if !domesticSubaccounts.isEmpty {
                accountType = ""
                accountNumber = ""
                currency = ""
            }
        } else {
            domesticSubaccounts = []
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

    private static func migrateLegacyDomesticSubaccounts(
        accountType: String,
        accountNumber: String,
        currency: String
    ) -> [DomesticSubaccount] {
        guard !accountType.isEmpty || !accountNumber.isEmpty || !currency.isEmpty else { return [] }
        let selectedCurrencies = CurrencyCode.selections(from: currency)
        return [DomesticSubaccount(
            type: accountType.isEmpty ? "银行账户" : accountType,
            accountNumber: accountNumber,
            currencies: selectedCurrencies.isEmpty ? [.cny] : selectedCurrencies
        )]
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
    var stocks: [StockHolding] = []
    var currencyExchangeRecords: [CurrencyExchangeRecord] = []

    private enum CodingKeys: String, CodingKey {
        case accounts, cards, stocks, currencyExchangeRecords
    }

    init(
        accounts: [BankAccount] = [],
        cards: [BankCard] = [],
        stocks: [StockHolding] = [],
        currencyExchangeRecords: [CurrencyExchangeRecord] = []
    ) {
        self.accounts = accounts
        self.cards = cards
        self.stocks = stocks
        self.currencyExchangeRecords = currencyExchangeRecords
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try values.decodeIfPresent([BankAccount].self, forKey: .accounts) ?? []
        cards = try values.decodeIfPresent([BankCard].self, forKey: .cards) ?? []
        stocks = try values.decodeIfPresent([StockHolding].self, forKey: .stocks) ?? []
        currencyExchangeRecords = try values.decodeIfPresent(
            [CurrencyExchangeRecord].self,
            forKey: .currencyExchangeRecords
        ) ?? []
    }

    var currentCardCount: Int {
        cards.lazy.filter { $0.status != .closed }.count
    }

    var currentBankCount: Int {
        accounts.lazy.filter { account in
            let linkedCards = self.cards.filter { $0.accountID == account.id }
            return linkedCards.isEmpty || linkedCards.contains { $0.status != .closed }
        }.count
    }
}
