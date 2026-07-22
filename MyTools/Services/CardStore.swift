import Foundation
import Combine

@MainActor
final class CardStore: ObservableObject {
    @Published private(set) var accounts: [BankAccount]
    @Published private(set) var cards: [BankCard]
    private let secureStore = SecureStore()

    init() {
        let vault = secureStore.loadVault()
        accounts = vault.accounts
        cards = vault.cards
    }

    func loadEncryptedVaultAfterAuthentication() {
        let encryptedVault = secureStore.hasLocalVault() ? VaultData() : secureStore.loadEncryptedVault()
        let vault = encryptedVault.isEmpty ? secureStore.loadVault() : encryptedVault
        accounts = vault.accounts
        cards = vault.cards
        // 旧版本加密数据在管理员认证后迁移到普通可读存储；之后普通模式启动不读取 Keychain。
        try? secureStore.saveVault(vault)
    }

    func upsertAccount(_ account: BankAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            for cardIndex in cards.indices where cards[cardIndex].accountID == account.id {
                cards[cardIndex].bankName = account.bankName
                cards[cardIndex].branchName = account.branchName
            }
        } else {
            accounts.append(account)
        }
        persist()
    }

    func deleteAccount(at offsets: IndexSet) {
        let ids = offsets.map { accounts[$0].id }
        accounts.remove(atOffsets: offsets)
        cards.removeAll { card in ids.contains(card.accountID ?? UUID()) }
        persist()
    }

    func cards(for account: BankAccount) -> [BankCard] { cards.filter { $0.accountID == account.id } }

    func upsertCard(_ card: BankCard, in account: BankAccount) {
        var attached = card; attached.accountID = account.id; attached.bankName = account.bankName; attached.branchName = account.branchName
        upsert(attached)
    }

    func upsert(_ card: BankCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card } else { cards.append(card) }
        persist()
    }

    func makeBackupDocument(password: String) throws -> VaultBackupDocument {
        let vault = VaultData(accounts: accounts, cards: cards)
        let data = try VaultBackupCrypto.makeBackup(from: vault, password: password)
        return VaultBackupDocument(data: data)
    }

    func restoreBackup(from data: Data, password: String) throws {
        let vault = try VaultBackupCrypto.restoreVault(from: data, password: password)
        try secureStore.saveVault(vault)
        accounts = vault.accounts
        cards = vault.cards
    }

    func delete(at offsets: IndexSet) { cards.remove(atOffsets: offsets); persist() }
    func delete(_ card: BankCard) { cards.removeAll { $0.id == card.id }; persist() }
    private func persist() { try? secureStore.saveVault(VaultData(accounts: accounts, cards: cards)) }
}

private extension VaultData {
    var isEmpty: Bool { accounts.isEmpty && cards.isEmpty }
}
