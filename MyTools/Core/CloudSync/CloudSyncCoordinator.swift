import Foundation
#if os(macOS)
import Security
#endif

enum CloudKitAvailability {
    static func isSupported(containerIdentifier: String) -> Bool {
        guard !containerIdentifier.isEmpty else { return false }
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ) as? [String] else {
            return false
        }
        return identifiers.contains(containerIdentifier)
#elseif targetEnvironment(simulator)
        // Simulator builds do not carry the production iCloud container
        // entitlement and must not construct CKContainer either.
        return false
#else
        // iOS/iPadOS builds are signed with the CloudKit entitlement from the
        // target's entitlements file. SecTask is not imported by the iOS Swift
        // Security module, so the XCTest environment check remains the caller's
        // guard for unsigned test processes.
        return true
#endif
    }
}

enum CloudSyncStatus: Equatable, Sendable {
    case disabled
    case checkingAccount
    case syncing
    case rebuildInProgress
    case synced(Date)
    case noAccount
    case restricted
    case temporarilyUnavailable
    case accountChanged
    case cloudDataRemoved
    case error(String)

    var title: String {
        switch self {
        case .disabled: return "已关闭"
        case .checkingAccount: return "正在检查 iCloud"
        case .syncing: return "正在同步"
        case .rebuildInProgress: return "另一台设备正在重建 iCloud"
        case .synced: return "已同步"
        case .noAccount: return "未登录 iCloud"
        case .restricted: return "iCloud 访问受限"
        case .temporarilyUnavailable: return "iCloud 暂时不可用"
        case .accountChanged: return "iCloud 账户已变化"
        case .cloudDataRemoved: return "云端数据已移除"
        case .error: return "同步失败"
        }
    }

    var isBusy: Bool {
        switch self {
        case .checkingAccount, .syncing, .rebuildInProgress: true
        default: false
        }
    }
}

typealias CloudSyncSnapshotProvider = @MainActor @Sendable () async throws -> CloudSyncSnapshot
typealias CloudSyncChangeHandler = @MainActor @Sendable ([CloudSyncChange]) throws -> Void

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: CloudSyncStatus
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var isRebuildingCloudData = false

    private enum DefaultsKey {
        static let enabled = "icloud-sync-enabled-v1"
        static let lastSuccessfulSyncAt = "icloud-sync-last-success-v1"
    }

    private static let localChangeDebounce: Duration = .seconds(2)

    private let defaults: UserDefaults
    private let attachmentStore: AttachmentStore
    private let containerIdentifier: String
    private let isSupported: Bool
    private var snapshotProvider: CloudSyncSnapshotProvider?
    private var changeHandler: CloudSyncChangeHandler?
    private var worker: CloudKitSyncWorker?
    private var operationTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var rebuildRetryTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var hasLoadedLocalData = false

    init(
        defaults: UserDefaults,
        attachmentStore: AttachmentStore,
        containerIdentifier: String,
        isSupported: Bool = true
    ) {
        self.defaults = defaults
        self.attachmentStore = attachmentStore
        self.containerIdentifier = containerIdentifier
        self.isSupported = isSupported
        let enabled = isSupported && defaults.bool(forKey: DefaultsKey.enabled)
        isEnabled = enabled
        lastSuccessfulSyncAt = defaults.object(forKey: DefaultsKey.lastSuccessfulSyncAt) as? Date
        status = enabled ? .checkingAccount : .disabled
    }

    static func disabled(
        defaults: UserDefaults,
        attachmentStore: AttachmentStore
    ) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            defaults: defaults,
            attachmentStore: attachmentStore,
            containerIdentifier: "",
            isSupported: false
        )
    }

    func attach(
        snapshotProvider: @escaping CloudSyncSnapshotProvider,
        changeHandler: @escaping CloudSyncChangeHandler
    ) {
        self.snapshotProvider = snapshotProvider
        self.changeHandler = changeHandler
        startIfPossible()
    }

    func localDataDidLoad() {
        hasLoadedLocalData = true
        startIfPossible()
    }

    func localDataDidChange() {
        guard isEnabled, worker != nil else { return }
        scheduleReconciliation(delay: Self.localChangeDebounce)
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported, enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.enabled)

        guard enabled else {
            status = .disabled
            operationTask?.cancel()
            operationTask = nil
            reconciliationTask?.cancel()
            reconciliationTask = nil
            rebuildRetryTask?.cancel()
            rebuildRetryTask = nil
            activeOperationID = nil
            let previousWorker = worker
            worker = nil
            Task { await previousWorker?.stop() }
            return
        }

        status = .checkingAccount
        startIfPossible()
    }

    func synchronizeNow() {
        guard activeOperationID == nil,
              let worker = prepareWorkerIfPossible() else { return }
        reconciliationTask?.cancel()
        reconciliationTask = nil
        let operationID = UUID()
        activeOperationID = operationID
        operationTask = Task { [weak self] in
            await worker.synchronize()
            self?.operationDidFinish(operationID)
        }
    }

    func rebuildCloudData() {
        guard canRebuildCloudData,
              let currentWorker = prepareWorkerIfPossible() else { return }
        reconciliationTask?.cancel()
        reconciliationTask = nil

        let operationID = UUID()
        activeOperationID = operationID
        isRebuildingCloudData = true
        status = .syncing
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Refuse to delete the remote zone unless the current local
                // source of truth can be encoded successfully first.
                _ = try await self.makeSnapshot()
                let lease = try await currentWorker.deleteRemoteZoneForRebuild()
                guard !Task.isCancelled, self.isEnabled else {
                    self.finishCloudDataRebuild(operationID)
                    return
                }

                self.worker = nil
                guard let replacementWorker = self.prepareWorkerIfPossible(
                    rebuildLease: lease
                ) else {
                    await currentWorker.abortRebuildLease(lease)
                    throw CloudDataRebuildError.unableToRestart
                }
                await replacementWorker.start()
                await replacementWorker.finishRebuildLease()
            } catch {
                guard !CloudSyncErrorFormatter.isCancellation(error) else {
                    self.finishCloudDataRebuild(operationID)
                    return
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? CloudSyncErrorFormatter.message(
                        for: error,
                        operation: "重建 iCloud 数据"
                    )
                self.receive(.error(
                    message
                ))
            }
            self.finishCloudDataRebuild(operationID)
        }
    }

    var errorDetail: String? {
        switch status {
        case .error(let message): message
        case .accountChanged: "为避免把本机资料上传到另一个账户，同步已自动关闭，请确认账户后重新开启。"
        case .cloudDataRemoved: "iCloud 中的\(AppMetadata.appName)同步数据已被移除。本机资料仍然保留；同步已自动关闭，确认后可以重新开启。"
        case .rebuildInProgress: "另一台设备正在重建 iCloud 数据，当前设备会在重建完成后自动继续同步。"
        default: nil
        }
    }

    var canSynchronizeNow: Bool {
        isEnabled && hasLoadedLocalData && activeOperationID == nil && !status.isBusy
    }

    var canRebuildCloudData: Bool {
        isEnabled
            && hasLoadedLocalData
            && activeOperationID == nil
            && !status.isBusy
            && !isRebuildingCloudData
    }

    private func startIfPossible() {
        guard activeOperationID == nil,
              let worker = prepareWorkerIfPossible() else { return }
        let operationID = UUID()
        activeOperationID = operationID
        operationTask = Task { [weak self] in
            await worker.start()
            self?.operationDidFinish(operationID)
        }
    }

    private func prepareWorkerIfPossible(
        rebuildLease: CloudSyncRebuildLease? = nil
    ) -> CloudKitSyncWorker? {
        guard isSupported,
              isEnabled,
              hasLoadedLocalData,
              snapshotProvider != nil,
              changeHandler != nil else { return nil }

        if worker == nil {
            worker = CloudKitSyncWorker(
                containerIdentifier: containerIdentifier,
                attachmentStore: attachmentStore,
                rebuildLease: rebuildLease,
                statusHandler: { [weak self] status in
                    self?.receive(status)
                },
                snapshotProvider: { [weak self] in
                    guard let self else { return .empty }
                    return try await self.snapshotProvider?() ?? .empty
                },
                changeHandler: { [weak self] changes in
                    try self?.changeHandler?(changes)
                }
            )
        }
        return worker
    }

    private func scheduleReconciliation(delay: Duration) {
        guard let worker else { return }
        reconciliationTask?.cancel()
        reconciliationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self else { return }
            do {
                let snapshot = try await self.makeSnapshot()
                await worker.reconcile(snapshot: snapshot)
            } catch {
                self.receive(.error(
                    "无法整理待同步数据（错误码：\(DiagnosticLogger.errorCode(error))）"
                ))
            }
        }
    }

    private func operationDidFinish(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        operationTask = nil
    }

    private func finishCloudDataRebuild(_ operationID: UUID) {
        isRebuildingCloudData = false
        operationDidFinish(operationID)
    }

    private func makeSnapshot() async throws -> CloudSyncSnapshot {
        guard let snapshotProvider else { return .empty }
        return try await snapshotProvider()
    }

    private func receive(_ status: CloudSyncStatus) {
        guard isEnabled else {
            self.status = .disabled
            return
        }
        self.status = status
        if case .synced(let date) = status {
            lastSuccessfulSyncAt = date
            defaults.set(date, forKey: DefaultsKey.lastSuccessfulSyncAt)
        }
        if status == .accountChanged || status == .cloudDataRemoved {
            isEnabled = false
            defaults.set(false, forKey: DefaultsKey.enabled)
            operationTask?.cancel()
            operationTask = nil
            reconciliationTask?.cancel()
            reconciliationTask = nil
            rebuildRetryTask?.cancel()
            rebuildRetryTask = nil
            activeOperationID = nil
            let previousWorker = worker
            worker = nil
            Task { await previousWorker?.stop() }
        } else if status == .rebuildInProgress {
            scheduleRebuildRetry()
        }
    }

    private func scheduleRebuildRetry() {
        guard isEnabled, rebuildRetryTask == nil else { return }
        rebuildRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.rebuildRetryTask = nil
            self.synchronizeNow()
        }
    }
}

private enum CloudDataRebuildError: LocalizedError {
    case unableToRestart

    var errorDescription: String? {
        "云端数据区已清理，但同步服务暂时无法重新启动；本机资料仍然保留。"
    }
}
