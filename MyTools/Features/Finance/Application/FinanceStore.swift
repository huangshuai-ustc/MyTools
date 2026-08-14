#if MYTOOLS_FEATURE_FINANCE
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FinanceStore: ObservableObject, ModuleDataCleanupParticipant {
    @Published private(set) var accounts: [BankAccount]
    @Published private(set) var cards: [BankCard]

    private let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    var cleanupModule: ToolModule { .personalFinance }

    init(
        accounts: [BankAccount] = [],
        cards: [BankCard] = [],
        attachmentStore: AttachmentStore
    ) {
        self.accounts = accounts
        self.cards = cards
        self.attachmentStore = attachmentStore
    }

    var currentCardCount: Int {
        VaultData(accounts: accounts, cards: cards).currentCardCount
    }

    var currentBankCount: Int {
        VaultData(accounts: accounts, cards: cards).currentBankCount
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(accounts: [BankAccount], cards: [BankCard]) {
        self.accounts = accounts
        self.cards = cards
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
    }

    func replaceAccount(_ account: BankAccount, cards updatedCards: [BankCard]) {
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
        didMutate()
    }

    func deleteAccount(id: UUID) {
        let ids = [id]
        for card in cards where ids.contains(card.accountID ?? UUID()) {
            card.statements.compactMap(\.attachment).forEach(attachmentStore.delete)
        }
        accounts.removeAll { $0.id == id }
        cards.removeAll { card in ids.contains(card.accountID ?? UUID()) }
        didMutate()
    }

    func cards(for account: BankAccount) -> [BankCard] {
        cards.filter { $0.accountID == account.id }
    }

    func importCreditCardStatement(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .pdf) else {
            attachmentStore.delete(attachment)
            throw AttachmentStoreError.invalidFile
        }
        return attachment
    }

    func deleteUncommittedAttachment(_ attachment: FileAttachment) {
        attachmentStore.delete(attachment)
    }

    func renameAttachment(
        _ attachment: FileAttachment,
        to fileName: String
    ) throws -> FileAttachment {
        try attachmentStore.rename(attachment, to: fileName)
    }

    func attachmentURL(for attachment: FileAttachment) -> URL {
        attachmentStore.url(for: attachment)
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
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

    private func appendFinding(
        to findings: inout [RedundantDataFinding],
        ruleID: String,
        title: String,
        detail: String,
        recordCount: Int,
        fieldCount: Int
    ) {
        guard fieldCount > 0 else { return }
        findings.append(RedundantDataFinding(
            ruleID: ruleID,
            module: .personalFinance,
            title: title,
            detail: detail,
            affectedRecordCount: recordCount,
            affectedFieldCount: fieldCount
        ))
    }
}

#endif
