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
    let vault: VaultData
    let secrets: [SecretVaultValue]

    init(vault: VaultData, secrets: [SecretVaultValue]) {
        self.vault = vault
        self.secrets = secrets
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

    func saveVault(_ vault: VaultData, secrets: [SecretVaultValue] = []) throws {
        let document = LocalVaultDocument(vault: vault, secrets: secrets)
        let payload = try JSONEncoder().encode(document)
        try writeVaultFile(payload)
    }

    // MARK: - Decode and migration

    private struct DecodedVaultDocument {
        let vault: VaultData
        let secrets: [SecretVaultValue]
        let source: String
    }

    private func decodeDocument(from data: Data) throws -> DecodedVaultDocument {
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
                let document = try JSONDecoder().decode(LocalVaultDocument.self, from: payload)
                return DecodedVaultDocument(
                    vault: document.vault,
                    secrets: document.secrets,
                    source: "Application Support（已加密）"
                )
            } catch {
                throw VaultReadError.invalidPayload
            }
        }

        // 旧版明文格式：正常解码，并尽可能立即原地升级为加密信封。
        let document = try JSONDecoder().decode(LocalVaultDocument.self, from: data)
        if let migratedSource = migratePlaintextToEncryption(data) {
            return DecodedVaultDocument(
                vault: document.vault,
                secrets: document.secrets,
                source: migratedSource
            )
        }
        return DecodedVaultDocument(
            vault: document.vault,
            secrets: document.secrets,
            source: "Application Support（未加密）"
        )
    }

    /// 把已读入的明文档案原地升级为加密信封。失败时返回 nil，继续以明文运行，
    /// 下一次保存会再次尝试加密，不会因为升级失败而丢失数据。
    private func migratePlaintextToEncryption(_ plaintext: Data) -> String? {
        do {
            let key: SymmetricKey
            if let existing = try keyProvider.loadKey() {
                key = existing
            } else {
                key = try keyProvider.createAndStoreKey()
            }
            let encrypted = try VaultCrypto.encrypt(plaintext, using: key)
            try encrypted.write(to: localVaultURL, options: .atomic)
            applyFileProtectionIfNeeded()
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
        try dataToWrite.write(to: localVaultURL, options: .atomic)
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
    func saveImmediately(_ vault: VaultData, secrets: [SecretVaultValue] = []) throws {
        let result: Result<Void, Error> = queue.sync {
            lock.lock()
            pendingWrite = nil
            lastErrorCode = nil
            lock.unlock()
            let result = Result { try secureStore.saveVault(vault, secrets: secrets) }
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
                let errorCode = self.lastErrorCode
                self.lastErrorCode = nil
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
                        DiagnosticLogger.shared.log(
                            .persistence,
                            "本地加密密钥暂不可用，待解锁后重试加密写入",
                            level: .warning
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
