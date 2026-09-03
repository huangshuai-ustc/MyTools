#if MYTOOLS_FEATURE_FINANCE
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FinanceStore: ObservableObject, ModuleDataCleanupParticipant, AttachmentManaging {
    @Published private(set) var accounts: [BankAccount]
    @Published private(set) var cards: [BankCard]
    @Published private(set) var domesticLoginFieldTemplates: [BankLoginFieldTemplate]
    @Published private(set) var overseasLoginFieldTemplates: [BankLoginFieldTemplate]

    let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    var cleanupModule: ToolModule { .personalFinance }

    init(
        accounts: [BankAccount] = [],
        cards: [BankCard] = [],
        domesticLoginFieldTemplates: [BankLoginFieldTemplate] = [],
        overseasLoginFieldTemplates: [BankLoginFieldTemplate] = [],
        attachmentStore: AttachmentStore
    ) {
        self.accounts = accounts.map(Self.convertingStoredLoginFields)
        self.cards = cards
        self.domesticLoginFieldTemplates = Self.normalizedTemplates(
            domesticLoginFieldTemplates.isEmpty ? BankLoginFieldTemplate.domesticDefaults : domesticLoginFieldTemplates
        )
        self.overseasLoginFieldTemplates = Self.normalizedTemplates(
            overseasLoginFieldTemplates.isEmpty ? BankLoginFieldTemplate.overseasDefaults : overseasLoginFieldTemplates
        )
        self.attachmentStore = attachmentStore
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

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(accounts: [BankAccount], cards: [BankCard]) {
        self.accounts = accounts.map(Self.convertingStoredLoginFields)
        self.cards = cards
        DiagnosticLogger.shared.log(.data, "财务数据替换 accounts=\(accounts.count) cards=\(cards.count)")
    }

    func replace(
        accounts: [BankAccount],
        cards: [BankCard],
        domesticLoginFieldTemplates: [BankLoginFieldTemplate],
        overseasLoginFieldTemplates: [BankLoginFieldTemplate]
    ) {
        self.accounts = accounts.map(Self.convertingStoredLoginFields)
        self.cards = cards
        self.domesticLoginFieldTemplates = Self.normalizedTemplates(
            domesticLoginFieldTemplates.isEmpty ? BankLoginFieldTemplate.domesticDefaults : domesticLoginFieldTemplates
        )
        self.overseasLoginFieldTemplates = Self.normalizedTemplates(
            overseasLoginFieldTemplates.isEmpty ? BankLoginFieldTemplate.overseasDefaults : overseasLoginFieldTemplates
        )
        DiagnosticLogger.shared.log(.data, "财务数据替换（含模板） accounts=\(accounts.count) cards=\(cards.count)")
    }

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

    func scanRedundantData() -> [RedundantDataFinding] {
        var findings: [RedundantDataFinding] = []

        let customTypeRecords = accounts.flatMap(\.foreignSubaccounts).filter {
            $0.type != .other && $0.customType?.isEmpty == false
        }.count
        appendFinding(
            to: &findings,
            ruleID: "non-custom-foreign-account-type",
            title: "非自定义境外子账户的类型名称",
            detail: "只有“其他账户”会使用自定义类型名称。",
            recordCount: customTypeRecords,
            fieldCount: customTypeRecords
        )

        let domesticRecords = accounts.filter {
            $0.region == .domestic && overseasOnlyFieldCount(in: $0) > 0
        }
        appendFinding(
            to: &findings,
            ruleID: "domestic-overseas-details",
            title: "境内银行的境外专属资料",
            detail: "境内银行不使用境外地址、SWIFT、IBAN 和汇入汇款资料。",
            recordCount: domesticRecords.count,
            fieldCount: domesticRecords.reduce(0) { $0 + overseasOnlyFieldCount(in: $1) }
        )

        let overseasAccountIDs = Set(accounts.filter { $0.region == .overseas }.map(\.id))
        let overseasCardBranchRecords = cards.filter {
            guard let accountID = $0.accountID, overseasAccountIDs.contains(accountID) else { return false }
            return $0.branchName?.isEmpty == false || $0.branchLocation != nil
        }
        appendFinding(
            to: &findings,
            ruleID: "overseas-card-opening-branch",
            title: "境外银行卡的独立开卡网点",
            detail: "只有境内银行卡使用卡片级开卡网点；境外银行使用账户级分行信息。",
            recordCount: overseasCardBranchRecords.count,
            fieldCount: overseasCardBranchRecords.reduce(0) {
                $0 + ($1.branchName?.isEmpty == false ? 1 : 0) + ($1.branchLocation == nil ? 0 : 1)
            }
        )

        return findings
    }

    func cleanupRedundantData() {
        for accountIndex in accounts.indices {
            for subaccountIndex in accounts[accountIndex].foreignSubaccounts.indices
            where accounts[accountIndex].foreignSubaccounts[subaccountIndex].type != .other {
                accounts[accountIndex].foreignSubaccounts[subaccountIndex].customType = nil
            }
            guard accounts[accountIndex].region == .domestic else { continue }
            accounts[accountIndex].swift = ""
            accounts[accountIndex].iban = ""
            accounts[accountIndex].correspondenceAddressChinese = ""
            accounts[accountIndex].correspondenceAddressEnglish = ""
            accounts[accountIndex].residentialAddressChinese = ""
            accounts[accountIndex].residentialAddressEnglish = ""
            accounts[accountIndex].remittanceBankName = ""
            accounts[accountIndex].remittanceBankAddress = ""
            accounts[accountIndex].remittanceInstructions = ""
        }
        let overseasAccountIDs = Set(accounts.filter { $0.region == .overseas }.map(\.id))
        for cardIndex in cards.indices {
            guard let accountID = cards[cardIndex].accountID,
                  overseasAccountIDs.contains(accountID) else { continue }
            cards[cardIndex].branchName = nil
            cards[cardIndex].branchLocation = nil
        }
    }

    func replaceAccount(_ account: BankAccount, cards updatedCards: [BankCard]) {
        let account = Self.convertingStoredLoginFields(account)
        let previousCards = cards.filter { $0.accountID == account.id }
        let retainedAttachmentIDs = Set(
            updatedCards.flatMap(\.statements).compactMap { $0.attachment?.id }
        )
        for card in previousCards {
            for statement in card.statements {
                guard let attachment = statement.attachment,
                      !retainedAttachmentIDs.contains(attachment.id) else { continue }
                attachmentStore.delete(attachment)
            }
        }

        let isUpdate = accounts.contains { $0.id == account.id }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        cards.removeAll { $0.accountID == account.id }
        cards.append(contentsOf: updatedCards.map { card in
            var attached = card
            attached.accountID = account.id
            return attached
        })
        DiagnosticLogger.shared.log(.data, "银行账户\(isUpdate ? "更新" : "新增") id=\(account.id) cards=\(updatedCards.count)")
        didMutate()
    }

    func deleteAccount(id: UUID) {
        let ids = [id]
        let cardCount = cards.filter { ids.contains($0.accountID ?? UUID()) }.count
        for card in cards where ids.contains(card.accountID ?? UUID()) {
            card.statements.compactMap(\.attachment).forEach(attachmentStore.delete)
        }
        accounts.removeAll { $0.id == id }
        cards.removeAll { card in ids.contains(card.accountID ?? UUID()) }
        DiagnosticLogger.shared.log(.data, "银行账户删除 id=\(id) 关联卡片=\(cardCount)")
        didMutate()
    }

    func cards(for account: BankAccount) -> [BankCard] {
        cards.filter { $0.accountID == account.id }
    }

    func importCreditCardStatement(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .pdf) else {
            attachmentStore.delete(attachment)
            DiagnosticLogger.shared.log(.attachment, "信用卡账单导入被拒绝（不支持的文件类型） name=\(url.lastPathComponent)", level: .warning)
            throw AttachmentStoreError.invalidFile
        }
        return attachment
    }

    // deleteUncommittedAttachment, renameAttachment, attachmentURL
    // are provided by the AttachmentManaging protocol extension.

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
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

    /// Converts values stored by the former dedicated login properties into independent
    /// account fields. Templates are intentionally not consulted: they only seed new accounts.
    private static func convertingStoredLoginFields(_ source: BankAccount) -> BankAccount {
        var account = source
        convertStoredLoginField(
            name: "绑定手机号",
            value: account.boundPhoneNumber,
            isSensitive: false,
            into: &account.additionalLoginFields
        )
        convertStoredLoginField(
            name: "登录账号",
            value: account.loginAccount,
            isSensitive: false,
            into: &account.additionalLoginFields
        )
        convertStoredLoginField(
            name: "登录密码",
            value: account.loginPassword,
            isSensitive: true,
            into: &account.additionalLoginFields
        )
        account.boundPhoneNumber = ""
        account.loginAccount = ""
        account.loginPassword = ""
        return account
    }

    private static func convertStoredLoginField(
        name: String,
        value: String,
        isSensitive: Bool,
        into fields: inout [AdditionalLoginField]
    ) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let index = fields.firstIndex(where: { $0.name == name && ($0.value.isEmpty || $0.value == value) }) {
            fields[index].value = value
            fields[index].isSensitive = fields[index].isSensitive || isSensitive
        } else {
            fields.append(AdditionalLoginField(name: name, value: value, isSensitive: isSensitive))
        }
    }

    private func overseasOnlyFieldCount(in account: BankAccount) -> Int {
        [
            account.swift,
            account.iban,
            account.correspondenceAddressChinese,
            account.correspondenceAddressEnglish,
            account.residentialAddressChinese,
            account.residentialAddressEnglish,
            account.remittanceBankName,
            account.remittanceBankAddress,
            account.remittanceInstructions
        ].filter { !$0.isEmpty }.count
    }

}

#endif
