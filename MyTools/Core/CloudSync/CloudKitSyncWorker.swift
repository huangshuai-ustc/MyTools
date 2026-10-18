import CloudKit
import CryptoKit
import Foundation

actor CloudKitSyncWorker: CKSyncEngineDelegate {
    private struct OperationFailure: LocalizedError, Sendable {
        let message: String

        var errorDescription: String? { message }
    }

    private enum Field {
        static let kind = "kind"
        static let entityID = "entityID"
        static let modifiedAt = "modifiedAt"
        static let deviceID = "deviceID"
        static let isDeleted = "isDeleted"
        static let schemaVersion = "schemaVersion"
        static let payload = "encryptedPayload"
        static let asset = "asset"
    }

    private static let recordType = "MyToolsEntity"
    private static let zoneName = "MyToolsData"
    private static let schemaVersion = CloudSyncStoredEntry.supportedSchemaVersion

    private let container: CKContainer
    private let attachmentStore: AttachmentStore
    private let stateStore: CloudSyncStateStore
    private let statusHandler: @MainActor @Sendable (CloudSyncStatus) -> Void
    private let snapshotProvider: CloudSyncSnapshotProvider
    private let changeHandler: CloudSyncChangeHandler
    private let zoneID: CKRecordZone.ID
    private var document: CloudSyncStoredDocument
    private var hasLoadedState = false
    // Treat feature data as inactive until the first local snapshot supplies the
    // compiled and syncable module set. This prevents startup fetches from
    // restoring attachments before the local data boundary is known.
    private var activeModules: Set<ToolModule> = []
    private var hasStarted = false
    private var isStarting = false
    private var operationFailure: OperationFailure?
    private var isPerformingRequestedOperation = false
    private var attachmentRestoreTask: Task<Void, Never>?
    /// 引擎状态更新很频繁；合并到这个延迟写入里，其余变更仍立即写盘（AUDIT-086(5)）。
    private var pendingStateSaveTask: Task<Void, Never>?
    private static let stateSaveDelay: Duration = .seconds(2)
    /// Deletions held back by the bulk-deletion circuit breaker in the last reconcile.
    private var pausedDeletionCount = 0
    /// Set by an explicit user confirmation; consumed by the next reconcile.
    private var allowsNextBulkDeletion = false

    private lazy var syncEngine: CKSyncEngine = makeSyncEngine()

    private func makeSyncEngine() -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: document.engineState,
            delegate: self
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = "mytools-private-database-v1"
        return CKSyncEngine(configuration)
    }

    init(
        containerIdentifier: String,
        attachmentStore: AttachmentStore,
        stateStore: CloudSyncStateStore = CloudSyncStateStore(),
        statusHandler: @escaping @MainActor @Sendable (CloudSyncStatus) -> Void,
        snapshotProvider: @escaping CloudSyncSnapshotProvider,
        changeHandler: @escaping CloudSyncChangeHandler
    ) {
        container = CKContainer(identifier: containerIdentifier)
        self.attachmentStore = attachmentStore
        self.stateStore = stateStore
        self.statusHandler = statusHandler
        self.snapshotProvider = snapshotProvider
        self.changeHandler = changeHandler
        zoneID = CKRecordZone.ID(
            zoneName: Self.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        // Loading and decoding the persisted sync state can involve tens of
        // megabytes. It is deliberately deferred to `start()` so creating the
        // worker from the main-actor coordinator never blocks the first screen.
        document = CloudSyncStoredDocument()
    }

    @discardableResult
    func start() async -> Bool {
        guard await loadPersistedStateIfNeeded() else { return false }
        guard !Task.isCancelled else { return false }
        guard !hasStarted else {
            await synchronize()
            return hasStarted
        }
        guard !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }

        await statusHandler(.checkingAccount)
        do {
            switch try await container.accountStatus() {
            case .available:
                break
            case .noAccount:
                await statusHandler(.noAccount)
                return false
            case .restricted:
                await statusHandler(.restricted)
                return false
            case .temporarilyUnavailable:
                await statusHandler(.temporarilyUnavailable)
                return false
            case .couldNotDetermine:
                await statusHandler(.error("无法确认 iCloud 账户状态"))
                return false
            @unknown default:
                await statusHandler(.error("未知的 iCloud 账户状态"))
                return false
            }

            let currentUser = try await container.userRecordID()
            if let previousUser = document.accountRecordName,
               previousUser != currentUser.recordName {
                resetSyncState(for: currentUser)
                await statusHandler(.accountChanged)
                return false
            }
            if document.accountRecordName == nil {
                document.accountRecordName = currentUser.recordName
                saveDocument()
            }

            await statusHandler(.syncing)

            // The first remote fetch must know which modules are active. If the
            // worker starts with an empty `activeModules` set, every remote
            // record is stored as inactive. The reconciliation that follows
            // can then mistake newly fetched records for local deletions.
            let initialSnapshot = try await snapshotProvider()
            _ = await prepareActiveModules(using: initialSnapshot)
            try await ensureZoneExists()
            try await fetchRemoteChanges()
            await retryPendingLocalApply()
            let mergedSnapshot = try await snapshotProvider()
            await reconcileReadySnapshot(mergedSnapshot)
            try await sendPendingChanges()
            _ = document.discardSystemFields(excluding: pendingRecordKeys())
            saveDocument()
            guard !Task.isCancelled else { return false }
            hasStarted = true
            await statusHandler(syncedStatus())
            return true
        } catch is OperationFailure {
            hasStarted = false
            return false
        } catch {
            hasStarted = false
            guard !CloudSyncErrorFormatter.isCancellation(error) else { return false }
            await report(error, operation: "启动 iCloud 同步")
            return false
        }
    }

    func reconcile(snapshot: CloudSyncSnapshot) async {
        guard hasStarted else { return }
        await reconcileReadySnapshot(snapshot)
    }

    private func reconcileReadySnapshot(_ snapshot: CloudSyncSnapshot) async {
        if await prepareActiveModules(using: snapshot) {
            return
        }

        let now = Date()
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        var changedKeys = Set<String>()
        let currentKeys = Set(snapshot.items.map(\.key))

        for item in snapshot.items {
            if item.kind == .attachment,
               item.assetURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
                continue
            }

            let digest = Self.digest(item.payload)
            let previous = document.entries[item.key]
            // Never overwrite a record written by a newer client (AUDIT-030).
            if previous?.requiresNewerClient == true { continue }
            if previous?.pendingLocalApply == true {
                // The local copy predates a remote change that has not been
                // applied yet; uploading it would revert the other device.
                if previous?.isDeleted == false, previous?.digest == digest {
                    document.entries[item.key]?.pendingLocalApply = false
                    changedKeys.insert(item.key)
                }
                continue
            }
            // A digest match only means the content hasn't changed since the
            // last attempt — it says nothing about whether that attempt
            // actually reached CloudKit. `needsRetry` is set whenever a save
            // failed for a reason `handleSentRecords` doesn't already
            // self-heal, so those entries must still be re-queued here.
            guard previous == nil
                    || previous?.isDeleted == true
                    || previous?.digest != digest
                    || previous?.needsRetry == true else { continue }

            document.entries[item.key] = CloudSyncStoredEntry(
                kind: item.kind,
                id: item.id,
                module: item.module,
                digest: digest,
                modifiedAt: CloudSyncStoredEntry.modifiedAt(editedAt: item.editedAt, previous: previous, now: now),
                deviceID: document.deviceID,
                isDeleted: false,
                payload: item.payload,
                systemFields: previous?.systemFields
            )
            changedKeys.insert(item.key)
            changes.append(.saveRecord(recordID(forKey: item.key)))
        }

        let deletionPlan = CloudSyncDeletionPlanner.plan(
            entries: document.entries,
            currentKeys: currentKeys,
            authorizedModules: snapshot.confirmedDeletionModules,
            allowsBulkDeletion: allowsNextBulkDeletion,
            isActive: { key, entry in isActiveEntry(kind: entry.kind, key: key) }
        )
        if deletionPlan.pausedCount == 0 { allowsNextBulkDeletion = false }
        pausedDeletionCount = deletionPlan.pausedCount
        for key in deletionPlan.keys {
            guard let entry = document.entries[key] else { continue }
            if !entry.isDeleted {
                document.entries[key] = CloudSyncStoredEntry(
                    kind: entry.kind,
                    id: entry.id,
                    module: entry.module,
                    digest: nil,
                    modifiedAt: now,
                    deviceID: document.deviceID,
                    isDeleted: true,
                    payload: nil,
                    systemFields: entry.systemFields
                )
                changedKeys.insert(key)
            }
            changes.append(.deleteRecord(recordID(forKey: key)))
        }
        if deletionPlan.pausedCount > 0 {
            DiagnosticLogger.shared.log(
                .cloudSync,
                "本机记录骤减，已暂停 \(deletionPlan.pausedCount) 条云端删除，等待用户确认",
                level: .warning
            )
            await statusHandler(.deletionPaused(deletionPlan.pausedCount))
        }

        let didDiscardPayloads = discardRedundantPayloads(
            matching: snapshot.items,
            excluding: changedKeys.union(pendingRecordKeys())
        )
        if !changes.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: changes)
        }
        if !changes.isEmpty || didDiscardPayloads {
            saveDocument()
        }
    }

    /// Updates the module boundary before records are fetched or reconciled.
    ///
    /// A worker is created with no active modules because it cannot know the
    /// compiled/syncable set until the first local snapshot is available. When
    /// a module is re-enabled, records fetched while it was disabled are also
    /// applied here before the next snapshot is compared.
    ///
    /// - Returns: `true` when applying re-enabled records changed the local
    ///   vault. The caller should then discard its old snapshot and wait for a
    ///   fresh one before running deletion reconciliation.
    private func prepareActiveModules(using snapshot: CloudSyncSnapshot) async -> Bool {
        let previouslyActiveModules = activeModules
        activeModules = snapshot.participatingModules

        let activatedModules = activeModules.subtracting(previouslyActiveModules)
        guard !activatedModules.isEmpty else { return false }

        // On process startup `activeModules` begins empty. Cached entries may
        // contain tombstones produced by an earlier interrupted/failed local
        // load, so they must never be replayed before the first server fetch.
        // Reconciliation below will turn valid non-empty local items back into
        // saves when the cache contains stale deletion markers. A genuine
        // in-process module re-enable still follows the cached-record path.
        guard hasStarted || !previouslyActiveModules.isEmpty else {
            DiagnosticLogger.shared.log(
                .cloudSync,
                "云同步首次启动：跳过本地缓存变更回放，先拉取服务器状态"
            )
            return false
        }

        // Apply records first. Attachment downloads are independent of the
        // metadata merge and must not block the first usable screen.
        attachmentRestoreTask?.cancel()
        attachmentRestoreTask = Task { [weak self] in
            await self?.restoreAttachments(for: activatedModules)
        }
        let changes = changesForActivatedModules(activatedModules)
        return await applyLocally(changes, operation: "恢复已重新开启模块的 iCloud 数据")
    }

    private func syncedStatus() -> CloudSyncStatus {
        pausedDeletionCount > 0 ? .deletionPaused(pausedDeletionCount) : .synced(Date())
    }

    /// Applies remote changes to the local vault. Their keys stay
    /// `pendingLocalApply` (persisted before the attempt) until the vault
    /// accepts them, so a failed or partial merge is retried later instead of
    /// being reconciled as a local deletion or overwritten by stale data.
    ///
    /// - Returns: `true` when at least one change was applied.
    @discardableResult
    private func applyLocally(_ changes: [CloudSyncChange], operation: String) async -> Bool {
        guard !changes.isEmpty else { return false }
        let keys = Set(changes.map(\.key))
        for key in keys { document.entries[key]?.pendingLocalApply = true }
        saveDocument()
        do {
            let rejected = try await changeHandler(changes)
            for key in keys.subtracting(rejected) {
                document.entries[key]?.pendingLocalApply = false
            }
            saveDocument()
            if !rejected.isEmpty {
                DiagnosticLogger.shared.log(
                    .cloudSync,
                    "\(rejected.count) 条 iCloud 记录未能合并，已保留待重试且不会被同步删除",
                    level: .warning
                )
            }
            return rejected.count < keys.count
        } catch {
            await report(error, operation: operation)
            return false
        }
    }

    private func retryPendingLocalApply() async {
        let changes: [CloudSyncChange] = document.entries
            .filter { key, entry in
                entry.pendingLocalApply && entry.kind != .attachment
                    && !entry.requiresNewerClient
                    && isActiveEntry(kind: entry.kind, key: key)
            }
            .values
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .compactMap { entry in
                if entry.isDeleted { return .delete(kind: entry.kind, id: entry.id) }
                return entry.payload.map { .upsert(kind: entry.kind, id: entry.id, payload: $0) }
            }
        await applyLocally(changes, operation: "重试合并 iCloud 数据")
    }

    private func changesForActivatedModules(
        _ modules: Set<ToolModule>
    ) -> [CloudSyncChange] {
        document.entries.values
            .filter { entry in
                guard let module = entry.kind.module, !entry.requiresNewerClient else { return false }
                return modules.contains(module) && entry.deviceID != document.deviceID
            }
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .compactMap { entry in
                if entry.kind == .attachment { return nil }
                if entry.isDeleted {
                    return .delete(kind: entry.kind, id: entry.id)
                }
                guard let payload = entry.payload else { return nil }
                return .upsert(kind: entry.kind, id: entry.id, payload: payload)
            }
    }

    /// Runs one sync that may send deletions previously paused by the circuit breaker.
    func synchronize(allowingBulkDeletion: Bool) async {
        allowsNextBulkDeletion = allowingBulkDeletion
        await synchronize()
    }

    func synchronize() async {
        if !hasStarted {
            await start()
            return
        }
        await statusHandler(.syncing)
        do {
            try await fetchRemoteChanges()
            await retryPendingLocalApply()
            let mergedSnapshot = try await snapshotProvider()
            await reconcileReadySnapshot(mergedSnapshot)
            try await sendPendingChanges()
            _ = document.discardSystemFields(excluding: pendingRecordKeys())
            saveDocument()
            await statusHandler(syncedStatus())
        } catch is OperationFailure {
            return
        } catch {
            guard !CloudSyncErrorFormatter.isCancellation(error) else { return }
            await report(error, operation: "手动同步")
        }
    }

    func stop() async {
        hasStarted = false
        attachmentRestoreTask?.cancel()
        attachmentRestoreTask = nil
        guard hasLoadedState else { return }
        if pendingStateSaveTask != nil { saveDocument() }
        await syncEngine.cancelOperations()
    }

    /// - Returns: false when the state file exists but cannot be read; sync stays
    ///   blocked instead of starting from an empty document.
    private func loadPersistedStateIfNeeded() async -> Bool {
        guard !hasLoadedState else { return true }
        let loaded = await Task.detached(priority: .utility) { [stateStore] in
            Result { () throws -> (CloudSyncStoredDocument, Bool) in
                var document = try stateStore.load()
                let upgradedState = document.prepareForCurrentReconciliationVersion()
                return (document, upgradedState)
            }
        }.value
        guard case .success(let value) = loaded else {
            DiagnosticLogger.shared.log(.cloudSync, "同步状态文件无法读取，已暂停同步", level: .error)
            await statusHandler(.error("同步状态文件无法读取。为避免已删除的资料从 iCloud 恢复，已暂停同步。"))
            return false
        }
        document = value.0
        hasLoadedState = true
        if value.1 {
            saveDocument()
        }
        return true
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            document.engineState = event.stateSerialization
            _ = document.discardSystemFields(excluding: pendingRecordKeys())
            scheduleStateSave()

        case .accountChange(let event):
            switch event.changeType {
            case .signIn(let currentUser):
                if let previousUser = document.accountRecordName,
                   previousUser != currentUser.recordName {
                    resetSyncState(for: currentUser)
                    await statusHandler(.accountChanged)
                } else {
                    document.accountRecordName = currentUser.recordName
                    saveDocument()
                    await statusHandler(.checkingAccount)
                }
            case .signOut(let previousUser):
                if document.accountRecordName == nil {
                    document.accountRecordName = previousUser.recordName
                    saveDocument()
                }
                await statusHandler(.noAccount)
            case .switchAccounts(_, let currentUser):
                resetSyncState(for: currentUser)
                await statusHandler(.accountChanged)
            @unknown default:
                await statusHandler(.accountChanged)
            }

        case .fetchedDatabaseChanges(let event):
            await handleFetchedDatabaseChanges(event, syncEngine: syncEngine)

        case .fetchedRecordZoneChanges(let event):
            await handleFetchedRecords(
                event.modifications.map(\.record),
                deletions: event.deletions.map(\.recordID),
                syncEngine: syncEngine
            )

        case .sentDatabaseChanges(let event):
            if let failure = event.failedZoneSaves.first {
                await report(failure.error, operation: "创建 iCloud 数据区")
            }

        case .sentRecordZoneChanges(let event):
            await handleSentRecords(event, syncEngine: syncEngine)

        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                await report(error, operation: "接收 iCloud 记录")
            }

        case .didFetchChanges, .didSendChanges:
            // Automatic syncs can run between the steps of `start()`; only
            // `start()` itself may report the first `.synced`, otherwise a
            // startup failure is followed by a misleading “完成”.
            if !isPerformingRequestedOperation, !isStarting, operationFailure == nil {
                await statusHandler(syncedStatus())
            }

        case .willFetchChanges, .willSendChanges:
            if !isPerformingRequestedOperation, !isStarting {
                operationFailure = nil
            }
            await statusHandler(.syncing)

        case .willFetchRecordZoneChanges:
            await statusHandler(.syncing)
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            guard context.options.scope.contains($0) else { return false }
            switch $0 {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                guard let (kind, _) = parse(recordID: recordID) else { return true }
                return isActiveEntry(kind: kind, key: recordID.recordName)
            @unknown default:
                return true
            }
        }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges
        ) { [weak self] recordID in
            await self?.recordToSave(with: recordID)
        }
    }

    private func recordToSave(with recordID: CKRecord.ID) -> CKRecord? {
        guard let entry = document.entries[recordID.recordName],
              !entry.requiresNewerClient else { return nil }
        let record = entry.systemFields.flatMap(CKRecord.cloudSyncRecord(from:))
            ?? CKRecord(recordType: Self.recordType, recordID: recordID)

        record[Field.kind] = entry.kind.rawValue as NSString
        record[Field.entityID] = entry.id.uuidString.lowercased() as NSString
        record[Field.modifiedAt] = entry.modifiedAt as NSDate
        record[Field.deviceID] = entry.deviceID as NSString
        record[Field.isDeleted] = NSNumber(value: entry.isDeleted)
        record[Field.schemaVersion] = NSNumber(value: Self.schemaVersion)

        if entry.isDeleted {
            record.encryptedValues[Field.payload] = nil
            record[Field.asset] = nil
        } else {
            guard let payload = entry.payload else { return nil }
            record.encryptedValues[Field.payload] = payload as NSData
            if entry.kind == .attachment,
               let attachment = try? CloudSyncCoding.decoder().decode(
                    FileAttachment.self,
                    from: payload
               ) {
                let assetURL = attachmentStore.url(for: attachment)
                guard FileManager.default.fileExists(atPath: assetURL.path) else {
                    return record
                }
                record[Field.asset] = CKAsset(fileURL: assetURL)
            }
        }
        return record
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
        syncEngine: CKSyncEngine
    ) async {
        guard let deletion = event.deletions.first(where: { $0.zoneID == zoneID }) else {
            return
        }
        switch deletion.reason {
        case .deleted:
            syncEngine.state.add(
                pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
            )
            // Uploaded entries no longer carry a payload; rebuild every record
            // from the current local snapshot so the new zone is complete (AUDIT-029).
            let keys: [String]
            do {
                let snapshot = try await snapshotProvider()
                let items = snapshot.items.filter { item in
                    item.assetURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
                }
                keys = document.prepareForRecreatedZone(localItems: items, now: Date())
                saveDocument()
            } catch {
                await report(error, operation: "重建 iCloud 数据区")
                keys = document.entries.compactMap { key, entry in
                    entry.isDeleted || entry.payload == nil ? nil : key
                }
            }
            DiagnosticLogger.shared.log(
                .cloudSync,
                "iCloud 数据区已被删除，按本机数据重新上传 \(keys.count) 条记录",
                level: .warning
            )
            syncEngine.state.add(pendingRecordZoneChanges: keys.map {
                .saveRecord(recordID(forKey: $0))
            })
        case .purged, .encryptedDataReset:
            document.entries = [:]
            saveDocument()
            operationFailure = OperationFailure(message: "iCloud 中的同步数据已被移除")
            await statusHandler(.cloudDataRemoved)
        @unknown default:
            let message = "iCloud 数据区发生了未知变化"
            operationFailure = OperationFailure(message: message)
            await statusHandler(.error(message))
        }
    }

    private func handleFetchedRecords(
        _ records: [CKRecord],
        deletions: [CKRecord.ID],
        syncEngine: CKSyncEngine
    ) async {
        var changes: [CloudSyncChange] = []
        let orderedRecords = records.sorted {
            remoteKind(from: $0) != .attachment && remoteKind(from: $1) == .attachment
        }

        for record in orderedRecords {
            do {
                if let change = try acceptRemoteRecord(record, syncEngine: syncEngine) {
                    changes.append(change)
                }
            } catch {
                // The entry already reflects the remote record; keep it from
                // being reconciled as a deletion until the file is in place.
                if let kind = remoteKind(from: record),
                   let id = (record[Field.entityID] as? String).flatMap(UUID.init(uuidString:)) {
                    document.entries[CloudSyncItem.key(kind: kind, id: id)]?.pendingLocalApply = true
                }
                await report(error, operation: "处理 iCloud 记录")
            }
        }

        for recordID in deletions {
            guard recordID.zoneID == zoneID,
                  let (kind, id) = parse(recordID: recordID) else { continue }
            guard isActiveEntry(kind: kind, key: recordID.recordName) else {
                let previous = document.entries[recordID.recordName]
                document.entries[recordID.recordName] = CloudSyncStoredEntry(
                    kind: kind,
                    id: id,
                    module: previous?.module ?? kind.module ?? attachmentModule(for: id),
                    digest: nil,
                    modifiedAt: Date(),
                    deviceID: "server",
                    isDeleted: true,
                    payload: nil,
                    systemFields: previous?.systemFields
                )
                syncEngine.state.remove(
                    pendingRecordZoneChanges: [.saveRecord(recordID)]
                )
                continue
            }
            let key = recordID.recordName
            let previous = document.entries[key]
            if kind == .attachment,
               let payload = previous?.payload,
               let attachment = try? CloudSyncCoding.decoder().decode(FileAttachment.self, from: payload) {
                attachmentStore.delete(attachment)
            } else {
                changes.append(.delete(kind: kind, id: id))
            }
            document.entries[key] = CloudSyncStoredEntry(
                kind: kind,
                id: id,
                module: previous?.module ?? attachmentModule(for: id),
                digest: nil,
                modifiedAt: Date(),
                deviceID: "server",
                isDeleted: true,
                payload: nil,
                systemFields: nil
            )
            syncEngine.state.remove(
                pendingRecordZoneChanges: [.saveRecord(recordID)]
            )
        }

        saveDocument()
        await applyLocally(changes, operation: "合并 iCloud 数据")
    }

    private func acceptRemoteRecord(
        _ record: CKRecord,
        syncEngine: CKSyncEngine
    ) throws -> CloudSyncChange? {
        guard record.recordType == Self.recordType,
              record.recordID.zoneID == zoneID,
              let kind = remoteKind(from: record),
              let idString = record[Field.entityID] as? String,
              let id = UUID(uuidString: idString),
              let modifiedAt = record[Field.modifiedAt] as? Date else {
            return nil
        }

        let key = CloudSyncItem.key(kind: kind, id: id)
        let module = kind.module ?? attachmentModule(for: id)
        let schemaVersion = (record[Field.schemaVersion] as? NSNumber)?.int64Value
        if (schemaVersion ?? 1) > Self.schemaVersion {
            storeNewerClientRecord(record, kind: kind, id: id, module: module, schemaVersion: schemaVersion, syncEngine: syncEngine)
            return nil
        }
        guard isActiveEntry(kind: kind, key: key, module: module) else {
            storeInactiveRemoteRecord(
                record: record,
                kind: kind,
                id: id,
                module: module,
                syncEngine: syncEngine
            )
            return nil
        }

        let isDeleted = (record[Field.isDeleted] as? NSNumber)?.boolValue ?? false
        let deviceID = record[Field.deviceID] as? String ?? "server"
        let payload = isDeleted ? nil : record.encryptedValues[Field.payload] as? Data
        guard isDeleted || payload != nil else { return nil }

        let digest = payload.map(Self.digest)
        let local = document.entries[key]
        let remoteWins = shouldAcceptRemote(
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            over: local
        )

        guard remoteWins else {
            if var local {
                local.systemFields = record.cloudSyncSystemFields()
                document.entries[key] = local
            }
            syncEngine.state.add(pendingRecordZoneChanges: [
                document.entries[key]?.isDeleted == true
                    ? .deleteRecord(record.recordID)
                    : .saveRecord(record.recordID)
            ])
            return nil
        }

        let contentChanged = local?.isDeleted != isDeleted || local?.digest != digest
        document.entries[key] = CloudSyncStoredEntry(
            kind: kind,
            id: id,
            module: module,
            digest: digest,
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            isDeleted: isDeleted,
            payload: payload,
            systemFields: record.cloudSyncSystemFields()
        )
        syncEngine.state.remove(
            pendingRecordZoneChanges: [.saveRecord(record.recordID)]
        )

        if kind == .attachment {
            try applyRemoteAttachment(
                record: record,
                payload: payload,
                previousPayload: local?.payload,
                isDeleted: isDeleted
            )
            return nil
        }
        guard contentChanged else { return nil }
        if isDeleted {
            return .delete(kind: kind, id: id)
        }
        return payload.map { .upsert(kind: kind, id: id, payload: $0) }
    }

    /// Keeps a newer-schema record verbatim; this build neither applies nor
    /// re-uploads it (AUDIT-030).
    private func storeNewerClientRecord(
        _ record: CKRecord,
        kind: CloudSyncEntityKind,
        id: UUID,
        module: ToolModule?,
        schemaVersion: Int64?,
        syncEngine: CKSyncEngine
    ) {
        let key = CloudSyncItem.key(kind: kind, id: id)
        let isDeleted = (record[Field.isDeleted] as? NSNumber)?.boolValue ?? false
        let payload = isDeleted ? nil : record.encryptedValues[Field.payload] as? Data
        document.entries[key] = CloudSyncStoredEntry(
            kind: kind,
            id: id,
            module: module ?? document.entries[key]?.module,
            digest: payload.map(Self.digest),
            modifiedAt: record[Field.modifiedAt] as? Date ?? Date(),
            deviceID: record[Field.deviceID] as? String ?? "server",
            isDeleted: isDeleted,
            payload: payload,
            pendingLocalApply: true,
            schemaVersion: schemaVersion
        )
        syncEngine.state.remove(pendingRecordZoneChanges: [
            .saveRecord(record.recordID),
            .deleteRecord(record.recordID)
        ])
        DiagnosticLogger.shared.log(
            .cloudSync,
            "收到更高版本（schema \(schemaVersion ?? 1)）的 iCloud 记录 kind=\(kind.rawValue)，已原样保留，升级 App 后再合并",
            level: .warning
        )
    }

    private func storeInactiveRemoteRecord(
        record: CKRecord,
        kind: CloudSyncEntityKind,
        id: UUID,
        module: ToolModule?,
        syncEngine: CKSyncEngine
    ) {
        let key = CloudSyncItem.key(kind: kind, id: id)
        let isDeleted = (record[Field.isDeleted] as? NSNumber)?.boolValue ?? false
        let payload = isDeleted ? nil : record.encryptedValues[Field.payload] as? Data
        guard isDeleted || payload != nil else { return }
        let modifiedAt = record[Field.modifiedAt] as? Date ?? Date()
        let deviceID = record[Field.deviceID] as? String ?? "server"
        let digest = payload.map(Self.digest)
        guard shouldAcceptRemote(
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            over: document.entries[key]
        ) else { return }
        document.entries[key] = CloudSyncStoredEntry(
            kind: kind,
            id: id,
            module: module,
            digest: digest,
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            isDeleted: isDeleted,
            payload: payload,
            systemFields: record.cloudSyncSystemFields()
        )
        syncEngine.state.remove(
            pendingRecordZoneChanges: [.saveRecord(record.recordID)]
        )
    }

    private func isActiveEntry(
        kind: CloudSyncEntityKind,
        key: String,
        module: ToolModule? = nil
    ) -> Bool {
        if kind == .attachment {
            let owner = module ?? document.entries[key]?.module
            if let owner {
                return activeModules.contains(owner)
            }
            return ToolModuleCatalog.definitions.contains {
                $0.ownsAttachments && activeModules.contains($0.module)
            }
        }
        return kind.isIncluded(in: activeModules)
    }

    private func attachmentModule(for id: UUID) -> ToolModule? {
        let owners: Set<ToolModule> = document.entries.values.reduce(into: []) { result, entry in
            guard !entry.isDeleted, let payload = entry.payload else { return }
            let decoder = CloudSyncCoding.decoder()
            switch entry.kind {
            case .financialInstitution:
#if MYTOOLS_FEATURE_FINANCE
                guard let institution = try? decoder.decode(FinancialInstitution.self, from: payload) else { return }
                if institution.financeAttachments.contains(where: { $0.id == id }) { result.insert(.personalFinance) }
#endif
                break
            case .financialProvider, .bankAccount, .bankCard:
                break
            case .medicalRecord:
#if MYTOOLS_FEATURE_HEALTH
                guard let record = try? decoder.decode(MedicalRecord.self, from: payload) else { return }
                if record.attachments.contains(where: { $0.id == id }) {
                    result.insert(.healthRecords)
                }
#endif
                break
            case .foodPlace:
                break
            case .secretItem:
#if MYTOOLS_FEATURE_SECRETS
                guard let secret = try? decoder.decode(SecretItem.self, from: payload) else { return }
                if secret.attachments.contains(where: { $0.id == id }) {
                    result.insert(.secrets)
                }
#endif
                break
            case .credentialDocument:
#if MYTOOLS_FEATURE_DOCUMENTS
                guard let document = try? decoder.decode(CredentialDocument.self, from: payload) else {
                    return
                }
                if document.attachments.contains(where: { $0.file.id == id }) {
                    result.insert(.documents)
                }
#endif
                break
            default:
                break
            }
        }
        return owners.sorted { $0.rawValue < $1.rawValue }.first
    }

    private func restoreAttachments(for modules: Set<ToolModule>) async {
        let entries = document.entries.values.filter { entry in
            entry.kind == .attachment
                && !entry.isDeleted
                && entry.deviceID != document.deviceID
                && entry.module.map(modules.contains) == true
        }
        for entry in entries {
            guard !Task.isCancelled else { return }
            do {
                let record = try await container.privateCloudDatabase.record(
                    for: recordID(forKey: CloudSyncItem.key(kind: entry.kind, id: entry.id))
                )
                try applyRemoteAttachment(
                    record: record,
                    payload: entry.payload,
                    previousPayload: nil,
                    isDeleted: false
                )
            } catch {
                await report(error, operation: "恢复 iCloud 附件")
            }
            await Task.yield()
        }
    }

    private func applyRemoteAttachment(
        record: CKRecord,
        payload: Data?,
        previousPayload: Data?,
        isDeleted: Bool
    ) throws {
        let decoder = CloudSyncCoding.decoder()
        let previousAttachment = previousPayload.flatMap {
            try? decoder.decode(FileAttachment.self, from: $0)
        }
        if isDeleted {
            if let previousAttachment {
                attachmentStore.delete(previousAttachment)
            }
            return
        }
        guard let payload,
              let attachment = try? decoder.decode(FileAttachment.self, from: payload),
              let asset = record[Field.asset] as? CKAsset,
              let sourceURL = asset.fileURL else { return }
        try attachmentStore.copyFile(
            from: sourceURL,
            to: attachment,
            replacing: previousAttachment
        )
    }

    private func handleSentRecords(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        for recordID in event.deletedRecordIDs {
            document.entries[recordID.recordName]?.systemFields = nil
        }

        for record in event.savedRecords {
            guard var entry = document.entries[record.recordID.recordName] else { continue }
            // The change tag is useful only while a save is pending. Keeping
            // it after a successful upload duplicates CloudKit's state locally
            // for every bill and makes the sync file grow without bound.
            entry.systemFields = nil
            entry.needsRetry = false
            if entry.kind != .attachment,
               isActiveEntry(kind: entry.kind, key: record.recordID.recordName) {
                entry.payload = nil
            }
            document.entries[record.recordID.recordName] = entry
        }

        for (recordID, error) in event.failedRecordDeletes {
            if (error as NSError).code == CKError.Code.unknownItem.rawValue {
                document.entries[recordID.recordName]?.systemFields = nil
            } else {
                await report(error, operation: "删除 iCloud 记录")
            }
        }

        for failure in event.failedRecordSaves {
            switch failure.error.code {
            case .serverRecordChanged:
                if let serverRecord = failure.error.serverRecord {
                    await handleFetchedRecords(
                        [serverRecord],
                        deletions: [],
                        syncEngine: syncEngine
                    )
                }
            case .unknownItem:
                let key = failure.record.recordID.recordName
                document.entries[key]?.systemFields = nil
                syncEngine.state.add(
                    pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
                )
            case .zoneNotFound:
                syncEngine.state.add(
                    pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
                )
                syncEngine.state.add(
                    pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
                )
            case .batchRequestFailed:
                // Failed only because another record in the batch did; that
                // record carries the real error. Retry without alerting.
                let key = failure.record.recordID.recordName
                document.entries[key]?.needsRetry = true
                syncEngine.state.add(
                    pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
                )
            default:
                // Every other error (network failure, service unavailable,
                // quota, etc.) is not self-healing: CKSyncEngine does not
                // automatically re-queue this record. Mark it so the next
                // reconcile re-sends it even though its digest hasn't
                // changed, instead of silently leaving it missing from
                // CloudKit forever. Re-queue immediately too, so a transient
                // failure doesn't have to wait for the next local edit or
                // reconcile cycle to be retried.
                let key = failure.record.recordID.recordName
                document.entries[key]?.needsRetry = true
                syncEngine.state.add(
                    pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
                )
                let code = DiagnosticLogger.errorCode(failure.error)
                DiagnosticLogger.shared.log(
                    .persistence,
                    "iCloud 记录上传失败，已标记待重试 kind=\(document.entries[key]?.kind.rawValue ?? "?") error=\(code)",
                    level: .warning
                )
                await report(failure.error, operation: "上传 iCloud 记录")
            }
        }
        _ = document.discardSystemFields(excluding: pendingRecordKeys())
        saveDocument()
    }

    private func ensureZoneExists() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let results = try await container.privateCloudDatabase.modifyRecordZones(
            saving: [zone],
            deleting: []
        )
        guard let result = results.saveResults[zoneID] else {
            throw NSError(
                domain: "MyToolsCloudSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CloudKit 未返回数据区创建结果"]
            )
        }
        _ = try result.get()
        syncEngine.state.remove(pendingDatabaseChanges: [.saveZone(zone)])
    }

    private func fetchRemoteChanges() async throws {
        operationFailure = nil
        isPerformingRequestedOperation = true
        defer { isPerformingRequestedOperation = false }

        var options = CKSyncEngine.FetchChangesOptions()
        options.scope = .zoneIDs([zoneID])
        try await syncEngine.fetchChanges(options)
        if let operationFailure { throw operationFailure }
    }

    private func sendPendingChanges() async throws {
        operationFailure = nil
        isPerformingRequestedOperation = true
        defer { isPerformingRequestedOperation = false }

        var options = CKSyncEngine.SendChangesOptions()
        options.scope = .zoneIDs([zoneID])
        do {
            try await syncEngine.sendChanges(options)
        } catch {
            // Each failed record was already merged or re-queued by
            // `handleSentRecords`; the next send retries them.
            guard CloudSyncErrorFormatter.isSelfHealingPartialFailure(error) else { throw error }
            DiagnosticLogger.shared.log(
                .cloudSync,
                "上传 iCloud 记录部分失败，均可自愈，等待自动重试：\(CloudSyncErrorFormatter.partialFailureSummary(error) ?? "")"
            )
        }
        if let operationFailure { throw operationFailure }
    }

    private func shouldAcceptRemote(
        modifiedAt: Date,
        deviceID: String,
        over local: CloudSyncStoredEntry?
    ) -> Bool {
        guard let local else { return true }
        if modifiedAt != local.modifiedAt {
            return modifiedAt > local.modifiedAt
        }
        return deviceID >= local.deviceID
    }

    private func recordID(forKey key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: key, zoneID: zoneID)
    }

    private func parse(recordID: CKRecord.ID) -> (CloudSyncEntityKind, UUID)? {
        let components = recordID.recordName.split(separator: ".", maxSplits: 1)
        guard components.count == 2,
              let kind = CloudSyncEntityKind(rawValue: String(components[0])),
              let id = UUID(uuidString: String(components[1])) else { return nil }
        return (kind, id)
    }

    private func remoteKind(from record: CKRecord) -> CloudSyncEntityKind? {
        (record[Field.kind] as? String).flatMap(CloudSyncEntityKind.init(rawValue:))
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Active entities already live in the local vault. Retaining a second full
    /// JSON copy is only necessary while the record is pending upload. Keep
    /// attachment metadata because it is required to remove a downloaded file.
    private func discardRedundantPayloads(
        matching items: [CloudSyncItem],
        excluding changedKeys: Set<String>
    ) -> Bool {
        var didChange = false
        for item in items {
            let key = item.key
            guard !changedKeys.contains(key),
                  item.kind != .attachment,
                  var entry = document.entries[key],
                  !entry.isDeleted,
                  entry.payload != nil,
                  entry.digest == Self.digest(item.payload),
                  isActiveEntry(kind: entry.kind, key: key) else {
                continue
            }
            entry.payload = nil
            document.entries[key] = entry
            didChange = true
        }
        return didChange
    }

    private func pendingRecordKeys() -> Set<String> {
        Set(syncEngine.state.pendingRecordZoneChanges.compactMap { change in
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                recordID.recordName
            @unknown default:
                nil
            }
        })
    }

    private func scheduleStateSave() {
        guard pendingStateSaveTask == nil else { return }
        pendingStateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stateSaveDelay)
            await self?.flushScheduledStateSave()
        }
    }

    private func flushScheduledStateSave() {
        guard pendingStateSaveTask != nil else { return }
        saveDocument()
    }

    private func saveDocument() {
        pendingStateSaveTask?.cancel()
        pendingStateSaveTask = nil
        do {
            try stateStore.save(document)
        } catch {
            cloudSyncLogger.error(
                "Unable to persist cloud sync state: \(DiagnosticLogger.errorCode(error), privacy: .public)"
            )
        }
    }

    private func resetSyncState(for account: CKRecord.ID) {
        document.resetForAccountChange(accountRecordName: account.recordName)
        saveDocument()
    }

    private func report(_ error: Error, operation: String) async {
        guard !CloudSyncErrorFormatter.isCancellation(error) else { return }
        let isSelfHealing = CloudSyncErrorFormatter.isSelfHealingPartialFailure(error)
        if let summary = CloudSyncErrorFormatter.partialFailureSummary(error) {
            DiagnosticLogger.shared.log(
                .cloudSync,
                "\(operation)部分失败明细：\(summary)",
                level: isSelfHealing ? .info : .warning
            )
        }
        guard !isSelfHealing else {
            DiagnosticLogger.shared.log(.cloudSync, "\(operation)：子错误均可自愈，等待自动重试，不提示错误")
            return
        }
        let code = DiagnosticLogger.errorCode(error)
        let message = CloudSyncErrorFormatter.message(for: error, operation: operation)
        operationFailure = OperationFailure(message: message)
        cloudSyncLogger.error("\(operation, privacy: .public) failed: \(code, privacy: .public)")
        DiagnosticLogger.shared.log(
            .persistence,
            "\(operation)失败 error=\(code)",
            level: .error
        )
        await statusHandler(.error(message))
    }
}

enum CloudSyncErrorFormatter {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let value = error as NSError
        guard value.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: value.code) else { return false }
        if code == .operationCancelled {
            return true
        }
        guard code == .partialFailure,
              let partialErrors = value.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: Error],
              !partialErrors.isEmpty else { return false }
        return partialErrors.values.allSatisfy(isCancellation)
    }

    /// Sub-errors recovered without the user: `handleSentRecords` merges the
    /// server record, re-queues unknown items, or recreates the zone, and a
    /// batch-only failure is retried with its batch.
    private static let selfHealingCodes: Set<CKError.Code> = [
        .serverRecordChanged, .unknownItem, .zoneNotFound, .batchRequestFailed, .operationCancelled
    ]

    private static func partialErrors(of error: Error) -> [AnyHashable: Error]? {
        let value = error as NSError
        guard value.domain == CKErrorDomain,
              value.code == CKError.Code.partialFailure.rawValue,
              let partialErrors = value.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
              !partialErrors.isEmpty else { return nil }
        return partialErrors
    }

    private static func cloudKitCode(_ error: Error) -> CKError.Code? {
        let value = error as NSError
        guard value.domain == CKErrorDomain else { return nil }
        return CKError.Code(rawValue: value.code)
    }

    /// True for a partial failure whose every sub-error heals itself. A batch
    /// made only of `batchRequestFailed` hides its cause, so it still alerts.
    static func isSelfHealingPartialFailure(_ error: Error) -> Bool {
        guard let partialErrors = partialErrors(of: error) else { return false }
        let codes = partialErrors.values.map(cloudKitCode)
        return codes.allSatisfy { $0.map(selfHealingCodes.contains) == true }
            && !codes.allSatisfy { $0 == .batchRequestFailed || $0 == .operationCancelled }
    }

    /// Groups sub-errors by record kind and code, with a masked sample id, e.g.
    /// `financialInstitution CKErrorDomain(14)×3 eg=1A2B…`. Never logs full ids.
    static func partialFailureSummary(_ error: Error) -> String? {
        guard let partialErrors = partialErrors(of: error) else { return nil }
        var groups: [String: (count: Int, sample: String)] = [:]
        for (item, childError) in partialErrors {
            let (kind, sample) = maskedItem(item)
            let group = "\(kind) \(DiagnosticLogger.errorCode(childError))"
            groups[group, default: (0, sample)].count += 1
        }
        let lines = groups.sorted { $0.key < $1.key }.prefix(12).map {
            "\($0.key)×\($0.value.count) eg=\($0.value.sample)"
        }
        let more = groups.count > 12 ? "；另有 \(groups.count - 12) 组" : ""
        return "共 \(partialErrors.count) 条：" + lines.joined(separator: "；") + more
    }

    private static func maskedItem(_ item: AnyHashable) -> (kind: String, sample: String) {
        if let zoneID = item.base as? CKRecordZone.ID {
            return ("zone", zoneID.zoneName)
        }
        let name = (item.base as? CKRecord.ID)?.recordName ?? String(describing: item.base)
        let components = name.split(separator: ".", maxSplits: 1)
        guard components.count == 2 else { return ("unknown", String(name.prefix(4)) + "…") }
        return (String(components[0]), String(components[1].prefix(4)) + "…")
    }

    static func message(for error: Error, operation: String) -> String {
        let value = error as NSError
        guard value.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: value.code) else {
            return "\(operation)失败（\(DiagnosticLogger.errorCode(error))）"
        }
        return "\(operation)失败（CKErrorDomain \(code.rawValue)）：\(hint(for: code))"
    }

    private static func hint(for code: CKError.Code) -> String {
        switch code {
        case .missingEntitlement, .badContainer:
            return "当前安装包缺少正确的 iCloud 容器权限，请重新签名安装。"
        case .notAuthenticated:
            return "设备尚未登录可用的 iCloud 账户，或 iCloud Drive 未开启。"
        case .permissionFailure:
            return "当前 Apple 账户没有访问此 CloudKit 容器的权限。"
        case .networkUnavailable, .networkFailure:
            return "网络暂时无法连接 iCloud，请检查网络后重试。"
        case .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .accountTemporarilyUnavailable:
            return "iCloud 服务暂时繁忙，请稍后重试。"
        case .quotaExceeded:
            return "iCloud 储存空间不足。"
        case .serverRejectedRequest, .invalidArguments:
            return "CloudKit 容器结构或环境尚未正确配置。"
        case .changeTokenExpired:
            return "云端变更记录已过期，请再次同步以重新对账。"
        case .partialFailure, .batchRequestFailed:
            return "部分记录未能同步，请查看诊断日志中的具体错误码。"
        case .assetFileNotFound, .assetFileModified, .assetNotAvailable:
            return "附件文件在同步期间不可用，请确认附件仍存在后重试。"
        default:
            return "CloudKit 返回了错误，请稍后重试并查看诊断日志。"
        }
    }
}
