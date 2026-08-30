import Foundation
import CryptoKit
import Security
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

private struct TemporarilyUnavailableVaultEncryptionKey: VaultEncryptionKeyProviding {
    func loadKey() throws -> SymmetricKey? {
        throw VaultEncryptionKeyError.keychainReadFailed(errSecInteractionNotAllowed)
    }

    func createAndStoreKey() throws -> SymmetricKey {
        throw VaultEncryptionKeyError.keychainWriteFailed(errSecInteractionNotAllowed)
    }
}

private final class RecoveringVaultEncryptionKey: VaultEncryptionKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let key = SymmetricKey(data: Data(repeating: 9, count: 32))
    private var remainingFailures: Int

    init(failureCount: Int) {
        remainingFailures = failureCount
    }

    func loadKey() throws -> SymmetricKey? {
        try lock.withLock {
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw VaultEncryptionKeyError.keychainReadFailed(errSecInteractionNotAllowed)
            }
            return key
        }
    }

    func createAndStoreKey() throws -> SymmetricKey { key }
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

    @Test func temporarilyUnavailableKeyDefersEncryptedLoadAndPreservesFile() throws {
        let (savingStore, vaultURL, directory) = makeStore(
            keyProvider: FixedVaultEncryptionKey()
        )
        try savingStore.saveVault(sampleVault(marker: "受保护数据测试"))
        let original = try Data(contentsOf: vaultURL)

        let unavailableStore = SecureStore(
            applicationSupportDirectory: directory,
            keyProvider: TemporarilyUnavailableVaultEncryptionKey()
        )
        let result = unavailableStore.loadVaultWithMetrics()

        #expect(!result.canPersist)
        #expect(result.failure == .protectedDataUnavailable)
        #expect(try Data(contentsOf: vaultURL) == original)
    }

    @Test func unavailableKeyNeverDowngradesEncryptedVaultToPlaintext() throws {
        let (savingStore, vaultURL, directory) = makeStore(
            keyProvider: FixedVaultEncryptionKey()
        )
        try savingStore.saveVault(sampleVault(marker: "原始加密内容"))
        let original = try Data(contentsOf: vaultURL)

        let unavailableStore = SecureStore(
            applicationSupportDirectory: directory,
            keyProvider: TemporarilyUnavailableVaultEncryptionKey()
        )
        var didThrow = false
        do {
            try unavailableStore.saveVault(sampleVault(marker: "不应明文写入"))
        } catch {
            didThrow = true
            #expect(isTemporaryVaultKeyAccessError(error))
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: vaultURL) == original)
        #expect(VaultCrypto.isEncryptedEnvelope(try Data(contentsOf: vaultURL)))
    }

    @Test func plaintextVaultWithoutUsableKeyLoadsButRefusesUnencryptedSave() throws {
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

        #expect(throws: VaultCryptoError.self) {
            try store.saveVault(sampleVault(marker: "不应明文保存"))
        }
        let preserved = try Data(contentsOf: vaultURL)
        #expect(String(data: preserved, encoding: .utf8)?.contains(marker) == true)
        #expect(String(data: preserved, encoding: .utf8)?.contains("不应明文保存") != true)
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

    @Test func persistenceCoordinatorRetriesTemporaryKeychainFailure() async throws {
        let keyProvider = RecoveringVaultEncryptionKey(failureCount: 1)
        let (store, vaultURL, _) = makeStore(keyProvider: keyProvider)
        let coordinator = VaultPersistenceCoordinator(
            secureStore: store,
            temporaryRetryDelay: 0.01
        )

        coordinator.schedule(sampleVault(marker: "自动重试写入"))
        try await Task.sleep(for: .milliseconds(100))

        let flushError = await coordinator.flush()
        #expect(flushError == nil)
        let result = store.loadVaultWithMetrics()
        #expect(result.canPersist)
        #expect(result.vault.billRecords.first?.merchant == "自动重试写入")
        #expect(VaultCrypto.isEncryptedEnvelope(try Data(contentsOf: vaultURL)))
    }
}
