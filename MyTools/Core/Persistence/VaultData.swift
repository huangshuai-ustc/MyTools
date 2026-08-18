import Foundation

enum OpaqueModuleValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case decimal(Decimal)
    case string(String)
    case array([OpaqueModuleValue])
    case object([String: OpaqueModuleValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .decimal(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([OpaqueModuleValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: OpaqueModuleValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .decimal(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var attachmentStoredFileNames: Set<String> {
        switch self {
        case .array(let values):
            return values.reduce(into: []) { result, value in
                result.formUnion(value.attachmentStoredFileNames)
            }
        case .object(let values):
            var result = values.values.reduce(into: Set<String>()) { result, value in
                result.formUnion(value.attachmentStoredFileNames)
            }
            if case .string(let storedFileName) = values["storedFileName"],
               !storedFileName.isEmpty {
                result.insert(storedFileName)
            }
            return result
        case .null, .bool, .integer, .decimal, .string:
            return []
        }
    }
}

#if MYTOOLS_FEATURE_FINANCE
typealias BankAccountVaultValue = BankAccount
typealias BankCardVaultValue = BankCard
typealias BankLoginFieldTemplateVaultValue = BankLoginFieldTemplate
#else
typealias BankAccountVaultValue = OpaqueModuleValue
typealias BankCardVaultValue = OpaqueModuleValue
typealias BankLoginFieldTemplateVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_STOCKS
typealias StockHoldingVaultValue = StockHolding
#else
typealias StockHoldingVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
typealias CurrencyExchangeVaultValue = CurrencyExchangeRecord
#else
typealias CurrencyExchangeVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_HEALTH
typealias MedicalRecordVaultValue = MedicalRecord
typealias HospitalProfileVaultValue = HospitalProfile
#else
typealias MedicalRecordVaultValue = OpaqueModuleValue
typealias HospitalProfileVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_FOOD_MAP
typealias FoodPlaceVaultValue = FoodPlace
#else
typealias FoodPlaceVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_SECRETS
typealias SecretVaultValue = SecretItem
typealias SecretFieldTemplateVaultValue = SecretFieldTemplate
#else
typealias SecretVaultValue = OpaqueModuleValue
typealias SecretFieldTemplateVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_DOCUMENTS
typealias CredentialDocumentVaultValue = CredentialDocument
#else
typealias CredentialDocumentVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_BILLS
typealias BillRecordVaultValue = BillRecord
#else
typealias BillRecordVaultValue = OpaqueModuleValue
#endif

struct VaultData: Codable, @unchecked Sendable {
    var accounts: [BankAccountVaultValue] = []
    var cards: [BankCardVaultValue] = []
    var domesticBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = []
    var overseasBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = []
    var stocks: [StockHoldingVaultValue] = []
    var currencyExchangeRecords: [CurrencyExchangeVaultValue] = []
    var medicalRecords: [MedicalRecordVaultValue] = []
    var hospitalProfiles: [HospitalProfileVaultValue] = []
    var foodPlaces: [FoodPlaceVaultValue] = []
    var credentialDocuments: [CredentialDocumentVaultValue] = []
    var billRecords: [BillRecordVaultValue] = []
    var medicalRecordTags: [String] = []
    var foodPlaceTags: [String] = []
    var credentialTags: [String] = []
    var billTags: [String] = []
    var secretTags: [String] = []
    var currencyRateAlerts: [CurrencyRateAlert] = []
    var stockPriceAlerts: [StockPriceAlert] = []
    var secretFieldTemplates: [SecretFieldTemplateVaultValue] = []

    init(
        accounts: [BankAccountVaultValue] = [],
        cards: [BankCardVaultValue] = [],
        domesticBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = [],
        overseasBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = [],
        stocks: [StockHoldingVaultValue] = [],
        currencyExchangeRecords: [CurrencyExchangeVaultValue] = [],
        medicalRecords: [MedicalRecordVaultValue] = [],
        hospitalProfiles: [HospitalProfileVaultValue] = [],
        foodPlaces: [FoodPlaceVaultValue] = [],
        credentialDocuments: [CredentialDocumentVaultValue] = [],
        billRecords: [BillRecordVaultValue] = [],
        medicalRecordTags: [String] = [],
        foodPlaceTags: [String] = [],
        credentialTags: [String] = [],
        billTags: [String] = [],
        secretTags: [String] = [],
        currencyRateAlerts: [CurrencyRateAlert] = [],
        stockPriceAlerts: [StockPriceAlert] = [],
        secretFieldTemplates: [SecretFieldTemplateVaultValue] = []
    ) {
        self.accounts = accounts
        self.cards = cards
        self.domesticBankLoginFieldTemplates = domesticBankLoginFieldTemplates
        self.overseasBankLoginFieldTemplates = overseasBankLoginFieldTemplates
        self.stocks = stocks
        self.currencyExchangeRecords = currencyExchangeRecords
        self.medicalRecords = medicalRecords
        self.hospitalProfiles = hospitalProfiles
        self.foodPlaces = foodPlaces
        self.credentialDocuments = credentialDocuments
        self.billRecords = billRecords
        self.medicalRecordTags = medicalRecordTags
        self.foodPlaceTags = foodPlaceTags
        self.credentialTags = credentialTags
        self.billTags = billTags
        self.secretTags = secretTags
        self.currencyRateAlerts = currencyRateAlerts
        self.stockPriceAlerts = stockPriceAlerts
        self.secretFieldTemplates = secretFieldTemplates
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        case cards
        case domesticBankLoginFieldTemplates
        case overseasBankLoginFieldTemplates
        case stocks
        case currencyExchangeRecords
        case medicalRecords
        case hospitalProfiles
        case foodPlaces
        case credentialDocuments
        case billRecords
        case medicalRecordTags
        case foodPlaceTags
        case credentialTags
        case billTags
        case secretTags
        case currencyRateAlerts
        case stockPriceAlerts
        case secretFieldTemplates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([BankAccountVaultValue].self, forKey: .accounts) ?? []
        cards = try container.decodeIfPresent([BankCardVaultValue].self, forKey: .cards) ?? []
        domesticBankLoginFieldTemplates = try container.decodeIfPresent(
            [BankLoginFieldTemplateVaultValue].self,
            forKey: .domesticBankLoginFieldTemplates
        ) ?? []
        overseasBankLoginFieldTemplates = try container.decodeIfPresent(
            [BankLoginFieldTemplateVaultValue].self,
            forKey: .overseasBankLoginFieldTemplates
        ) ?? []
        stocks = try container.decodeIfPresent([StockHoldingVaultValue].self, forKey: .stocks) ?? []
        currencyExchangeRecords = try container.decodeIfPresent(
            [CurrencyExchangeVaultValue].self,
            forKey: .currencyExchangeRecords
        ) ?? []
        medicalRecords = try container.decodeIfPresent([MedicalRecordVaultValue].self, forKey: .medicalRecords) ?? []
        hospitalProfiles = try container.decodeIfPresent([HospitalProfileVaultValue].self, forKey: .hospitalProfiles) ?? []
        foodPlaces = try container.decodeIfPresent([FoodPlaceVaultValue].self, forKey: .foodPlaces) ?? []
        credentialDocuments = try container.decodeIfPresent(
            [CredentialDocumentVaultValue].self,
            forKey: .credentialDocuments
        ) ?? []
        billRecords = try container.decodeIfPresent([BillRecordVaultValue].self, forKey: .billRecords) ?? []
        medicalRecordTags = try container.decodeIfPresent([String].self, forKey: .medicalRecordTags) ?? []
        foodPlaceTags = try container.decodeIfPresent([String].self, forKey: .foodPlaceTags) ?? []
        credentialTags = try container.decodeIfPresent([String].self, forKey: .credentialTags) ?? []
        billTags = try container.decodeIfPresent([String].self, forKey: .billTags) ?? []
        secretTags = try container.decodeIfPresent([String].self, forKey: .secretTags) ?? []
        currencyRateAlerts = try container.decodeIfPresent(
            [CurrencyRateAlert].self,
            forKey: .currencyRateAlerts
        ) ?? []
        stockPriceAlerts = try container.decodeIfPresent(
            [StockPriceAlert].self,
            forKey: .stockPriceAlerts
        ) ?? []
        secretFieldTemplates = try container.decodeIfPresent(
            [SecretFieldTemplateVaultValue].self,
            forKey: .secretFieldTemplates
        ) ?? []
    }

    var currentCardCount: Int {
#if MYTOOLS_FEATURE_FINANCE
        cards.lazy.filter { $0.status != .closed }.count
#else
        0
#endif
    }

    var currentBankCount: Int {
#if MYTOOLS_FEATURE_FINANCE
        let cardsByAccountID = Dictionary(grouping: cards) { $0.accountID }
        return accounts.lazy.filter { account in
            let linkedCards = cardsByAccountID[account.id] ?? []
            return !account.isInactiveFinanceArchive(cards: linkedCards)
        }.count
#else
        return 0
#endif
    }

    var opaqueAttachmentStoredFileNames: Set<String> {
        var result = Set<String>()
#if !MYTOOLS_FEATURE_FINANCE
        result.formUnion(accounts.flatMap(\.attachmentStoredFileNames))
        result.formUnion(cards.flatMap(\.attachmentStoredFileNames))
#endif
#if !MYTOOLS_FEATURE_HEALTH
        result.formUnion(medicalRecords.flatMap(\.attachmentStoredFileNames))
        result.formUnion(hospitalProfiles.flatMap(\.attachmentStoredFileNames))
#endif
#if !MYTOOLS_FEATURE_FOOD_MAP
        result.formUnion(foodPlaces.flatMap(\.attachmentStoredFileNames))
#endif
#if !MYTOOLS_FEATURE_DOCUMENTS
        result.formUnion(credentialDocuments.flatMap(\.attachmentStoredFileNames))
#endif
        return result
    }
}
