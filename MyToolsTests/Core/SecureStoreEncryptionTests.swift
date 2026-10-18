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
    @Test func paymentV3MigrationCommitsAtomicallyAndKeepsEncryptedOriginal() throws {
        let key = FixedVaultEncryptionKey()
        let (store, url, _) = makeStore(keyProvider: key)
        var institution = FinancialInstitution(kind: .payment)
        institution.schemaVersion = 3
        var account = PaymentAccount()
        account.note = "旧账户备注"
        account.receivingProfiles = [FinanceReceivingMethod(accountID: account.id)]
        institution.paymentAccounts = [account]
        var vault = sampleVault(marker: "retained health")
        vault.financialInstitutions = [institution]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlainVaultFixture(vault: vault, secrets: []))) as? [String: Any])
        var rawVault = try #require(json["vault"] as? [String: Any])
        var institutions = try #require(rawVault["financialInstitutions"] as? [[String: Any]])
        var payment = try #require(institutions[0]["payment"] as? [String: Any])
        var accounts = try #require(payment["accounts"] as? [[String: Any]])
        accounts[0].removeValue(forKey: "receivingProfiles")
        payment["accounts"] = accounts
        institutions[0]["payment"] = payment
        rawVault["financialInstitutions"] = institutions
        json["vault"] = rawVault
        let raw = try JSONSerialization.data(withJSONObject: json)
        let original = try VaultCrypto.encrypt(raw, using: key.key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: url)
        let loaded = store.loadVaultWithMetrics()
        #expect(loaded.canPersist)
        #expect(loaded.vault.unavailableModules.isEmpty)
        #expect(loaded.vault.financialInstitutions.first?.schemaVersion == 4)
        #expect(loaded.vault.financialInstitutions.first?.paymentAccounts == [account])
        #expect(loaded.vault.medicalRecords == vault.medicalRecords)
        #expect(try Data(contentsOf: url) != original)
        let snapshots = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("pre-finance-v4-") }
        #expect(snapshots.count == 1)
        #expect(try Data(contentsOf: #require(snapshots.first)) == original)
        let committed = try Data(contentsOf: url)
        #expect(store.loadVaultWithMetrics().canPersist)
        #expect(try Data(contentsOf: url) == committed)
        // Corrupt one current profile: retain exact bytes, quarantine only Finance, no cloud reconciliation.
        accounts[0]["receivingProfiles"] = [["id": "invalid"]]
        payment["accounts"] = accounts
        institutions[0]["payment"] = payment
        institutions[0]["schemaVersion"] = 4
        rawVault["financialInstitutions"] = institutions
        json["vault"] = rawVault
        let corrupt = try VaultCrypto.encrypt(JSONSerialization.data(withJSONObject: json), using: key.key)
        try corrupt.write(to: url)
        let blocked = store.loadVaultWithMetrics()
        #expect(blocked.vault.unavailableModules.contains("personalFinance"))
        #expect(try Data(contentsOf: url) == corrupt)
        let snapshot = try CloudSyncSnapshotBuilder.make(vault: blocked.vault, secrets: [], attachmentStore: AttachmentStore())
        #expect(!snapshot.participatingModules.contains(.personalFinance))
        #expect(!snapshot.items.contains { $0.kind == .financialInstitution })
        try store.saveVault(blocked.vault)
        #expect(store.loadVaultWithMetrics().vault.preservedModulePayloads == blocked.vault.preservedModulePayloads)
    }

    @Test func unreadableFinanceIsQuarantinedWhileOtherModulesRemainWritable() throws {
        let key = FixedVaultEncryptionKey()
        let (store, url, _) = makeStore(keyProvider: key)
        let institution = FinancialInstitution()
        var vault = sampleVault(marker: "healthy records")
        vault.financialInstitutions = [institution]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlainVaultFixture(vault: vault, secrets: []))) as? [String: Any])
        var rawVault = try #require(json["vault"] as? [String: Any])
        var accounts = try #require(rawVault["financialInstitutions"] as? [[String: Any]])
        // Schema 3 stores the version on the institution itself.
        accounts[0]["schemaVersion"] = 999
        accounts[0]["unknownFutureValue"] = ["storedFileName": "protected.pdf"]
        rawVault["financialInstitutions"] = accounts
        rawVault["futureModule"] = ["amount": 12345, "note": "retain unknown module"]
        json["vault"] = rawVault
        let raw = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let encrypted = try VaultCrypto.encrypt(raw, using: key.key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encrypted.write(to: url)

        let loaded = store.loadVaultWithMetrics()
        #expect(loaded.canPersist)
        #expect(loaded.vault.unavailableModules == ["personalFinance"])
        #expect(loaded.vault.medicalRecords.first?.hospital == "healthy records")
        #expect(try Data(contentsOf: url) == encrypted)
        #expect(loaded.vault.opaqueAttachmentStoredFileNames.contains("protected.pdf"))
        var edited = loaded.vault
        edited.medicalRecords[0].hospital = "edited safely"
        // Even an accidental mutation of the unavailable typed projection must not overwrite it.
        edited.financialInstitutions = []
        try store.saveVault(edited, secrets: loaded.secrets)
        let reloaded = store.loadVaultWithMetrics()
        #expect(reloaded.vault.medicalRecords.first?.hospital == "edited safely")
        #expect(reloaded.vault.unavailableModules == ["personalFinance"])
        #expect(reloaded.vault.preservedModulePayloads == loaded.vault.preservedModulePayloads)
        #expect(reloaded.vault.unknownPayloads == loaded.vault.unknownPayloads)
        let snapshot = try CloudSyncSnapshotBuilder.make(vault: reloaded.vault, secrets: [], attachmentStore: AttachmentStore())
        #expect(!snapshot.participatingModules.contains(.personalFinance))
        #expect(snapshot.participatingModules.contains(.healthRecords))
        let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "snapshot" }
        #expect(!backups.isEmpty)
        #expect(try backups.contains { try VaultCrypto.decrypt(Data(contentsOf: $0), using: key.key) == raw })
    }

    @Test func malformedSecretsDoNotBlockOtherModulesAndArePreservedOnSave() throws {
        let key = FixedVaultEncryptionKey()
        let (store, url, _) = makeStore(keyProvider: key)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlainVaultFixture(vault: sampleVault(marker: "safe"), secrets: []))) as? [String: Any])
        json["secrets"] = ["unsupported": ["storedFileName": "secret.pdf"]]
        let original = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultCrypto.encrypt(original, using: key.key).write(to: url)
        let loaded = store.loadVaultWithMetrics()
        #expect(loaded.canPersist)
        #expect(loaded.vault.unavailableModules == ["secrets"])
        #expect(loaded.vault.medicalRecords.first?.hospital == "safe")
        try store.saveVault(loaded.vault, secrets: [])
        let reloaded = store.loadVaultWithMetrics()
        #expect(reloaded.vault.preservedSecrets == loaded.vault.preservedSecrets)
        #expect(reloaded.vault.preservedModulePayloads == loaded.vault.preservedModulePayloads)
        #expect(reloaded.vault.opaqueAttachmentStoredFileNames.contains("secret.pdf"))
    }

    @Test func strictBackupDecodeStillRejectsBrokenModuleAndLocalDecodeIsolatesEachGroup() throws {
        let raw = Data(#"{"accounts":"bad-finance","stocks":"bad-stocks","billTags":["keep"]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VaultData.self, from: raw) }
        let decoder = JSONDecoder()
        decoder.userInfo[.isolateVaultModules] = true
        let vault = try decoder.decode(VaultData.self, from: raw)
        #expect(vault.unavailableModules == ["personalFinance", "myStocks"])
        #expect(vault.billTags == ["keep"])
        let roundTrip = try decoder.decode(VaultData.self, from: JSONEncoder().encode(vault))
        #expect(roundTrip.preservedModulePayloads == vault.preservedModulePayloads)
        #expect(roundTrip.unavailableModules == vault.unavailableModules)
    }

    @Test func restoreSaveKeepsEncryptedCopyOfReplacedVault() throws {
        // AUDIT-003: backup import replaces whole modules, so the previous file is kept first.
        let key = FixedVaultEncryptionKey()
        let (store, url, _) = makeStore(keyProvider: key)
        try store.saveVault(sampleVault(marker: "before restore"))
        let original = try Data(contentsOf: url)
        let coordinator = VaultPersistenceCoordinator(secureStore: store)

        try coordinator.saveImmediately(sampleVault(marker: "after restore"), secrets: [], preservingOriginal: true)

        #expect(store.loadVaultWithMetrics().vault.medicalRecords.first?.hospital == "after restore")
        let snapshots = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pre-restore-") }
        #expect(try snapshots.map { try Data(contentsOf: $0) } == [original])
    }

    @Test func attachmentStoredFileNameCannotEscapeAttachmentDirectory() throws {
        // AUDIT-004: storedFileName arrives from backups and CloudKit and must stay a bare name.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentPathTests-\(UUID().uuidString)", isDirectory: true)
        let attachmentsURL = root.appendingPathComponent("Attachments", isDirectory: true)
        let victimURL = root.appendingPathComponent("local-vault.json")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: victimURL)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directoryURL: attachmentsURL)

        for name in ["../local-vault.json", "a/b.pdf", "..", ".hidden", "", "x\\y"] {
            var attachment = FileAttachment()
            attachment.storedFileName = name
            #expect(throws: AttachmentStoreError.self) { try store.write(Data("x".utf8), to: attachment) }
            #expect(throws: AttachmentStoreError.self) { try store.data(for: attachment) }
            store.delete(attachment)
            #expect(store.url(for: attachment).deletingLastPathComponent().standardizedFileURL.path
                == attachmentsURL.standardizedFileURL.path)
        }
        #expect(try Data(contentsOf: victimURL) == Data("vault".utf8))

        var legacy = FileAttachment()
        legacy.storedFileName = "体检报告 2025.pdf"
        try store.write(Data("ok".utf8), to: legacy)
        #expect(try store.data(for: legacy) == Data("ok".utf8))
    }

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
        var record = MedicalRecord()
        record.hospital = marker
        return VaultData(medicalRecords: [record])
    }

    @Test func vaultEnvelopeBindsVersionAndStillOpensLegacyEnvelope() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let payload = Data("payload".utf8)
        let current = try VaultCrypto.encrypt(payload, using: key)
        var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        #expect(object["version"] as? String == "2.1")
        #expect(try VaultCrypto.decrypt(current, using: key) == payload)

        // Rewriting the header to the legacy version must not bypass the AAD check.
        object["version"] = "2.0"
        let downgraded = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: VaultCryptoError.authenticationFailed) {
            try VaultCrypto.decrypt(downgraded, using: key)
        }

        // A genuine 2.0 envelope (no AAD) still decrypts.
        let combined = try #require(try AES.GCM.seal(payload, using: key).combined)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "format": "mytools-vault", "version": "2.0", "combined": combined.base64EncodedString(),
        ])
        #expect(try VaultCrypto.decrypt(legacy, using: key) == payload)
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
        #expect(result.vault.medicalRecords.first?.hospital == marker)
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
        #expect(result.vault.medicalRecords.first?.hospital == marker)

        let migratedRaw = try Data(contentsOf: vaultURL)
        #expect(VaultCrypto.isEncryptedEnvelope(migratedRaw))
        #expect(String(data: migratedRaw, encoding: .utf8)?.contains(marker) != true)
        // AUDIT-031：替换前留有加密的迁移前快照。
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: vaultURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("pre-encryption-") && $0.hasSuffix(".snapshot") }
        #expect(snapshots.count == 1)

        let reloaded = store.loadVaultWithMetrics()
        #expect(reloaded.canPersist)
        #expect(reloaded.source.contains("已加密"))
        #expect(reloaded.vault.medicalRecords.first?.hospital == marker)
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
        #expect(result.vault.medicalRecords.isEmpty)
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
        #expect(loadResult.vault.medicalRecords.first?.hospital == marker)

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
        #expect(!result.vault.medicalRecords.isEmpty)
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
        #expect(result.vault.medicalRecords.first?.hospital == "自动重试写入")
        #expect(VaultCrypto.isEncryptedEnvelope(try Data(contentsOf: vaultURL)))
    }
}
