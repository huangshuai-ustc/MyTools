import Foundation
import CryptoKit
import Testing
@testable import MyTools

private struct FixedVaultEncryptionKey: VaultEncryptionKeyProviding {
    let key: SymmetricKey

    init(seed: UInt8 = 1) {
        key = SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    func loadKey() throws -> SymmetricKey? { key }
    func createAndStoreKey() throws -> SymmetricKey { key }
}

private struct MissingVaultEncryptionKey: VaultEncryptionKeyProviding {
    func loadKey() throws -> SymmetricKey? { nil }
    func createAndStoreKey() throws -> SymmetricKey { throw VaultCryptoError.keyDerivationFailed }
}

private struct ThrowingVaultEncryptionKey: VaultEncryptionKeyProviding {
    func loadKey() throws -> SymmetricKey? { throw VaultCryptoError.keyDerivationFailed }
    func createAndStoreKey() throws -> SymmetricKey { throw VaultCryptoError.keyDerivationFailed }
}

private struct PlainVaultFixture: Codable {
    let vault: VaultData
    let secrets: [SecretVaultValue]
}

struct SecureStoreEncryptionTests {
    private func makeStore(
        keyProvider: any VaultEncryptionKeyProviding
    ) -> (store: SecureStore, vaultURL: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureStoreEncryptionTests-\(UUID().uuidString)", isDirectory: true)
        let store = SecureStore(
            applicationSupportDirectory: directory,
            keyProvider: keyProvider
        )
        let vaultURL = directory
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("local-vault.json", isDirectory: false)
        return (store, vaultURL, directory)
    }

    private func sampleVault(marker: String) -> VaultData {
        var record = BillRecord()
        record.merchant = marker
        return VaultData(billRecords: [record])
    }

    @Test func encryptedRoundTripPreservesDataAndWritesEnvelope() throws {
        let (store, vaultURL, _) = makeStore(keyProvider: FixedVaultEncryptionKey())
        let marker = "加密往返测试"
        try store.saveVault(sampleVault(marker: marker))

        let raw = try Data(contentsOf: vaultURL)
        #expect(VaultCrypto.isEncryptedEnvelope(raw))
        #expect(String(data: raw, encoding: .utf8)?.contains(marker) != true)

        let result = store.loadVaultWithMetrics()
        #expect(result.canPersist)
        #expect(result.source.contains("已加密"))
        #expect(result.vault.billRecords.first?.merchant == marker)
    }

    @Test func legacyPlaintextVaultMigratesToEncryptionOnLoad() throws {
        let (store, vaultURL, _) = makeStore(keyProvider: FixedVaultEncryptionKey())
        let marker = "明文迁移测试"
        let fixture = PlainVaultFixture(vault: sampleVault(marker: marker), secrets: [])
        try FileManager.default.createDirectory(
            at: vaultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(fixture).write(to: vaultURL)

        let result = store.loadVaultWithMetrics()
        #expect(result.canPersist)
        #expect(result.source.contains("已升级加密"))
        #expect(result.vault.billRecords.first?.merchant == marker)

        let migratedRaw = try Data(contentsOf: vaultURL)
        #expect(VaultCrypto.isEncryptedEnvelope(migratedRaw))
        #expect(String(data: migratedRaw, encoding: .utf8)?.contains(marker) != true)

        let reloaded = store.loadVaultWithMetrics()
        #expect(reloaded.canPersist)
        #expect(reloaded.source.contains("已加密"))
        #expect(reloaded.vault.billRecords.first?.merchant == marker)
    }

    @Test func tamperedEncryptedVaultFailsClosedAndPreservesFile() throws {
        let (store, vaultURL, _) = makeStore(keyProvider: FixedVaultEncryptionKey())
        try store.saveVault(sampleVault(marker: "篡改测试"))

        var corrupted = try Data(contentsOf: vaultURL)
        corrupted[corrupted.count - 1] ^= 0xFF
        try corrupted.write(to: vaultURL)

        let result = store.loadVaultWithMetrics()
        #expect(!result.canPersist)
        #expect(result.source.contains("原文件已保留"))
        #expect(result.vault.billRecords.isEmpty)
        #expect(try Data(contentsOf: vaultURL) == corrupted)
    }

    @Test func wrongKeyFailsClosedAndPreservesFile() throws {
        let (savingStore, vaultURL, directory) = makeStore(
            keyProvider: FixedVaultEncryptionKey(seed: 1)
        )
        try savingStore.saveVault(sampleVault(marker: "错误密钥测试"))

        let otherStore = SecureStore(
            applicationSupportDirectory: directory,
            keyProvider: FixedVaultEncryptionKey(seed: 2)
        )
        let result = otherStore.loadVaultWithMetrics()
        #expect(!result.canPersist)
        #expect(result.source.contains("原文件已保留"))
        #expect(VaultCrypto.isEncryptedEnvelope(try Data(contentsOf: vaultURL)))
    }

    @Test func encryptedVaultWithMissingKeyFailsClosed() throws {
        let (savingStore, vaultURL, directory) = makeStore(
            keyProvider: FixedVaultEncryptionKey()
        )
        try savingStore.saveVault(sampleVault(marker: "密钥缺失测试"))

        let missingKeyStore = SecureStore(
            applicationSupportDirectory: directory,
            keyProvider: MissingVaultEncryptionKey()
        )
        let result = missingKeyStore.loadVaultWithMetrics()
        #expect(!result.canPersist)
        #expect(result.source.contains("原文件已保留"))
        #expect(VaultCrypto.isEncryptedEnvelope(try Data(contentsOf: vaultURL)))
    }

    @Test func plaintextVaultWithoutUsableKeyStillLoadsAndSavesPlaintext() throws {
        let (store, vaultURL, _) = makeStore(keyProvider: ThrowingVaultEncryptionKey())
        let marker = "明文降级测试"
        let fixture = PlainVaultFixture(vault: sampleVault(marker: marker), secrets: [])
        try FileManager.default.createDirectory(
            at: vaultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(fixture).write(to: vaultURL)

        let loadResult = store.loadVaultWithMetrics()
        #expect(loadResult.canPersist)
        #expect(loadResult.source.contains("未加密"))
        #expect(loadResult.vault.billRecords.first?.merchant == marker)

        try store.saveVault(sampleVault(marker: "明文降级保存"))
        let raw = try Data(contentsOf: vaultURL)
        #expect(!VaultCrypto.isEncryptedEnvelope(raw))
        #expect(String(data: raw, encoding: .utf8)?.contains("明文降级保存") == true)

        let reloaded = store.loadVaultWithMetrics()
        #expect(reloaded.canPersist)
        #expect(reloaded.vault.billRecords.first?.merchant == "明文降级保存")
    }

    @Test func corruptedPlaintextVaultFailsClosed() throws {
        let (store, vaultURL, _) = makeStore(keyProvider: FixedVaultEncryptionKey())
        try FileManager.default.createDirectory(
            at: vaultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json-at-all".utf8).write(to: vaultURL)

        let result = store.loadVaultWithMetrics()
        #expect(!result.canPersist)
        #expect(result.source.contains("原文件已保留"))
        #expect(try Data(contentsOf: vaultURL) == Data("not-json-at-all".utf8))
    }

    @Test func concurrentScheduleFlushesWithoutErrorsAndPersistsEncryptedVault() async throws {
        let (store, vaultURL, _) = makeStore(keyProvider: FixedVaultEncryptionKey())
        let coordinator = VaultPersistenceCoordinator(secureStore: store)
        let writeCount = 64
        let vaults = (0..<writeCount).map { sampleVault(marker: "并发调度-\($0)") }
        DispatchQueue.concurrentPerform(iterations: writeCount) { index in
            coordinator.schedule(vaults[index])
        }

        let flushError = await coordinator.flush()
        #expect(flushError == nil)

        let result = store.loadVaultWithMetrics()
        #expect(result.canPersist)
        #expect(!result.vault.billRecords.isEmpty)
        #expect(VaultCrypto.isEncryptedEnvelope(try Data(contentsOf: vaultURL)))
    }
}
