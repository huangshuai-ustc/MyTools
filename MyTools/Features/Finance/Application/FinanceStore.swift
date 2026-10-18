#if MYTOOLS_FEATURE_FINANCE
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FinanceStore: ObservableObject, ModuleDataCleanupParticipant, AttachmentManaging {
    @Published private(set) var financialInstitutions: [FinancialInstitution]
    @Published private(set) var domesticLoginFieldTemplates: [BankLoginFieldTemplate]
    @Published private(set) var overseasLoginFieldTemplates: [BankLoginFieldTemplate]
    let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?
    var cleanupModule: ToolModule { .personalFinance }
    var cards: [BankCard] { financialInstitutions.flatMap(\.cards) }
    var currentCardCount: Int { cards.filter { $0.status != .closed }.count }
    var currentBankCount: Int { financialInstitutions.filter { !$0.isInactiveFinanceArchive(cards: $0.cards) }.count }

    init(financialInstitutions: [FinancialInstitution] = [], domesticLoginFieldTemplates: [BankLoginFieldTemplate] = BankLoginFieldTemplate.domesticDefaults, overseasLoginFieldTemplates: [BankLoginFieldTemplate] = BankLoginFieldTemplate.overseasDefaults, attachmentStore: AttachmentStore) {
        self.financialInstitutions = financialInstitutions.map { value in var value = value; value.normalizePaymentReceivingProfiles(); return value }
        self.domesticLoginFieldTemplates = Self.normalizedTemplates(domesticLoginFieldTemplates)
        self.overseasLoginFieldTemplates = Self.normalizedTemplates(overseasLoginFieldTemplates)
        self.attachmentStore = attachmentStore
    }
    convenience init(accounts: [FinancialInstitution] = [], cards: [BankCard] = [], domesticLoginFieldTemplates: [BankLoginFieldTemplate] = BankLoginFieldTemplate.domesticDefaults, overseasLoginFieldTemplates: [BankLoginFieldTemplate] = BankLoginFieldTemplate.overseasDefaults, attachmentStore: AttachmentStore) {
        var values = accounts
        for i in values.indices { values[i].cards = cards.filter { $0.accountID == values[i].id } }
        self.init(financialInstitutions: values, domesticLoginFieldTemplates: domesticLoginFieldTemplates, overseasLoginFieldTemplates: overseasLoginFieldTemplates, attachmentStore: attachmentStore)
    }
    func attach(mutationNotifier: any VaultMutationNotifying) { self.mutationNotifier = mutationNotifier }
    func replace(financialInstitutions: [FinancialInstitution], domesticLoginFieldTemplates: [BankLoginFieldTemplate], overseasLoginFieldTemplates: [BankLoginFieldTemplate]) {
        self.financialInstitutions = financialInstitutions.map { value in var value = value; value.normalizePaymentReceivingProfiles(); return value }
        self.domesticLoginFieldTemplates = Self.normalizedTemplates(domesticLoginFieldTemplates)
        self.overseasLoginFieldTemplates = Self.normalizedTemplates(overseasLoginFieldTemplates)
    }
    func scanRedundantData() -> [RedundantDataFinding] {
        var findings: [RedundantDataFinding] = []
        appendFinding(
            to: &findings,
            ruleID: "non-custom-account-type",
            title: "非自定义账户类型的类型名称",
            detail: "账户类型不是“其他”时不会显示自定义类型名称。",
            items: financialInstitutions.flatMap { institution in
                institution.allAccounts.filter(Self.hasStaleCustomType).map { account in
                    RedundantDataItem(
                        id: "\(institution.id.uuidString).\(account.id.uuidString)",
                        recordTitle: "\(Self.title(of: institution)) · \(account.displayName)",
                        fieldNames: ["自定义类型（\(account.customType)）"]
                    )
                }
            }
        )
        appendFinding(
            to: &findings,
            ruleID: "domestic-overseas-details",
            title: "境内银行的境外信息",
            detail: "境内银行不显示 SWIFT、IBAN、汇款信息和中英文地址。",
            items: financialInstitutions.compactMap { institution in
                let fields = Self.overseasOnlyFields(in: institution).map(\.name)
                guard !fields.isEmpty else { return nil }
                return RedundantDataItem(id: institution.id.uuidString, recordTitle: Self.title(of: institution), fieldNames: fields)
            }
        )
        return findings
    }

    func cleanupRedundantData() {
        for index in financialInstitutions.indices {
            var value = financialInstitutions[index]
            var accounts = value.accounts
            for i in accounts.indices {
                Self.clearStaleCustomType(&accounts[i])
                for j in accounts[i].subaccounts.indices { Self.clearStaleCustomType(&accounts[i].subaccounts[j]) }
            }
            value.accounts = accounts
            for field in Self.overseasOnlyFields(in: value) { value[keyPath: field.keyPath] = "" }
            if value != financialInstitutions[index] { financialInstitutions[index] = value }
        }
    }

    private static func title(of institution: FinancialInstitution) -> String {
        let name = institution.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? institution.serviceSummary : name
    }

    private static func hasStaleCustomType(_ account: FinancialAccount) -> Bool {
        account.kind != .other && !account.customType.isEmpty
    }

    private static func clearStaleCustomType(_ account: inout FinancialAccount) {
        if hasStaleCustomType(account) { account.customType = "" }
    }

    /// Bank fields that the editor and detail page only expose for overseas banks.
    private static func overseasOnlyFields(
        in institution: FinancialInstitution
    ) -> [(name: String, keyPath: WritableKeyPath<FinancialInstitution, String>)] {
        guard institution.kind == .bank, institution.region == .domestic else { return [] }
        let fields: [(name: String, keyPath: WritableKeyPath<FinancialInstitution, String>)] = [
            ("SWIFT", \.swift),
            ("IBAN", \.iban),
            ("汇款银行名称", \.remittanceBankName),
            ("汇款银行地址", \.remittanceBankAddress),
            ("汇款说明", \.remittanceInstructions),
            ("通讯地址（中文）", \.correspondenceAddressChinese),
            ("通讯地址（英文）", \.correspondenceAddressEnglish),
            ("居住地址（中文）", \.residentialAddressChinese),
            ("居住地址（英文）", \.residentialAddressEnglish)
        ]
        return fields.filter { !institution[keyPath: $0.keyPath].isEmpty }
    }

    @discardableResult
    func saveInstitution(_ institution: FinancialInstitution, cards: [BankCard], expected: FinancialInstitution?, expectedCards: [BankCard]) throws -> Bool {
        var value = institution
        if value.kind != .bank && !cards.isEmpty { throw FinancialArchiveError.wrongCategory }
        value.cards = cards.map { card in var card = card; card.accountID = value.id; return card }
        try value.validate()
        value.schemaVersion = FinancialInstitution.currentSchemaVersion
        let current = financialInstitutions.first { $0.id == value.id }
        guard expected.map({ $0 == current && $0.cards == expectedCards }) ?? (current == nil) else { throw FinancialArchiveError.editConflict }
        let previousFiles = current?.financeAttachments ?? []
        if let index = financialInstitutions.firstIndex(where: { $0.id == value.id }) { financialInstitutions[index] = value }
        else { financialInstitutions.append(value) }
        didMutate()
        mutationNotifier?.scheduleAttachmentRemovalAfterPersistence(previousFiles)
        return true
    }
    @discardableResult
    func replaceAccount(_ institution: FinancialInstitution, cards: [BankCard], expected: FinancialInstitution, expectedCards: [BankCard]? = nil) -> Bool {
        do { return try saveInstitution(institution, cards: cards, expected: expected, expectedCards: expectedCards ?? expected.cards) }
        catch { DiagnosticLogger.shared.log(.data, "金融档案保存被拒绝 id=\(institution.id)", level: .warning); return false }
    }
    func deleteAccount(id: UUID) {
        guard let value = financialInstitutions.first(where: { $0.id == id }) else { return }
        financialInstitutions.removeAll { $0.id == id }; didMutate()
        mutationNotifier?.scheduleAttachmentRemovalAfterPersistence(value.financeAttachments)
    }
    func cards(for institution: FinancialInstitution) -> [BankCard] { financialInstitutions.first { $0.id == institution.id }?.cards ?? [] }
    func updateCard(_ updated: BankCard, expected: BankCard) -> Bool {
        guard let parentID = expected.accountID, let parent = financialInstitutions.first(where: { $0.id == parentID }), parent.cards.first(where: { $0.id == expected.id }) == expected else { return false }
        return replaceAccount(parent, cards: parent.cards.map { $0.id == updated.id ? updated : $0 }, expected: parent)
    }
    func importCreditCardStatement(from url: URL) throws -> FileAttachment {
        let value = try attachmentStore.importFile(from: url)
        guard value.contentType.conforms(to: .pdf) else { attachmentStore.delete(value); throw AttachmentStoreError.invalidFile }
        return value
    }
    func importCreditCardStatementInBackground(from url: URL) async throws -> FileAttachment {
        let attachments = attachmentStore
        return try await Task.detached(priority: .userInitiated) {
            let value = try attachments.importFile(from: url)
            guard value.contentType.conforms(to: .pdf) else { attachments.delete(value); throw AttachmentStoreError.invalidFile }
            return value
        }.value
    }
    func importFinanceDocument(from url: URL) async throws -> FileAttachment {
        let attachments = attachmentStore
        return try await Task.detached(priority: .userInitiated) { try attachments.importFile(from: url) }.value
    }
    private func didMutate() { mutationNotifier?.moduleStoreDidMutate() }
    func loginFieldTemplates(for region: BankRegion) -> [BankLoginFieldTemplate] {
        region == .domestic ? domesticLoginFieldTemplates : overseasLoginFieldTemplates
    }

    func makeLoginFields(for region: BankRegion) -> [AdditionalLoginField] {
        loginFieldTemplates(for: region)
            .map { $0.makeField() }
    }

    func upsertLoginFieldTemplate(_ template: BankLoginFieldTemplate, for region: BankRegion) {
        var value = template
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else {
            DiagnosticLogger.shared.log(.data, "登录字段模板保存被拒绝（名称为空） region=\(region)", level: .warning)
            return
        }
        var templates = loginFieldTemplates(for: region)
        let isUpdate = templates.contains { $0.id == value.id }
        if let index = templates.firstIndex(where: { $0.id == value.id }) {
            templates[index] = value
        } else {
            templates.append(value)
        }
        templates = Self.normalizedTemplates(templates)
        if region == .domestic {
            domesticLoginFieldTemplates = templates
        } else {
            overseasLoginFieldTemplates = templates
        }
        DiagnosticLogger.shared.log(.data, "登录字段模板\(isUpdate ? "更新" : "新增") region=\(region) id=\(value.id)")
        didMutate()
    }

    func deleteLoginFieldTemplate(_ template: BankLoginFieldTemplate, for region: BankRegion) {
        let templates = loginFieldTemplates(for: region).filter { $0.id != template.id }
        if region == .domestic {
            domesticLoginFieldTemplates = templates
        } else {
            overseasLoginFieldTemplates = templates
        }
        DiagnosticLogger.shared.log(.data, "登录字段模板删除 region=\(region) id=\(template.id)")
        didMutate()
    }

    private static func normalizedTemplates(_ templates: [BankLoginFieldTemplate]) -> [BankLoginFieldTemplate] {
        var seen = Set<String>()
        return templates.compactMap { source in
            var template = source
            template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !template.name.isEmpty else { return nil }
            let comparisonName = template.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(comparisonName).inserted else { return nil }
            return template
        }
    }

}
#endif
