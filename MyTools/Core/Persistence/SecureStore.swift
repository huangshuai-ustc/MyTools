import Foundation
import CryptoKit
import OSLog

enum LocalVaultLoadFailure: Equatable, Sendable {
    case protectedDataUnavailable
    case unrecoverable
}

struct LocalVaultLoadResult: @unchecked Sendable {
    let vault: VaultData
    let secrets: [SecretVaultValue]
    let byteCount: Int
    let source: String
    let canPersist: Bool
    let readMilliseconds: Double
    let decodeMilliseconds: Double
    let totalMilliseconds: Double
    let failure: LocalVaultLoadFailure?

    init(
        vault: VaultData,
        secrets: [SecretVaultValue],
        byteCount: Int,
        source: String,
        canPersist: Bool,
        readMilliseconds: Double,
        decodeMilliseconds: Double,
        totalMilliseconds: Double,
        failure: LocalVaultLoadFailure? = nil
    ) {
        self.vault = vault
        self.secrets = secrets
        self.byteCount = byteCount
        self.source = source
        self.canPersist = canPersist
        self.readMilliseconds = readMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.failure = failure
    }
}

private struct LocalVaultDocument: Codable {
    let schemaVersion: Int
    var vault: VaultData
    let secrets: [SecretVaultValue]

    init(vault: VaultData, secrets: [SecretVaultValue]) {
        schemaVersion = 2
        self.vault = vault
        self.secrets = secrets
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, vault, secrets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...2).contains(schemaVersion) else { throw VaultReadError.unsupportedVersion }
        vault = try c.decode(VaultData.self, forKey: .vault)
        do {
            secrets = try c.decode([SecretVaultValue].self, forKey: .secrets)
        } catch {
            guard decoder.userInfo[.isolateVaultModules] as? Bool == true else { throw error }
            vault.unavailableModules.insert("secrets")
            secrets = []
        }
        if vault.unavailableModules.contains("secrets"), c.contains(.secrets) {
            vault.preservedSecrets = try c.decode(OpaqueModuleValue.self, forKey: .secrets)
        }
        if vault.unavailableModules.contains("secrets"),
           case .object(let rawVault) = try c.decode(OpaqueModuleValue.self, forKey: .vault) {
            for key in ["secretTags", "secretFieldTemplates"] {
                vault.preservedModulePayloads[key] = rawVault[key]
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(vault, forKey: .vault)
        if let raw = vault.preservedSecrets { try c.encode(raw, forKey: .secrets) }
        else if !vault.unavailableModules.contains("secrets") { try c.encode(secrets, forKey: .secrets) }
    }
}

private enum VaultReadError: LocalizedError {
    case keyTemporarilyUnavailable(OSStatus)
    case keyUnavailable
    case authenticationFailed
    case unsupportedVersion
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .keyTemporarilyUnavailable:
            return "设备受保护数据暂不可用，解锁后将自动重试"
        case .keyUnavailable:
            return "本地存档已加密但加密密钥不可用，原文件已保留"
        case .authenticationFailed:
            return "本地存档解密失败（密钥不匹配或内容被篡改），原文件已保留"
        case .unsupportedVersion:
            return "本地存档加密格式版本不受支持，原文件已保留"
        case .invalidPayload:
            return "本地存档解密后内容无效，原文件已保留"
        }
    }
}

final class SecureStore {
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private let keyProvider: any VaultEncryptionKeyProviding

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        keyProvider: any VaultEncryptionKeyProviding = KeychainVaultEncryptionKey()
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.keyProvider = keyProvider
    }

    private var localVaultDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("MyTools", isDirectory: true)
    }

    private var localVaultURL: URL {
        localVaultDirectory.appendingPathComponent("local-vault.json", isDirectory: false)
    }

    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        let totalStartedAt = ProcessInfo.processInfo.systemUptime
        var readMilliseconds = 0.0
        var decodeMilliseconds = 0.0

        if fileManager.fileExists(atPath: localVaultURL.path) {
            do {
                let readStartedAt = ProcessInfo.processInfo.systemUptime
                // The vault is small and decoded immediately. A direct read avoids the extra
                // mapping setup and first-page faults seen on cold launches on physical devices.
                let data = try Data(contentsOf: localVaultURL)
                readMilliseconds += elapsedMilliseconds(since: readStartedAt)

                let decodeStartedAt = ProcessInfo.processInfo.systemUptime
                let document = try decodeDocument(from: data)
#if MYTOOLS_FEATURE_FINANCE
                if !document.vault.unavailableModules.contains("personalFinance"),
                   try requiresPaymentSchemaMigration(data) {
                    // Do not expose migrated data to CloudKit until staging, validation,
                    // recovery snapshot and atomic replacement have all succeeded.
                    let migrated = try JSONEncoder().encode(LocalVaultDocument(vault: document.vault, secrets: document.secrets))
                    try writeVaultFile(migrated)
                }
#endif
                if document.schemaVersion < 2 || !document.vault.unavailableModules.isEmpty {
                    try preserveRecoverySnapshot(data, vault: document.vault)
                }
                decodeMilliseconds += elapsedMilliseconds(since: decodeStartedAt)

                return loadResult(
                    vault: document.vault,
                    secrets: document.secrets,
                    byteCount: data.count,
                    source: document.source,
                    canPersist: true,
                    readMilliseconds: readMilliseconds,
                    decodeMilliseconds: decodeMilliseconds,
                    totalStartedAt: totalStartedAt
                )
            } catch {
                return failedLoadResult(
                    error: error,
                    readMilliseconds: readMilliseconds,
                    decodeMilliseconds: decodeMilliseconds,
                    totalStartedAt: totalStartedAt
                )
            }
        }

        return loadResult(
            vault: VaultData(),
            secrets: [],
            byteCount: 0,
            source: "空档案",
            canPersist: true,
            readMilliseconds: readMilliseconds,
            decodeMilliseconds: decodeMilliseconds,
            totalStartedAt: totalStartedAt
        )
    }

    /// `preservingOriginal` keeps an encrypted copy of the file being replaced
    /// (used by backup import, which replaces whole modules).
    func saveVault(_ vault: VaultData, secrets: [SecretVaultValue] = [], preservingOriginal: Bool = false) throws {
#if MYTOOLS_FEATURE_FINANCE
        if !vault.unavailableModules.contains("personalFinance") {
            for institution in vault.financialInstitutions { try institution.validate() }
        }
#endif
        let document = LocalVaultDocument(vault: vault, secrets: secrets)
        let payload = try JSONEncoder().encode(document)
        if preservingOriginal, fileManager.fileExists(atPath: localVaultURL.path) {
            try preserveRecoverySnapshot(Data(contentsOf: localVaultURL), vault: VaultData(), prefix: "pre-restore", requireSnapshot: true)
        }
        try writeVaultFile(payload)
    }

    // MARK: - Decode and migration

    private struct DecodedVaultDocument {
        let vault: VaultData
        let secrets: [SecretVaultValue]
        let source: String
        let schemaVersion: Int
    }

    private func decodeDocument(from data: Data) throws -> DecodedVaultDocument {
        let decoder = JSONDecoder()
        decoder.userInfo[.isolateVaultModules] = true
        if VaultCrypto.isEncryptedEnvelope(data) {
            let key: SymmetricKey
            do {
                guard let loadedKey = try keyProvider.loadKey() else {
                    throw VaultReadError.keyUnavailable
                }
                key = loadedKey
            } catch let error as VaultEncryptionKeyError where error.isTemporarilyUnavailable {
                DiagnosticLogger.shared.log(
                    .persistence,
                    "设备受保护数据暂不可用，等待解锁后重试 status=\(error.status)",
                    level: .warning
                )
                throw VaultReadError.keyTemporarilyUnavailable(error.status)
            } catch {
                DiagnosticLogger.shared.log(
                    .persistence,
                    "本地存档已加密但加密密钥不可用，原文件已保留",
                    level: .error
                )
                throw VaultReadError.keyUnavailable
            }
            let payload: Data
            do {
                payload = try VaultCrypto.decrypt(data, using: key)
            } catch VaultCryptoError.unsupportedVersion {
                throw VaultReadError.unsupportedVersion
            } catch {
                throw VaultReadError.authenticationFailed
            }
            do {
                let document = try decoder.decode(LocalVaultDocument.self, from: payload)
                return DecodedVaultDocument(
                    vault: document.vault,
                    secrets: document.secrets,
                    source: "Application Support（已加密）",
                    schemaVersion: document.schemaVersion
                )
            } catch {
                throw VaultReadError.invalidPayload
            }
        }

        // 旧版明文格式：正常解码，并尽可能立即升级为加密信封（先留加密副本，再安全替换）。
        let document = try decoder.decode(LocalVaultDocument.self, from: data)
        if document.vault.unavailableModules.isEmpty, let migratedSource = migratePlaintextToEncryption(data) {
            return DecodedVaultDocument(
                vault: document.vault,
                secrets: document.secrets,
                source: migratedSource,
                schemaVersion: document.schemaVersion
            )
        }
        return DecodedVaultDocument(
            vault: document.vault,
            secrets: document.secrets,
            source: "Application Support（未加密）",
            schemaVersion: document.schemaVersion
        )
    }

    /// 把已读入的明文档案升级为加密信封。先生成加密的恢复快照，再走常规的
    /// “临时文件 → 解密回读比对 → 替换”写入（AUDIT-031）。失败时返回 nil，
    /// 继续以明文运行，下一次保存会再次尝试加密，不会因为升级失败而丢失数据。
    private func migratePlaintextToEncryption(_ plaintext: Data) -> String? {
        do {
            if try keyProvider.loadKey() == nil {
                _ = try keyProvider.createAndStoreKey()
            }
            try preserveRecoverySnapshot(plaintext, vault: VaultData(), prefix: "pre-encryption", requireSnapshot: true)
            try writeVaultFile(plaintext)
            return "Application Support（已升级加密）"
        } catch {
            DiagnosticLogger.shared.log(
                .persistence,
                "本地存档加密升级未完成，仍以明文运行 error=\(DiagnosticLogger.errorCode(error))",
                level: .warning
            )
            return nil
        }
    }

    // MARK: - Write

    /// Keep the exact pre-upgrade/quarantined document, encrypted at rest. A content
    /// hash avoids another whole-vault snapshot on each launch of the same file.
    private func preserveRecoverySnapshot(
        _ original: Data,
        vault: VaultData,
        prefix: String = "recovery",
        requireSnapshot: Bool = false
    ) throws {
        var identity = original
        if !vault.unavailableModules.isEmpty {
            var quarantined = vault.preservedModulePayloads
            quarantined["$secrets"] = vault.preservedSecrets
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            identity = try encoder.encode(quarantined)
        }
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let url = localVaultDirectory.appendingPathComponent("\(prefix)-\(digest).snapshot")
        guard !fileManager.fileExists(atPath: url.path) else { return }
        let bytes: Data
        if VaultCrypto.isEncryptedEnvelope(original) { bytes = original }
        else {
            // A plaintext document remains readable when Keychain is unavailable;
            // saveVault still refuses to write without an encryption key.
            guard let key = try? keyProvider.loadKey() else {
                if requireSnapshot { throw VaultCryptoError.keyDerivationFailed }
                return
            }
            bytes = try VaultCrypto.encrypt(original, using: key)
        }
        try bytes.write(to: url, options: .atomic)
#if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
    }

#if MYTOOLS_FEATURE_FINANCE
    private func requiresPaymentSchemaMigration(_ original: Data) throws -> Bool {
        let payload: Data
        if VaultCrypto.isEncryptedEnvelope(original) {
            guard let key = try keyProvider.loadKey() else { throw VaultReadError.keyUnavailable }
            payload = try VaultCrypto.decrypt(original, using: key)
        } else { payload = original }
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let vault = json?["vault"] as? [String: Any]
        let institutions = vault?["financialInstitutions"] as? [[String: Any]] ?? []
        return institutions.contains { ($0["kind"] as? String) == "payment" && ($0["schemaVersion"] as? Int ?? 1) < FinancialInstitution.currentSchemaVersion }
    }
#endif

    private func writeVaultFile(_ payload: Data) throws {
        let key: SymmetricKey
        if let existing = try keyProvider.loadKey() {
            key = existing
        } else {
            key = try keyProvider.createAndStoreKey()
        }
        let dataToWrite = try VaultCrypto.encrypt(payload, using: key)
        try fileManager.createDirectory(
            at: localVaultDirectory,
            withIntermediateDirectories: true
        )
        let staging = localVaultDirectory.appendingPathComponent("vault-write-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        try dataToWrite.write(to: staging, options: .atomic)
        let stagedPayload = try VaultCrypto.decrypt(Data(contentsOf: staging), using: key)
        guard stagedPayload == payload else { throw VaultReadError.invalidPayload }
#if MYTOOLS_FEATURE_FINANCE
        // Inspect the original bytes, not the already-normalized in-memory schema.
        // Snapshot only a real payment-schema upgrade, after staging has been verified.
        if fileManager.fileExists(atPath: localVaultURL.path) {
            let original = try Data(contentsOf: localVaultURL)
            if try requiresPaymentSchemaMigration(original) {
                let decoder = JSONDecoder()
                decoder.userInfo[.isolateVaultModules] = true
                let verified = try decoder.decode(LocalVaultDocument.self, from: stagedPayload)
                if !verified.vault.unavailableModules.contains("personalFinance") {
                    for institution in verified.vault.financialInstitutions { try institution.validate() }
                    try preserveRecoverySnapshot(original, vault: VaultData(), prefix: "pre-finance-v4", requireSnapshot: true)
                }
            }
        }
#endif
#if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
#endif
        if fileManager.fileExists(atPath: localVaultURL.path) {
            _ = try fileManager.replaceItemAt(localVaultURL, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: localVaultURL)
        }
        applyFileProtectionIfNeeded()
    }

    private func applyFileProtectionIfNeeded() {
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: localVaultURL.path
        )
#endif
    }

    // MARK: - Failure handling

    private func failedLoadResult(
        error: Error,
        readMilliseconds: Double,
        decodeMilliseconds: Double,
        totalStartedAt: TimeInterval
    ) -> LocalVaultLoadResult {
        let failure: LocalVaultLoadFailure
        let source: String
        if case .keyTemporarilyUnavailable = error as? VaultReadError {
            failure = .protectedDataUnavailable
            source = "等待设备解锁后重试"
            logTemporaryLoadDelay(error)
        } else {
            failure = .unrecoverable
            source = "存档读取失败（原文件已保留）"
            logLoadFailure("本地存档读取或解码失败，已禁止空档案覆盖", error: error)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: localVaultURL.path)
        return loadResult(
            vault: VaultData(),
            secrets: [],
            byteCount: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
            source: source,
            canPersist: false,
            failure: failure,
            readMilliseconds: readMilliseconds,
            decodeMilliseconds: decodeMilliseconds,
            totalStartedAt: totalStartedAt
        )
    }

    private func logTemporaryLoadDelay(_ error: Error) {
        let code = DiagnosticLogger.errorCode(error)
        persistenceLogger.info("Protected local vault data is temporarily unavailable: \(code, privacy: .public)")
        DiagnosticLogger.shared.log(
            .persistence,
            "本地存档暂不可读，等待受保护数据可用后自动重试 error=\(code)",
            level: .warning
        )
    }

    private func logLoadFailure(_ message: String, error: Error) {
        let code = DiagnosticLogger.errorCode(error)
        persistenceLogger.error("\(message, privacy: .public): \(code, privacy: .public)")
        DiagnosticLogger.shared.log(
            .persistence,
            "\(message) error=\(code)",
            level: .error
        )
    }

    private func loadResult(
        vault: VaultData,
        secrets: [SecretVaultValue],
        byteCount: Int,
        source: String,
        canPersist: Bool,
        failure: LocalVaultLoadFailure? = nil,
        readMilliseconds: Double,
        decodeMilliseconds: Double,
        totalStartedAt: TimeInterval
    ) -> LocalVaultLoadResult {
        LocalVaultLoadResult(
            vault: vault,
            secrets: secrets,
            byteCount: byteCount,
            source: source,
            canPersist: canPersist,
            readMilliseconds: readMilliseconds,
            decodeMilliseconds: decodeMilliseconds,
            totalMilliseconds: elapsedMilliseconds(since: totalStartedAt),
            failure: failure
        )
    }

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    }
}

private let persistenceLogger = Logger(
    subsystem: AppMetadata.bundleIdentifier,
    category: "Persistence"
)

/// Serializes full-vault writes away from the UI thread and coalesces bursts of edits.
final class VaultPersistenceCoordinator: @unchecked Sendable {
    private struct PendingWrite: @unchecked Sendable {
        let vault: VaultData
        let secrets: [SecretVaultValue]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "\(AppMetadata.bundleIdentifier).vault-persistence",
        qos: .utility
    )
    private let secureStore: SecureStore
    private var pendingWrite: PendingWrite?
    private var isWorkerScheduled = false
    private var lastErrorCode: String?
    private let initialTemporaryRetryDelay: TimeInterval
    private var temporaryRetryDelay: TimeInterval
    private var didLogTemporaryKeyFailure = false

    init(
        secureStore: SecureStore = SecureStore(),
        temporaryRetryDelay: TimeInterval = 1
    ) {
        self.secureStore = secureStore
        let normalizedRetryDelay = max(temporaryRetryDelay, 0.01)
        initialTemporaryRetryDelay = normalizedRetryDelay
        self.temporaryRetryDelay = normalizedRetryDelay
    }

    func schedule(_ vault: VaultData, secrets: [SecretVaultValue] = []) {
        lock.lock()
        pendingWrite = PendingWrite(vault: vault, secrets: secrets)
        let shouldScheduleWorker = !isWorkerScheduled
        isWorkerScheduled = true
        lock.unlock()

        guard shouldScheduleWorker else { return }
        queue.async { [self] in
            drainPendingWrites()
        }
    }

    /// Used by restore operations that must report a write failure before replacing live data.
    func saveImmediately(_ vault: VaultData, secrets: [SecretVaultValue] = [], preservingOriginal: Bool) throws {
        let result: Result<Void, Error> = queue.sync {
            lock.lock()
            pendingWrite = nil
            lastErrorCode = nil
            lock.unlock()
            let result = Result { try secureStore.saveVault(vault, secrets: secrets, preservingOriginal: preservingOriginal) }
            lock.lock()
            pendingWrite = nil
            if case .success = result {
                lastErrorCode = nil
            }
            lock.unlock()
            return result
        }
        try result.get()
    }

    func flush() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.lock.lock()
                let errorCode = self.lastErrorCode ?? (self.pendingWrite == nil ? nil : "VaultWritePending")
                self.lock.unlock()
                continuation.resume(returning: errorCode)
            }
        }
    }

    private func drainPendingWrites() {
        while true {
            lock.lock()
            guard let write = pendingWrite else {
                isWorkerScheduled = false
                lock.unlock()
                return
            }
            pendingWrite = nil
            lock.unlock()

            do {
                try secureStore.saveVault(write.vault, secrets: write.secrets)
                lock.lock()
                lastErrorCode = nil
                lock.unlock()
                temporaryRetryDelay = initialTemporaryRetryDelay
                didLogTemporaryKeyFailure = false
            } catch {
                if isTemporaryVaultKeyAccessError(error) {
                    lock.lock()
                    if pendingWrite == nil {
                        pendingWrite = write
                    }
                    isWorkerScheduled = false
                    lock.unlock()

                    if !didLogTemporaryKeyFailure {
                        didLogTemporaryKeyFailure = true
                        DiagnosticLogger.shared.logOncePerSession(
                            "vault-write-key-locked", .persistence,
                            "本地加密密钥暂不可用，待解锁后重试加密写入"
                        )
                    }
                    let delay = temporaryRetryDelay
                    temporaryRetryDelay = min(temporaryRetryDelay * 2, 30)
                    queue.asyncAfter(deadline: .now() + delay) { [self] in
                        resumeWorkerIfNeeded()
                    }
                    return
                }
                let errorCode = DiagnosticLogger.errorCode(error)
                lock.lock()
                lastErrorCode = errorCode
                lock.unlock()
                persistenceLogger.error(
                    "Unable to persist local vault: \(errorCode, privacy: .public)"
                )
                DiagnosticLogger.shared.log(
                    .persistence,
                    "本地存档写入失败 error=\(errorCode)",
                    level: .error
                )
            }
        }
    }

    private func resumeWorkerIfNeeded() {
        lock.lock()
        guard pendingWrite != nil, !isWorkerScheduled else {
            lock.unlock()
            return
        }
        isWorkerScheduled = true
        lock.unlock()
        drainPendingWrites()
    }
}
