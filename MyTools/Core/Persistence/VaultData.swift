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
        !storedFileName.isEmpty
      {
        result.insert(storedFileName)
      }
      return result
    case .null, .bool, .integer, .decimal, .string:
      return []
    }
  }
}

#if MYTOOLS_FEATURE_FINANCE
  typealias FinancialInstitutionVaultValue = FinancialInstitution
  typealias BankCardVaultValue = BankCard
  typealias BankLoginFieldTemplateVaultValue = BankLoginFieldTemplate
#else
  typealias FinancialInstitutionVaultValue = OpaqueModuleValue
  typealias BankCardVaultValue = OpaqueModuleValue
  typealias BankLoginFieldTemplateVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_STOCKS
  typealias StockHoldingVaultValue = StockHolding
  typealias StockCashFlowVaultValue = StockCashFlowRecord
#else
  typealias StockHoldingVaultValue = OpaqueModuleValue
  typealias StockCashFlowVaultValue = OpaqueModuleValue
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
  typealias CredentialFieldTemplateVaultValue = CredentialFieldTemplate
#else
  typealias CredentialDocumentVaultValue = OpaqueModuleValue
  typealias CredentialFieldTemplateVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_BILLS
  typealias BillRecordVaultValue = BillRecord
#else
  typealias BillRecordVaultValue = OpaqueModuleValue
#endif

#if MYTOOLS_FEATURE_PARTNERSHIP
  typealias PartnershipBookVaultValue = PartnershipBook
#else
  typealias PartnershipBookVaultValue = OpaqueModuleValue
#endif

extension CodingUserInfoKey {
  static let isolateVaultModules = CodingUserInfoKey(rawValue: "isolateVaultModules")!
}

struct VaultData: Codable, @unchecked Sendable {
  // Runtime quarantine, never encoded as normal empty module data.
  var unavailableModules: Set<String> = []
  var preservedModulePayloads: [String: OpaqueModuleValue] = [:]
  var preservedSecrets: OpaqueModuleValue?
  var unknownPayloads: [String: OpaqueModuleValue] = [:]

  // Missing historical keys mean "not configured". Present empty arrays
  // mean the user deliberately removed every template, including on sync.
  static var defaultDomesticBankTemplates: [BankLoginFieldTemplateVaultValue] {
    #if MYTOOLS_FEATURE_FINANCE
      BankLoginFieldTemplate.domesticDefaults
    #else
      []
    #endif
  }
  static var defaultOverseasBankTemplates: [BankLoginFieldTemplateVaultValue] {
    #if MYTOOLS_FEATURE_FINANCE
      BankLoginFieldTemplate.overseasDefaults
    #else
      []
    #endif
  }
  var financialInstitutions: [FinancialInstitutionVaultValue] = []
  #if MYTOOLS_FEATURE_FINANCE
  var cards: [BankCard] {
    get { financialInstitutions.flatMap(\.cards) }
    set {
      for i in financialInstitutions.indices { financialInstitutions[i].cards = newValue.filter { $0.accountID == financialInstitutions[i].id } }
    }
  }
  #else
  var cards: [OpaqueModuleValue] { get { [] } set {} }
  #endif
  var domesticBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = []
  var overseasBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = []
  var stocks: [StockHoldingVaultValue] = []
  var stockCashFlowRecords: [StockCashFlowVaultValue] = []
  var currencyExchangeRecords: [CurrencyExchangeVaultValue] = []
  var medicalRecords: [MedicalRecordVaultValue] = []
  var hospitalProfiles: [HospitalProfileVaultValue] = []
  var foodPlaces: [FoodPlaceVaultValue] = []
  var credentialDocuments: [CredentialDocumentVaultValue] = []
  var credentialFieldTemplates: [CredentialFieldTemplateVaultValue] = []
  var billRecords: [BillRecordVaultValue] = []
  var partnershipBooks: [PartnershipBookVaultValue] = []
  var medicalRecordTags: [String] = []
  var foodPlaceTags: [String] = []
  var credentialTags: [String] = []
  var billTags: [String] = []
  var secretTags: [String] = []
  var currencyRateAlerts: [CurrencyRateAlert] = []
  var stockPriceAlerts: [StockPriceAlert] = []
  var stockReturnAlerts: [StockReturnAlert] = []
  var secretFieldTemplates: [SecretFieldTemplateVaultValue] = []

  init(
    financialInstitutions: [FinancialInstitutionVaultValue] = [],
    domesticBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = VaultData
      .defaultDomesticBankTemplates,
    overseasBankLoginFieldTemplates: [BankLoginFieldTemplateVaultValue] = VaultData
      .defaultOverseasBankTemplates,
    stocks: [StockHoldingVaultValue] = [],
    stockCashFlowRecords: [StockCashFlowVaultValue] = [],
    currencyExchangeRecords: [CurrencyExchangeVaultValue] = [],
    medicalRecords: [MedicalRecordVaultValue] = [],
    hospitalProfiles: [HospitalProfileVaultValue] = [],
    foodPlaces: [FoodPlaceVaultValue] = [],
    credentialDocuments: [CredentialDocumentVaultValue] = [],
    credentialFieldTemplates: [CredentialFieldTemplateVaultValue] = [],
    billRecords: [BillRecordVaultValue] = [],
    partnershipBooks: [PartnershipBookVaultValue] = [],
    medicalRecordTags: [String] = [],
    foodPlaceTags: [String] = [],
    credentialTags: [String] = [],
    billTags: [String] = [],
    secretTags: [String] = [],
    currencyRateAlerts: [CurrencyRateAlert] = [],
    stockPriceAlerts: [StockPriceAlert] = [],
    stockReturnAlerts: [StockReturnAlert] = [],
    secretFieldTemplates: [SecretFieldTemplateVaultValue] = []
  ) {
    self.financialInstitutions = financialInstitutions
    self.domesticBankLoginFieldTemplates = domesticBankLoginFieldTemplates
    self.overseasBankLoginFieldTemplates = overseasBankLoginFieldTemplates
    self.stocks = stocks
    self.stockCashFlowRecords = stockCashFlowRecords
    self.currencyExchangeRecords = currencyExchangeRecords
    self.medicalRecords = medicalRecords
    self.hospitalProfiles = hospitalProfiles
    self.foodPlaces = foodPlaces
    self.credentialDocuments = credentialDocuments
    self.credentialFieldTemplates = credentialFieldTemplates
    self.billRecords = billRecords
    self.partnershipBooks = partnershipBooks
    self.medicalRecordTags = medicalRecordTags
    self.foodPlaceTags = foodPlaceTags
    self.credentialTags = credentialTags
    self.billTags = billTags
    self.secretTags = secretTags
    self.currencyRateAlerts = currencyRateAlerts
    self.stockPriceAlerts = stockPriceAlerts
    self.stockReturnAlerts = stockReturnAlerts
    self.secretFieldTemplates = secretFieldTemplates
  }

  #if MYTOOLS_FEATURE_FINANCE
  init(accounts: [FinancialInstitution] = [], cards: [BankCard] = [], stocks: [StockHoldingVaultValue] = [], medicalRecords: [MedicalRecordVaultValue] = [], billRecords: [BillRecordVaultValue] = []) {
    self.init(financialInstitutions: accounts.map { value in
      var copy = value; copy.cards = cards.filter { $0.accountID == value.id }; return copy
    }, stocks: stocks, medicalRecords: medicalRecords, billRecords: billRecords)
  }
  #endif

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case financialInstitutions
    case domesticBankLoginFieldTemplates
    case overseasBankLoginFieldTemplates
    case stocks
    case stockCashFlowRecords
    case currencyExchangeRecords
    case medicalRecords
    case hospitalProfiles
    case foodPlaces
    case credentialDocuments
    case credentialFieldTemplates
    case billRecords
    case partnershipBooks
    case medicalRecordTags
    case foodPlaceTags
    case credentialTags
    case billTags
    case secretTags
    case currencyRateAlerts
    case stockPriceAlerts
    case stockReturnAlerts
    case secretFieldTemplates
  }

  private struct PayloadKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
  }

  init(from decoder: Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try decoder.container(keyedBy: PayloadKey.self)
    let isolate = decoder.userInfo[.isolateVaultModules] as? Bool == true
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    for key in raw.allKeys where !known.contains(key.stringValue) {
      unknownPayloads[key.stringValue] = try raw.decode(OpaqueModuleValue.self, forKey: key)
    }
    do {
      guard !raw.contains(PayloadKey("accounts")), !raw.contains(PayloadKey("financialProviders")) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Finance requires the converted schema 3 backup."))
      }
      financialInstitutions = try container.decodeIfPresent([FinancialInstitutionVaultValue].self, forKey: .financialInstitutions) ?? []
      domesticBankLoginFieldTemplates =
        try container.decodeIfPresent(
          [BankLoginFieldTemplateVaultValue].self,
          forKey: .domesticBankLoginFieldTemplates
        ) ?? Self.defaultDomesticBankTemplates
      overseasBankLoginFieldTemplates =
        try container.decodeIfPresent(
          [BankLoginFieldTemplateVaultValue].self,
          forKey: .overseasBankLoginFieldTemplates
        ) ?? Self.defaultOverseasBankTemplates
      #if MYTOOLS_FEATURE_FINANCE
        guard Set(financialInstitutions.map(\.id)).count == financialInstitutions.count else { throw FinancialArchiveError.invalidRelationships }
        for index in financialInstitutions.indices {
          financialInstitutions[index].normalizePaymentReceivingProfiles()
          try financialInstitutions[index].validate()
        }
        guard Set(cards.map(\.id)).count == cards.count else { throw FinancialArchiveError.invalidRelationships }
      #endif
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("personalFinance")
      financialInstitutions = []
      domesticBankLoginFieldTemplates = []
      overseasBankLoginFieldTemplates = []
      for key in [
        "financialInstitutions", "accounts", "cards", "financialProviders",
        "domesticBankLoginFieldTemplates", "overseasBankLoginFieldTemplates",
      ] where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      stocks = try container.decodeIfPresent([StockHoldingVaultValue].self, forKey: .stocks) ?? []
      stockCashFlowRecords =
        try container.decodeIfPresent(
          [StockCashFlowVaultValue].self,
          forKey: .stockCashFlowRecords
        ) ?? []
      stockPriceAlerts =
        try container.decodeIfPresent(
          [StockPriceAlert].self,
          forKey: .stockPriceAlerts
        ) ?? []
      stockReturnAlerts =
        try container.decodeIfPresent(
          [StockReturnAlert].self,
          forKey: .stockReturnAlerts
        ) ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("myStocks")
      stocks = []
      stockCashFlowRecords = []
      stockPriceAlerts = []
      stockReturnAlerts = []
      for key in ["stocks", "stockCashFlowRecords", "stockPriceAlerts", "stockReturnAlerts"]
      where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      currencyExchangeRecords =
        try container.decodeIfPresent(
          [CurrencyExchangeVaultValue].self,
          forKey: .currencyExchangeRecords
        ) ?? []
      currencyRateAlerts =
        try container.decodeIfPresent(
          [CurrencyRateAlert].self,
          forKey: .currencyRateAlerts
        ) ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("currencyExchange")
      currencyExchangeRecords = []
      currencyRateAlerts = []
      for key in ["currencyExchangeRecords", "currencyRateAlerts"]
      where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      medicalRecords =
        try container.decodeIfPresent([MedicalRecordVaultValue].self, forKey: .medicalRecords) ?? []
      hospitalProfiles =
        try container.decodeIfPresent([HospitalProfileVaultValue].self, forKey: .hospitalProfiles)
        ?? []
      medicalRecordTags =
        try container.decodeIfPresent([String].self, forKey: .medicalRecordTags) ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("healthRecords")
      medicalRecords = []
      hospitalProfiles = []
      medicalRecordTags = []
      for key in ["medicalRecords", "hospitalProfiles", "medicalRecordTags"]
      where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      foodPlaces =
        try container.decodeIfPresent([FoodPlaceVaultValue].self, forKey: .foodPlaces) ?? []
      foodPlaceTags = try container.decodeIfPresent([String].self, forKey: .foodPlaceTags) ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("foodMap")
      foodPlaces = []
      foodPlaceTags = []
      for key in ["foodPlaces", "foodPlaceTags"] where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      credentialDocuments =
        try container.decodeIfPresent(
          [CredentialDocumentVaultValue].self,
          forKey: .credentialDocuments
        ) ?? []
      credentialFieldTemplates =
        try container.decodeIfPresent(
          [CredentialFieldTemplateVaultValue].self,
          forKey: .credentialFieldTemplates
        ) ?? []
      credentialTags = try container.decodeIfPresent([String].self, forKey: .credentialTags) ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("documents")
      credentialDocuments = []
      credentialFieldTemplates = []
      credentialTags = []
      for key in ["credentialDocuments", "credentialFieldTemplates", "credentialTags"]
      where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      billRecords =
        try container.decodeIfPresent([BillRecordVaultValue].self, forKey: .billRecords) ?? []
      billTags = try container.decodeIfPresent([String].self, forKey: .billTags) ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("bills")
      billRecords = []
      billTags = []
      for key in ["billRecords", "billTags"] where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      partnershipBooks =
        try container.decodeIfPresent([PartnershipBookVaultValue].self, forKey: .partnershipBooks)
        ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("partnership")
      partnershipBooks = []
      for key in ["partnershipBooks"] where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
    do {
      secretTags = try container.decodeIfPresent([String].self, forKey: .secretTags) ?? []
      secretFieldTemplates =
        try container.decodeIfPresent(
          [SecretFieldTemplateVaultValue].self,
          forKey: .secretFieldTemplates
        ) ?? []
    } catch {
      guard isolate else { throw error }
      unavailableModules.insert("secrets")
      secretTags = []
      secretFieldTemplates = []
      for key in ["secretTags", "secretFieldTemplates"] where raw.contains(PayloadKey(key)) {
        preservedModulePayloads[key] = try raw.decode(
          OpaqueModuleValue.self, forKey: PayloadKey(key))
      }
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let raw = preservedModulePayloads["financialInstitutions"] {
      try container.encode(raw, forKey: .financialInstitutions)
    } else {
      try container.encode(financialInstitutions, forKey: .financialInstitutions)
    }
    if let raw = preservedModulePayloads["domesticBankLoginFieldTemplates"] {
      try container.encode(raw, forKey: .domesticBankLoginFieldTemplates)
    } else if !unavailableModules.contains("personalFinance") {
      try container.encode(
        domesticBankLoginFieldTemplates, forKey: .domesticBankLoginFieldTemplates)
    }
    if let raw = preservedModulePayloads["overseasBankLoginFieldTemplates"] {
      try container.encode(raw, forKey: .overseasBankLoginFieldTemplates)
    } else if !unavailableModules.contains("personalFinance") {
      try container.encode(
        overseasBankLoginFieldTemplates, forKey: .overseasBankLoginFieldTemplates)
    }
    if let raw = preservedModulePayloads["stocks"] {
      try container.encode(raw, forKey: .stocks)
    } else if !unavailableModules.contains("myStocks") {
      try container.encode(stocks, forKey: .stocks)
    }
    if let raw = preservedModulePayloads["stockCashFlowRecords"] {
      try container.encode(raw, forKey: .stockCashFlowRecords)
    } else if !unavailableModules.contains("myStocks") {
      try container.encode(stockCashFlowRecords, forKey: .stockCashFlowRecords)
    }
    if let raw = preservedModulePayloads["stockPriceAlerts"] {
      try container.encode(raw, forKey: .stockPriceAlerts)
    } else if !unavailableModules.contains("myStocks") {
      try container.encode(stockPriceAlerts, forKey: .stockPriceAlerts)
    }
    if let raw = preservedModulePayloads["stockReturnAlerts"] {
      try container.encode(raw, forKey: .stockReturnAlerts)
    } else if !unavailableModules.contains("myStocks") {
      try container.encode(stockReturnAlerts, forKey: .stockReturnAlerts)
    }
    if let raw = preservedModulePayloads["currencyExchangeRecords"] {
      try container.encode(raw, forKey: .currencyExchangeRecords)
    } else if !unavailableModules.contains("currencyExchange") {
      try container.encode(currencyExchangeRecords, forKey: .currencyExchangeRecords)
    }
    if let raw = preservedModulePayloads["currencyRateAlerts"] {
      try container.encode(raw, forKey: .currencyRateAlerts)
    } else if !unavailableModules.contains("currencyExchange") {
      try container.encode(currencyRateAlerts, forKey: .currencyRateAlerts)
    }
    if let raw = preservedModulePayloads["medicalRecords"] {
      try container.encode(raw, forKey: .medicalRecords)
    } else if !unavailableModules.contains("healthRecords") {
      try container.encode(medicalRecords, forKey: .medicalRecords)
    }
    if let raw = preservedModulePayloads["hospitalProfiles"] {
      try container.encode(raw, forKey: .hospitalProfiles)
    } else if !unavailableModules.contains("healthRecords") {
      try container.encode(hospitalProfiles, forKey: .hospitalProfiles)
    }
    if let raw = preservedModulePayloads["medicalRecordTags"] {
      try container.encode(raw, forKey: .medicalRecordTags)
    } else if !unavailableModules.contains("healthRecords") {
      try container.encode(medicalRecordTags, forKey: .medicalRecordTags)
    }
    if let raw = preservedModulePayloads["foodPlaces"] {
      try container.encode(raw, forKey: .foodPlaces)
    } else if !unavailableModules.contains("foodMap") {
      try container.encode(foodPlaces, forKey: .foodPlaces)
    }
    if let raw = preservedModulePayloads["foodPlaceTags"] {
      try container.encode(raw, forKey: .foodPlaceTags)
    } else if !unavailableModules.contains("foodMap") {
      try container.encode(foodPlaceTags, forKey: .foodPlaceTags)
    }
    if let raw = preservedModulePayloads["credentialDocuments"] {
      try container.encode(raw, forKey: .credentialDocuments)
    } else if !unavailableModules.contains("documents") {
      try container.encode(credentialDocuments, forKey: .credentialDocuments)
    }
    if let raw = preservedModulePayloads["credentialFieldTemplates"] {
      try container.encode(raw, forKey: .credentialFieldTemplates)
    } else if !unavailableModules.contains("documents") {
      try container.encode(credentialFieldTemplates, forKey: .credentialFieldTemplates)
    }
    if let raw = preservedModulePayloads["credentialTags"] {
      try container.encode(raw, forKey: .credentialTags)
    } else if !unavailableModules.contains("documents") {
      try container.encode(credentialTags, forKey: .credentialTags)
    }
    if let raw = preservedModulePayloads["billRecords"] {
      try container.encode(raw, forKey: .billRecords)
    } else if !unavailableModules.contains("bills") {
      try container.encode(billRecords, forKey: .billRecords)
    }
    if let raw = preservedModulePayloads["billTags"] {
      try container.encode(raw, forKey: .billTags)
    } else if !unavailableModules.contains("bills") {
      try container.encode(billTags, forKey: .billTags)
    }
    if let raw = preservedModulePayloads["partnershipBooks"] {
      try container.encode(raw, forKey: .partnershipBooks)
    } else if !unavailableModules.contains("partnership") {
      try container.encode(partnershipBooks, forKey: .partnershipBooks)
    }
    if let raw = preservedModulePayloads["secretTags"] {
      try container.encode(raw, forKey: .secretTags)
    } else if !unavailableModules.contains("secrets") {
      try container.encode(secretTags, forKey: .secretTags)
    }
    if let raw = preservedModulePayloads["secretFieldTemplates"] {
      try container.encode(raw, forKey: .secretFieldTemplates)
    } else if !unavailableModules.contains("secrets") {
      try container.encode(secretFieldTemplates, forKey: .secretFieldTemplates)
    }
    var extras = encoder.container(keyedBy: PayloadKey.self)
    for (key, value) in unknownPayloads { try extras.encode(value, forKey: PayloadKey(key)) }
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
      return financialInstitutions.lazy.filter { account in
        let linkedCards = cardsByAccountID[account.id] ?? []
        return !account.isInactiveFinanceArchive(cards: linkedCards)
      }.count
    #else
      return 0
    #endif
  }

  var opaqueAttachmentStoredFileNames: Set<String> {
    var result = Set(preservedModulePayloads.values.flatMap(\.attachmentStoredFileNames))
    result.formUnion(unknownPayloads.values.flatMap(\.attachmentStoredFileNames))
    result.formUnion(preservedSecrets?.attachmentStoredFileNames ?? [])
    #if !MYTOOLS_FEATURE_FINANCE
      result.formUnion(financialInstitutions.flatMap(\.attachmentStoredFileNames))
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
