import Foundation
import OSLog

struct LocalVaultLoadResult: @unchecked Sendable {
    let vault: VaultData
    let secrets: [SecretItem]
    let byteCount: Int
    let source: String
    let canPersist: Bool
    let readMilliseconds: Double
    let decodeMilliseconds: Double
    let totalMilliseconds: Double
}

private struct LocalVaultDocument: Codable {
    let vault: VaultData
    let secrets: [SecretItem]

    init(vault: VaultData, secrets: [SecretItem]) {
        self.vault = vault
        self.secrets = secrets
    }
}

final class SecureStore {
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
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
                let document = try JSONDecoder().decode(LocalVaultDocument.self, from: data)
                decodeMilliseconds += elapsedMilliseconds(since: decodeStartedAt)

                return loadResult(
                    vault: document.vault,
                    secrets: document.secrets,
                    byteCount: data.count,
                    source: "Application Support",
                    canPersist: true,
                    readMilliseconds: readMilliseconds,
                    decodeMilliseconds: decodeMilliseconds,
                    totalStartedAt: totalStartedAt
                )
            } catch {
                logLoadFailure("本地存档读取或解码失败，已禁止空档案覆盖", error: error)
                let attributes = try? fileManager.attributesOfItem(atPath: localVaultURL.path)
                return loadResult(
                    vault: VaultData(),
                    secrets: [],
                    byteCount: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                    source: "存档读取失败（原文件已保留）",
                    canPersist: false,
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

    func saveVault(_ vault: VaultData, secrets: [SecretItem] = []) throws {
        try writeVaultFile(LocalVaultDocument(vault: vault, secrets: secrets))
    }

    private func writeVaultFile(_ document: LocalVaultDocument) throws {
        let payload = try JSONEncoder().encode(document)
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
        secrets: [SecretItem],
        byteCount: Int,
        source: String,
        canPersist: Bool,
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
            totalMilliseconds: elapsedMilliseconds(since: totalStartedAt)
        )
    }

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    }

}

private let persistenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.fjwyz.PersonalToolBox",
    category: "Persistence"
)

/// Serializes full-vault writes away from the UI thread and coalesces bursts of edits.
final class VaultPersistenceCoordinator: @unchecked Sendable {
    private struct PendingWrite: @unchecked Sendable {
        let vault: VaultData
        let secrets: [SecretItem]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.fjwyz.PersonalToolBox.vault-persistence",
        qos: .utility
    )
    private let secureStore: SecureStore
    private var pendingWrite: PendingWrite?
    private var isWorkerScheduled = false
    private var lastErrorCode: String?

    init(secureStore: SecureStore = SecureStore()) {
        self.secureStore = secureStore
    }

    func schedule(_ vault: VaultData, secrets: [SecretItem] = []) {
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
    func saveImmediately(_ vault: VaultData, secrets: [SecretItem] = []) throws {
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
            } catch {
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
}
