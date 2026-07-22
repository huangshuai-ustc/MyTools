import Foundation
import CryptoKit
import Security

enum SecureStoreError: Error { case keychain(OSStatus), invalidData }

final class SecureStore {
    private let service = "com.example.ToolBox.encryption-key"
    private let defaultsKey = "encrypted-bank-cards"
    private let publicDefaultsKey = "public-vault-metadata"
    private let localVaultKey = "local-vault-data"

    func loadCards() -> [BankCard] {
        guard let blob = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        guard
              let keyData = try? keyData(),
              let sealed = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(sealed, using: SymmetricKey(data: keyData)),
              let cards = try? JSONDecoder().decode([BankCard].self, from: plaintext) else { return [] }
        return cards
    }

    func loadEncryptedVault() -> VaultData {
        guard let blob = UserDefaults.standard.data(forKey: defaultsKey),
              let keyData = try? keyData(),
              let sealed = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(sealed, using: SymmetricKey(data: keyData)),
              let vault = try? JSONDecoder().decode(VaultData.self, from: plaintext) else {
            return VaultData()
        }
        return vault
    }

    func loadVault() -> VaultData {
        guard let data = UserDefaults.standard.data(forKey: localVaultKey),
              let vault = try? JSONDecoder().decode(VaultData.self, from: data) else {
            return loadPublicVault()
        }
        return vault
    }

    func hasLocalVault() -> Bool {
        UserDefaults.standard.data(forKey: localVaultKey) != nil
    }

    func loadPublicVault() -> VaultData {
        guard let data = UserDefaults.standard.data(forKey: publicDefaultsKey),
              let vault = try? JSONDecoder().decode(VaultData.self, from: data) else { return VaultData() }
        return vault
    }

    func saveVault(_ vault: VaultData) throws {
        let payload = try JSONEncoder().encode(vault)
        UserDefaults.standard.set(payload, forKey: localVaultKey)
        let publicVault = VaultData(
            accounts: vault.accounts.map { account in var copy = account; copy.accountNumber = ""; copy.swift = ""; copy.iban = ""; return copy },
            cards: vault.cards.map { card in var copy = card; copy.cardNumber = card.cardNumber.count > 4 ? String(card.cardNumber.suffix(4)) : card.cardNumber; copy.cvv = ""; return copy }
        )
        if let publicData = try? JSONEncoder().encode(publicVault) { UserDefaults.standard.set(publicData, forKey: publicDefaultsKey) }
    }

    func saveCards(_ cards: [BankCard]) throws {
        let key = SymmetricKey(data: try keyData())
        let payload = try JSONEncoder().encode(cards)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw SecureStoreError.invalidData }
        UserDefaults.standard.set(combined, forKey: defaultsKey)
    }

    private func keyData() throws -> Data {
        if let existing = keychainData() { return existing }
        let newKey = SymmetricKey(size: .bits256)
        let data = newKey.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw SecureStoreError.keychain(status) }
        return keychainData() ?? data
    }

    private func keychainData() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
