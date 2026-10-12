#if MYTOOLS_FEATURE_FINANCE
import Foundation

enum FinancialInstitutionKind: String, Codable, CaseIterable, Identifiable {
    case bank, brokerage, payment, other
    var id: Self { self }
    var title: String { switch self { case .bank: "银行"; case .brokerage: "券商"; case .payment: "支付机构"; case .other: "其他" } }
}

/// Single aggregate root. Typed payloads contain only the corresponding business facts.
struct FinancialInstitution: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 3
    var schemaVersion = Self.currentSchemaVersion
    var id = UUID()
    var name = ""
    var kind: FinancialInstitutionKind = .bank
    var customKind = ""
    var country = ""
    var website = ""
    var phone = ""
    var note = ""
    var bank: BankInstitutionDetails? = BankInstitutionDetails()
    var brokerage: BrokerageInstitutionDetails?
    var payment: PaymentInstitutionDetails?
    var other: OtherFinancialInstitutionDetails?
    var logins: [FinanceLogin] = []
    var documents: [FinanceDocument] = []
    var fields: [AdditionalLoginField] = []

    init(kind: FinancialInstitutionKind = .bank) {
        self.kind = kind
        bank = kind == .bank ? BankInstitutionDetails() : nil
        brokerage = kind == .brokerage ? BrokerageInstitutionDetails() : nil
        payment = kind == .payment ? PaymentInstitutionDetails() : nil
        other = kind == .other ? OtherFinancialInstitutionDetails() : nil
    }

    /// Moves the pre-v3 payment shape (institution-level receivingMethods) into
    /// the one-to-one account.receivingProfile relation. Orphaned profiles are
    /// dropped only after the account set has been validated; they cannot remain
    /// hidden in the payload and later reappear after reinstall.
    mutating func normalizePaymentReceivingProfiles() {
        guard kind == .payment, var details = payment else { return }
        var values = details.accounts
        for profile in details.receivingMethods {
            guard let index = values.firstIndex(where: { $0.id == profile.accountID }) else { continue }
            if values[index].receivingProfile == nil { values[index].receivingProfile = profile }
        }
        details.accounts = values
        details.receivingMethods = []
        payment = details
    }
    /// In-memory adapter used by older fixtures; this is never encoded as a
    /// separate persisted field.
    var financialProfile: FinancialInstitution? {
        get { self }
        set { if let newValue { self = newValue } }
    }
    var boundPhoneNumber: String {
        get { additionalLoginFields.first(where: { $0.name == "绑定手机号" })?.value ?? "" }
        set { upsertCompatibilityField(name: "绑定手机号", value: newValue, sensitive: false) }
    }
    var loginAccount: String {
        get { additionalLoginFields.first(where: { $0.name == "登录账号" })?.value ?? "" }
        set { upsertCompatibilityField(name: "登录账号", value: newValue, sensitive: false) }
    }
    var loginPassword: String {
        get { additionalLoginFields.first(where: { $0.name == "登录密码" })?.value ?? "" }
        set { upsertCompatibilityField(name: "登录密码", value: newValue, sensitive: true) }
    }
    private mutating func upsertCompatibilityField(name: String, value: String, sensitive: Bool) {
        var fields = additionalLoginFields
        if let index = fields.firstIndex(where: { $0.name == name }) { fields[index].value = value; fields[index].isSensitive = sensitive }
        else if !value.isEmpty { fields.append(AdditionalLoginField(name: name, value: value, isSensitive: sensitive)) }
        additionalLoginFields = fields
    }
    var services: Set<FinanceService> { switch kind { case .bank: [.banking]; case .brokerage: [.securities]; case .payment: [.payments]; case .other: [.other] } }
    var serviceSummary: String { kind == .other && !customKind.isEmpty ? customKind : kind.title }
    var accounts: [FinancialAccount] {
        get { bank?.accounts ?? [] }
        set { bank?.accounts = newValue }
    }
    var bankAccounts: [FinancialAccount] {
        get { bank?.accounts ?? [] }
        set { bank?.accounts = newValue }
    }
    var brokerageAccounts: [BrokerageAccount] {
        get { brokerage?.accounts ?? [] }
        set { brokerage?.accounts = newValue }
    }
    var paymentAccounts: [PaymentAccount] {
        get { payment?.accounts ?? [] }
        set { payment?.accounts = newValue }
    }
    var receivingMethods: [FinanceReceivingMethod] {
        get {
            switch kind {
            case .bank: bank?.receivingMethods ?? []
            case .brokerage: brokerage?.fundingMethods ?? []
            case .payment: paymentAccounts.compactMap(\.receivingProfile)
            case .other: other?.receivingMethods ?? []
            }
        }
        set {
            switch kind {
            case .bank: bank?.receivingMethods = newValue
            case .brokerage: brokerage?.fundingMethods = newValue
            case .payment:
                var values = paymentAccounts
                for index in values.indices {
                    values[index].receivingProfile = newValue.first { $0.accountID == values[index].id }
                }
                paymentAccounts = values
            case .other: other?.receivingMethods = newValue
            }
        }
    }
    var cards: [BankCard] { get { bank?.cards ?? [] } set { bank?.cards = newValue } }
    var region: BankRegion { get { bank?.region ?? .domestic } set { bank?.region = newValue } }
    var loginTemplateRegion: BankRegion { get { region } set { region = newValue } }
    var branchName: String { get { bank?.branchName ?? "" } set { bank?.branchName = newValue } }
    var branchLocation: BankBranchLocation? { get { bank?.branchLocation ?? nil } set { bank?.branchLocation = newValue } }
    var isOnlineBank: Bool { get { bank?.isOnlineBank ?? false } set { bank?.isOnlineBank = newValue } }
    var openedAt: Date? { get { bank?.openedAt ?? nil } set { bank?.openedAt = newValue } }
    var correspondenceAddressChinese: String { get { bank?.correspondenceAddressChinese ?? "" } set { bank?.correspondenceAddressChinese = newValue } }
    var correspondenceAddressEnglish: String { get { bank?.correspondenceAddressEnglish ?? "" } set { bank?.correspondenceAddressEnglish = newValue } }
    var residentialAddressChinese: String { get { bank?.residentialAddressChinese ?? "" } set { bank?.residentialAddressChinese = newValue } }
    var residentialAddressEnglish: String { get { bank?.residentialAddressEnglish ?? "" } set { bank?.residentialAddressEnglish = newValue } }
    var financeAttachments: [FileAttachment] { documents.map(\.attachment) + cards.flatMap(\.statements).compactMap(\.attachment) }
    // Bank presentation adapters use the same canonical account collection.
    // No legacy envelope or duplicate subaccount payload is persisted.
    var bankName: String { get { name } set { name = newValue } }
    var status: AccountStatus { get { bank?.status ?? .normal } set { bank?.status = newValue } }
    var domesticSubaccounts: [DomesticSubaccount] {
        get { accounts.filter { ($0.bankRegion ?? region) == .domestic }.map { DomesticSubaccount(id: $0.id, type: $0.typeTitle, name: $0.name, accountNumber: $0.accountNumber, currencies: $0.currencies, status: $0.status) } }
        set {
            let old = accounts
            let updated = newValue.map { input -> FinancialAccount in
                var value = old.first { $0.id == input.id } ?? FinancialAccount()
                value.id = input.id; value.bankRegion = .domestic
                value.kind = FinanceAccountKind.allCases.first { $0.title == input.type } ?? .other
                value.customType = value.kind == .other ? input.type : ""
                value.name = input.name; value.accountNumber = input.accountNumber
                value.currencies = input.currencies; value.status = input.status
                return value
            }
            accounts = old.filter { ($0.bankRegion ?? region) != .domestic } + updated
        }
    }
    var foreignSubaccounts: [ForeignSubaccount] {
        get { accounts.filter { ($0.bankRegion ?? region) == .overseas }.map { value in
            let kind = ForeignAccountType.allCases.first { $0.title == value.typeTitle } ?? .other
            return ForeignSubaccount(id: value.id, type: kind, name: value.name, accountNumber: value.accountNumber, currencies: value.currencies, status: value.status, customType: kind == .other ? value.typeTitle : nil)
        } }
        set {
            let old = accounts
            let updated = newValue.map { input -> FinancialAccount in
                var value = old.first { $0.id == input.id } ?? FinancialAccount()
                value.id = input.id; value.bankRegion = .overseas
                value.kind = FinanceAccountKind.allCases.first { $0.title == input.typeTitle } ?? .other
                value.customType = value.kind == .other ? input.typeTitle : ""
                value.name = input.name; value.accountNumber = input.accountNumber
                value.currencies = input.currencies; value.status = input.status
                return value
            }
            accounts = old.filter { ($0.bankRegion ?? region) != .overseas } + updated
        }
    }
    var additionalLoginFields: [AdditionalLoginField] {
        get { logins.flatMap(\.fields) }
        set {
            var groups = logins
            var remaining = newValue
            for i in groups.indices {
                let ids = Set(groups[i].fields.map(\.id))
                groups[i].fields = remaining.filter { ids.contains($0.id) }
                remaining.removeAll { ids.contains($0.id) }
            }
            if !remaining.isEmpty {
                if groups.isEmpty { groups.append(FinanceLogin(id: id)) }
                groups[0].fields += remaining
            }
            logins = groups
        }
    }
    var activeSubaccountCount: Int { region == .domestic ? domesticSubaccounts.filter { $0.status != .closed }.count : foreignSubaccounts.filter { $0.status != .closed }.count }
    var closedSubaccountCount: Int { region == .domestic ? domesticSubaccounts.filter { $0.status == .closed }.count : foreignSubaccounts.filter { $0.status == .closed }.count }
    var swift: String { get { bank?.swift ?? "" } set { bank?.swift = newValue } }
    var iban: String { get { bank?.iban ?? "" } set { bank?.iban = newValue } }
    var remittanceBankName: String { get { bank?.remittanceBankName ?? "" } set { bank?.remittanceBankName = newValue } }
    var remittanceBankAddress: String { get { bank?.remittanceBankAddress ?? "" } set { bank?.remittanceBankAddress = newValue } }
    var remittanceInstructions: String { get { bank?.remittanceInstructions ?? "" } set { bank?.remittanceInstructions = newValue } }
    var allAccounts: [FinancialAccount] { bankAccounts.flatMap { [$0] + $0.subaccounts } }
    func isInactiveFinanceArchive(cards: [BankCard]) -> Bool {
        if kind == .bank {
            let activeSubaccount = region == .domestic
                ? domesticSubaccounts.contains { $0.status == .normal }
                : foreignSubaccounts.contains { $0.status == .normal }
            return !cards.contains { $0.status != .closed }
                && !activeSubaccount && (!cards.isEmpty || status != .normal)
        }
        return (!allAccounts.isEmpty || !cards.isEmpty) && allAccounts.allSatisfy { $0.status == .closed } && cards.allSatisfy { $0.status == .closed }
    }
    func matches(_ query: String) -> Bool {
        query.isEmpty || ([name, serviceSummary, country, note] + allAccounts.flatMap { [$0.name, $0.typeTitle, $0.accountNumber, $0.holderName, $0.currencySummary] } + brokerageAccounts.flatMap { [$0.name, $0.accountNumber, $0.baseCurrency.rawValue] } + paymentAccounts.flatMap { [$0.name, $0.accountNumber, $0.currencySummary] } + receivingMethods.map { $0.details.displayName }).contains { $0.localizedCaseInsensitiveContains(query) }
    }
    mutating func removeAccount(id: UUID) {
        var values = accounts
        let removedIDs = Set(values.filter { $0.id == id }.flatMap { [$0.id] + $0.subaccounts.map(\.id) } + [id])
        values.removeAll { $0.id == id }
        for i in values.indices { values[i].subaccounts.removeAll { $0.id == id } }
        accounts = values
        var routes = receivingMethods
        for i in routes.indices where routes[i].accountID.map(removedIDs.contains) == true { routes[i].accountID = nil }
        receivingMethods = routes
        for i in logins.indices { logins[i].accountIDs.subtract(removedIDs) }
        for i in documents.indices where documents[i].accountID.map(removedIDs.contains) == true { documents[i].accountID = nil }
        var valuesCards = cards
        for i in valuesCards.indices { valuesCards[i].linkedFinancialAccountIDs?.subtract(removedIDs) }
        cards = valuesCards
        if kind == .payment { normalizePaymentReceivingProfiles() }
    }
    mutating func removeReceivingMethod(id: UUID) {
        var values = receivingMethods
        values.removeAll { $0.id == id }; receivingMethods = values
        for i in documents.indices where documents[i].receivingMethodID == id { documents[i].receivingMethodID = nil }
    }
    func validate(cards: [BankCard]) throws {
        var value = self; value.cards = cards; try value.validate()
    }
    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw FinancialArchiveError.unsupportedVersion }
        guard (bank != nil) == (kind == .bank), (brokerage != nil) == (kind == .brokerage), (payment != nil) == (kind == .payment), (other != nil) == (kind == .other) else { throw FinancialArchiveError.wrongCategory }
        let accountIDs = Set(allAccounts.map(\.id) + brokerageAccounts.map(\.id) + paymentAccounts.map(\.id)), routeIDs = Set(receivingMethods.map(\.id)), cardIDs = Set(cards.map(\.id))
        let allAccountIDs = allAccounts.map(\.id) + brokerageAccounts.map(\.id) + paymentAccounts.map(\.id)
        guard accountIDs.count == allAccountIDs.count, routeIDs.count == receivingMethods.count,
              Set(logins.map(\.id)).count == logins.count, Set(documents.map(\.id)).count == documents.count,
              allAccounts.allSatisfy({ $0.subaccounts.allSatisfy { $0.subaccounts.isEmpty } }),
              receivingMethods.allSatisfy({ ($0.accountID.map(accountIDs.contains) ?? true) && Set($0.details.fields.map(\.id)).count == $0.details.fields.count }),
              paymentAccounts.allSatisfy({ account in account.receivingProfile.map { profile in profile.accountID == account.id && Set(profile.details.fields.map(\.id)).count == profile.details.fields.count } ?? true }),
              logins.allSatisfy({ $0.accountIDs.isSubset(of: accountIDs) && Set($0.fields.map(\.id)).count == $0.fields.count }),
              documents.allSatisfy({ ($0.accountID.map(accountIDs.contains) ?? true) && ($0.receivingMethodID.map(routeIDs.contains) ?? true) }),
              cardIDs.count == cards.count, cards.allSatisfy({ $0.accountID == id && ($0.linkedFinancialAccountIDs ?? []).isSubset(of: accountIDs) && ($0.replacedByCardID.map(cardIDs.contains) ?? true) && Set($0.additionalCredentials.map(\.id)).count == $0.additionalCredentials.count })
        else { throw FinancialArchiveError.invalidRelationships }
        let replacements = Dictionary(uniqueKeysWithValues: cards.compactMap { card in card.replacedByCardID.map { (card.id, $0) } })
        for card in cards { var seen: Set<UUID> = [card.id]; var next = replacements[card.id]; while let id = next { guard seen.insert(id).inserted else { throw FinancialArchiveError.invalidRelationships }; next = replacements[id] } }
    }
}

struct BankInstitutionDetails: Codable, Equatable {
    var status: AccountStatus?
    var region: BankRegion = .domestic
    var branchName = ""
    var branchLocation: BankBranchLocation?
    var isOnlineBank = false
    var openedAt: Date?
    var correspondenceAddressChinese = ""
    var correspondenceAddressEnglish = ""
    var residentialAddressChinese = ""
    var residentialAddressEnglish = ""
    var swift: String?
    var iban: String?
    var remittanceBankName: String?
    var remittanceBankAddress: String?
    var remittanceInstructions: String?
    var accounts: [FinancialAccount] = []
    var cards: [BankCard] = []
    var receivingMethods: [FinanceReceivingMethod] = []
}
#endif
