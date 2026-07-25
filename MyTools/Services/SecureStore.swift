import Foundation
import CryptoKit
import Security

enum SecureStoreError: Error { case keychain(OSStatus), invalidData }

struct LocalVaultLoadResult: @unchecked Sendable {
    let vault: VaultData
    let byteCount: Int
    let source: String
    let readMilliseconds: Double
    let decodeMilliseconds: Double
    let migrationMilliseconds: Double
    let totalMilliseconds: Double
}

final class SecureStore {
    private let service = "com.example.ToolBox.encryption-key"
    private let defaultsKey = "encrypted-bank-cards"
    private let publicDefaultsKey = "public-vault-metadata"
    private let localVaultKey = "local-vault-data"
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let applicationSupportDirectory: URL

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    private var localVaultDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("MyTools", isDirectory: true)
    }

    private var localVaultURL: URL {
        localVaultDirectory.appendingPathComponent("local-vault.json", isDirectory: false)
    }

    func loadCards() -> [BankCard] {
        guard let blob = defaults.data(forKey: defaultsKey) else { return [] }
        guard
              let keyData = try? keyData(),
              let sealed = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(sealed, using: SymmetricKey(data: keyData)),
              let cards = try? JSONDecoder().decode([BankCard].self, from: plaintext) else { return [] }
        return cards
    }

    func loadEncryptedVault() -> VaultData {
        guard let blob = defaults.data(forKey: defaultsKey),
              let keyData = try? keyData(),
              let sealed = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(sealed, using: SymmetricKey(data: keyData)),
              let vault = try? JSONDecoder().decode(VaultData.self, from: plaintext) else {
            return VaultData()
        }
        return vault
    }

    func loadVault() -> VaultData {
        loadVaultWithMetrics().vault
    }

    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        let totalStartedAt = ProcessInfo.processInfo.systemUptime
        var readMilliseconds = 0.0
        var decodeMilliseconds = 0.0

        if fileManager.fileExists(atPath: localVaultURL.path) {
            let readStartedAt = ProcessInfo.processInfo.systemUptime
            let data = try? Data(contentsOf: localVaultURL, options: .mappedIfSafe)
            readMilliseconds += elapsedMilliseconds(since: readStartedAt)

            if let data {
                let decodeStartedAt = ProcessInfo.processInfo.systemUptime
                let vault = try? JSONDecoder().decode(VaultData.self, from: data)
                decodeMilliseconds += elapsedMilliseconds(since: decodeStartedAt)
                if let vault {
                    return loadResult(
                        vault: vault,
                        byteCount: data.count,
                        source: "Application Support",
                        readMilliseconds: readMilliseconds,
                        decodeMilliseconds: decodeMilliseconds,
                        totalStartedAt: totalStartedAt
                    )
                }
            }
        }

        let legacyReadStartedAt = ProcessInfo.processInfo.systemUptime
        let legacyData = defaults.data(forKey: localVaultKey)
        readMilliseconds += elapsedMilliseconds(since: legacyReadStartedAt)
        if let legacyData {
            let decodeStartedAt = ProcessInfo.processInfo.systemUptime
            let vault = try? JSONDecoder().decode(VaultData.self, from: legacyData)
            decodeMilliseconds += elapsedMilliseconds(since: decodeStartedAt)
            if let vault {
                let migrationStartedAt = ProcessInfo.processInfo.systemUptime
                let source: String
                do {
                    try writeVaultFile(vault)
                    defaults.removeObject(forKey: localVaultKey)
                    source = "UserDefaults（迁移成功）"
                } catch {
                    // 保留旧数据，下次启动可以继续读取并重试迁移。
                    source = "UserDefaults（迁移写入失败，已保留旧数据）"
                }
                return loadResult(
                    vault: vault,
                    byteCount: legacyData.count,
                    source: source,
                    readMilliseconds: readMilliseconds,
                    decodeMilliseconds: decodeMilliseconds,
                    migrationMilliseconds: elapsedMilliseconds(since: migrationStartedAt),
                    totalStartedAt: totalStartedAt
                )
            }
        }

        let publicReadStartedAt = ProcessInfo.processInfo.systemUptime
        let publicData = defaults.data(forKey: publicDefaultsKey)
        readMilliseconds += elapsedMilliseconds(since: publicReadStartedAt)
        if let publicData {
            let decodeStartedAt = ProcessInfo.processInfo.systemUptime
            let vault = try? JSONDecoder().decode(VaultData.self, from: publicData)
            decodeMilliseconds += elapsedMilliseconds(since: decodeStartedAt)
            if let vault {
                return loadResult(
                    vault: vault,
                    byteCount: publicData.count,
                    source: "脱敏兼容数据",
                    readMilliseconds: readMilliseconds,
                    decodeMilliseconds: decodeMilliseconds,
                    totalStartedAt: totalStartedAt
                )
            }
        }

        return loadResult(
            vault: VaultData(),
            byteCount: 0,
            source: "空档案",
            readMilliseconds: readMilliseconds,
            decodeMilliseconds: decodeMilliseconds,
            totalStartedAt: totalStartedAt
        )
    }

    func hasLocalVault() -> Bool {
        fileManager.fileExists(atPath: localVaultURL.path)
            || defaults.data(forKey: localVaultKey) != nil
    }

    func loadPublicVault() -> VaultData {
        guard let data = defaults.data(forKey: publicDefaultsKey),
              let vault = try? JSONDecoder().decode(VaultData.self, from: data) else { return VaultData() }
        return vault
    }

    func saveVault(_ vault: VaultData) throws {
        try writeVaultFile(vault)
        defaults.removeObject(forKey: localVaultKey)
        let publicVault = VaultData(
            accounts: vault.accounts.map { account in
                var copy = account
                copy.accountNumber = ""
                copy.swift = ""
                copy.iban = ""
                copy.remittanceSwiftCode = ""
                copy.loginPassword = ""
                copy.additionalLoginFields = account.additionalLoginFields.map { field in
                    var redacted = field
                    redacted.value = field.isSensitive
                        ? ""
                        : (field.value.count > 4 ? String(field.value.suffix(4)) : field.value)
                    return redacted
                }
                copy.foreignSubaccounts = account.foreignSubaccounts.map { subaccount in
                    var redacted = subaccount
                    redacted.accountNumber = subaccount.accountNumber.count > 4
                        ? String(subaccount.accountNumber.suffix(4))
                        : subaccount.accountNumber
                    return redacted
                }
                return copy
            },
            cards: vault.cards.map { card in
                var copy = card
                copy.cardNumber = card.cardNumber.count > 4
                    ? String(card.cardNumber.suffix(4))
                    : card.cardNumber
                copy.cvv = ""
                for index in copy.statements.indices {
                    copy.statements[index].attachment?.backupData = nil
                }
                return copy
            },
            stocks: vault.stocks.map { stock in
                var copy = stock
                copy.transactions = []
                copy.dividends = []
                return copy
            },
            currencyExchangeRecords: vault.currencyExchangeRecords,
            medicalRecords: vault.medicalRecords.map { record in
                var copy = record
                for index in copy.attachments.indices { copy.attachments[index].backupData = nil }
                return copy
            },
            hospitalProfiles: vault.hospitalProfiles
        )
        if let publicData = try? JSONEncoder().encode(publicVault) {
            defaults.set(publicData, forKey: publicDefaultsKey)
        }
    }

    func saveCards(_ cards: [BankCard]) throws {
        let key = SymmetricKey(data: try keyData())
        let payload = try JSONEncoder().encode(cards)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw SecureStoreError.invalidData }
        defaults.set(combined, forKey: defaultsKey)
    }

    private func writeVaultFile(_ vault: VaultData) throws {
        let payload = try JSONEncoder().encode(vault)
        try fileManager.createDirectory(
            at: localVaultDirectory,
            withIntermediateDirectories: true
        )
        try payload.write(to: localVaultURL, options: .atomic)
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: localVaultURL.path
        )
#endif
    }

    private func loadResult(
        vault: VaultData,
        byteCount: Int,
        source: String,
        readMilliseconds: Double,
        decodeMilliseconds: Double,
        migrationMilliseconds: Double = 0,
        totalStartedAt: TimeInterval
    ) -> LocalVaultLoadResult {
        LocalVaultLoadResult(
            vault: vault,
            byteCount: byteCount,
            source: source,
            readMilliseconds: readMilliseconds,
            decodeMilliseconds: decodeMilliseconds,
            migrationMilliseconds: migrationMilliseconds,
            totalMilliseconds: elapsedMilliseconds(since: totalStartedAt)
        )
    }

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
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
