import Foundation
import UniformTypeIdentifiers

@MainActor
final class FinanceStore: ObservableObject {
    @Published private(set) var accounts: [BankAccount]
    @Published private(set) var cards: [BankCard]

    private let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?

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

    func deleteAccount(at offsets: IndexSet) {
        let ids = offsets.map { accounts[$0].id }
        for card in cards where ids.contains(card.accountID ?? UUID()) {
            card.statements.compactMap(\.attachment).forEach(attachmentStore.delete)
        }
        accounts.remove(atOffsets: offsets)
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
}
