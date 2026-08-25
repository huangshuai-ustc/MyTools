import CloudKit
import CryptoKit
import Foundation

actor CloudKitSyncWorker: CKSyncEngineDelegate {
    private struct RebuildControl: Codable, Sendable {
        let generation: Int64
        let ownerDeviceID: String?
        let lockedUntil: Date?

        var isLocked: Bool {
            guard let lockedUntil else { return false }
            return lockedUntil > Date()
        }
    }

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
    private static let controlZoneName = "MyToolsControl"
    private static let controlRecordName = "rebuild-control"
    private static let schemaVersion: Int64 = 1

    private let container: CKContainer
    private let attachmentStore: AttachmentStore
    private let stateStore: CloudSyncStateStore
    private let statusHandler: @MainActor @Sendable (CloudSyncStatus) -> Void
    private let snapshotProvider: CloudSyncSnapshotProvider
    private let changeHandler: CloudSyncChangeHandler
    private let zoneID: CKRecordZone.ID
    private let controlZoneID: CKRecordZone.ID
    private let controlRecordID: CKRecord.ID
    private let rebuildLease: CloudSyncRebuildLease?
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
    private var isRebuildingRemoteData = false
    private var isResettingRemoteState = false
    private var attachmentRestoreTask: Task<Void, Never>?

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
        rebuildLease: CloudSyncRebuildLease? = nil,
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
        controlZoneID = CKRecordZone.ID(
            zoneName: Self.controlZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        controlRecordID = CKRecord.ID(
            recordName: Self.controlRecordName,
            zoneID: controlZoneID
        )
        self.rebuildLease = rebuildLease
        // Loading and decoding the persisted sync state can involve tens of
        // megabytes. It is deliberately deferred to `start()` so creating the
        // worker from the main-actor coordinator never blocks the first screen.
        document = CloudSyncStoredDocument()
    }

    @discardableResult
    func start() async -> Bool {
        await loadPersistedStateIfNeeded()
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

            try await ensureControlZoneExists()
            guard try await prepareForRebuildControl(currentUser: currentUser) else {
                return false
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
            let mergedSnapshot = try await snapshotProvider()
            await reconcileReadySnapshot(mergedSnapshot)
            try await sendPendingChanges()
            _ = document.discardSystemFields(excluding: pendingRecordKeys())
            saveDocument()
            guard !Task.isCancelled else { return false }
            hasStarted = true
            await statusHandler(.synced(Date()))
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
        guard (try? await ensureRemoteSyncAllowed()) == true else {
            if !hasStarted {
                await start()
            }
            return
        }
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
            guard previous == nil
                    || previous?.isDeleted == true
                    || previous?.digest != digest else { continue }

            document.entries[item.key] = CloudSyncStoredEntry(
                kind: item.kind,
                id: item.id,
                module: item.module,
                digest: digest,
                modifiedAt: now,
                deviceID: document.deviceID,
                isDeleted: false,
                payload: item.payload,
                systemFields: previous?.systemFields
            )
            changedKeys.insert(item.key)
            changes.append(.saveRecord(recordID(forKey: item.key)))
        }

        for (key, entry) in document.entries
        where isActiveEntry(kind: entry.kind, key: key)
            && (!entry.isDeleted || entry.systemFields != nil)
            && !currentKeys.contains(key) {
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

        // Apply records first. Attachment downloads are independent of the
        // metadata merge and must not block the first usable screen.
        attachmentRestoreTask?.cancel()
        attachmentRestoreTask = Task { [weak self] in
            await self?.restoreAttachments(for: activatedModules)
        }
        let changes = changesForActivatedModules(activatedModules)
        guard !changes.isEmpty else { return false }
        do {
            try await changeHandler(changes)
            saveDocument()
            return true
        } catch {
            await report(error, operation: "恢复已重新开启模块的 iCloud 数据")
            return false
        }
    }

    private func changesForActivatedModules(
        _ modules: Set<ToolModule>
    ) -> [CloudSyncChange] {
        document.entries.values
            .filter { entry in
                guard let module = entry.kind.module else { return false }
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

    func synchronize() async {
        if !hasStarted {
            await start()
            return
        }
        await statusHandler(.syncing)
        do {
            guard try await ensureRemoteSyncAllowed() else {
                if !hasStarted {
                    await start()
                }
                return
            }
            try await fetchRemoteChanges()
            let mergedSnapshot = try await snapshotProvider()
            await reconcileReadySnapshot(mergedSnapshot)
            try await sendPendingChanges()
            _ = document.discardSystemFields(excluding: pendingRecordKeys())
            saveDocument()
            await statusHandler(.synced(Date()))
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
        await syncEngine.cancelOperations()
    }

    /// Deletes only this app's private CloudKit zone. The local vault and
    /// attachment directory are owned by AppStore/AttachmentStore and are not
    /// touched. The coordinator replaces this worker after the reset so the
    /// next start uses a fresh CKSyncEngine state and uploads the local snapshot.
    func deleteRemoteZoneForRebuild() async throws -> CloudSyncRebuildLease {
        await loadPersistedStateIfNeeded()
        guard !Task.isCancelled else { throw CancellationError() }

        let currentUser = try await container.userRecordID()
        if let previousUser = document.accountRecordName,
           previousUser != currentUser.recordName {
            throw OperationFailure(message: "iCloud 账户已变化，无法重建云端数据")
        }

        isRebuildingRemoteData = true
        var acquiredLease: CloudSyncRebuildLease?
        do {
            let lease = try await acquireRebuildLease(
                ownerDeviceID: document.deviceID,
                localGeneration: document.rebuildGeneration ?? 0
            )
            acquiredLease = lease
            attachmentRestoreTask?.cancel()
            attachmentRestoreTask = nil
            await syncEngine.cancelOperations()
            let results = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [],
                deleting: [zoneID]
            )
            if let result = results.deleteResults[zoneID] {
                do {
                    _ = try result.get()
                } catch {
                    guard Self.isMissingZone(error) else { throw error }
                }
            }
            document.resetForRemoteRebuild(
                accountRecordName: currentUser.recordName,
                rebuildGeneration: lease.generation
            )
            saveDocument()
            hasStarted = false
            return lease
        } catch {
            if let acquiredLease {
                try? await releaseRebuildLease(acquiredLease)
            }
            isRebuildingRemoteData = false
            throw error
        }
    }

    private func loadPersistedStateIfNeeded() async {
        guard !hasLoadedState else { return }
        let loaded = await Task.detached(priority: .utility) { [stateStore] in
            var document = stateStore.load()
            let upgradedState = document.prepareForCurrentReconciliationVersion()
            return (document, upgradedState)
        }.value
        document = loaded.0
        hasLoadedState = true
        if loaded.1 {
            saveDocument()
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard !isRebuildingRemoteData, !isResettingRemoteState else { return }
        switch event {
        case .stateUpdate(let event):
            document.engineState = event.stateSerialization
            _ = document.discardSystemFields(excluding: pendingRecordKeys())
            saveDocument()

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
            guard (try? await ensureRemoteSyncAllowed()) == true else { return }
            await handleFetchedDatabaseChanges(event, syncEngine: syncEngine)

        case .fetchedRecordZoneChanges(let event):
            guard (try? await ensureRemoteSyncAllowed()) == true else { return }
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
            guard (try? await ensureRemoteSyncAllowed()) == true else { return }
            await handleSentRecords(event, syncEngine: syncEngine)

        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                await report(error, operation: "接收 iCloud 记录")
            }

        case .didFetchChanges, .didSendChanges:
            if !isPerformingRequestedOperation, operationFailure == nil {
                await statusHandler(.synced(Date()))
            }

        case .willFetchChanges, .willSendChanges:
            if !isPerformingRequestedOperation {
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
        guard (try? await ensureRemoteSyncAllowed()) == true else { return nil }
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
        guard let entry = document.entries[recordID.recordName] else { return nil }
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
            let recordChanges = document.entries.keys.map {
                CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(forKey: $0))
            }
            syncEngine.state.add(pendingRecordZoneChanges: recordChanges)
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
        guard !changes.isEmpty else { return }
        do {
            try await changeHandler(changes)
        } catch {
            await report(error, operation: "合并 iCloud 数据")
        }
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
            case .bankCard:
#if MYTOOLS_FEATURE_FINANCE
                guard let card = try? decoder.decode(BankCard.self, from: payload) else { return }
                if card.statements.contains(where: { $0.attachment?.id == id }) {
                    result.insert(.personalFinance)
                }
#endif
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
#if MYTOOLS_FEATURE_FOOD_MAP
                guard let place = try? decoder.decode(FoodPlace.self, from: payload) else { return }
                if place.photos.contains(where: { $0.id == id }) {
                    result.insert(.foodMap)
                }
#endif
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
        guard !isRebuildingRemoteData,
              !isResettingRemoteState,
              (try? await ensureRemoteSyncAllowed()) == true else { return }
        for recordID in event.deletedRecordIDs {
            document.entries[recordID.recordName]?.systemFields = nil
        }

        for record in event.savedRecords {
            guard var entry = document.entries[record.recordID.recordName] else { continue }
            // The change tag is useful only while a save is pending. Keeping
            // it after a successful upload duplicates CloudKit's state locally
            // for every bill and makes the sync file grow without bound.
            entry.systemFields = nil
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
            default:
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

    private func ensureControlZoneExists() async throws {
        let zone = CKRecordZone(zoneID: controlZoneID)
        let results = try await container.privateCloudDatabase.modifyRecordZones(
            saving: [zone],
            deleting: []
        )
        guard let result = results.saveResults[controlZoneID] else {
            throw NSError(
                domain: "MyToolsCloudSync",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "CloudKit 未返回重建控制区结果"]
            )
        }
        _ = try result.get()
    }

    private func prepareForRebuildControl(currentUser: CKRecord.ID) async throws -> Bool {
        let control = try await loadRebuildControl()
        let localGeneration = document.rebuildGeneration ?? 0
        if control.generation > localGeneration {
            document.resetForRemoteRebuild(
                accountRecordName: currentUser.recordName,
                rebuildGeneration: control.generation
            )
            saveDocument()
            await resetSyncEngineForRemoteGenerationChange()
            hasStarted = false
        }
        guard !control.isLocked || ownsRebuildLease(control) else {
            await statusHandler(.rebuildInProgress)
            return false
        }
        return true
    }

    private func ensureRemoteSyncAllowed() async throws -> Bool {
        let control = try await loadRebuildControl()
        let localGeneration = document.rebuildGeneration ?? 0
        if control.generation > localGeneration {
            document.resetForRemoteRebuild(
                accountRecordName: document.accountRecordName,
                rebuildGeneration: control.generation
            )
            saveDocument()
            await resetSyncEngineForRemoteGenerationChange()
            hasStarted = false
            return false
        }
        guard !control.isLocked || ownsRebuildLease(control) else {
            hasStarted = false
            await statusHandler(.rebuildInProgress)
            return false
        }
        return true
    }

    private func resetSyncEngineForRemoteGenerationChange() async {
        isResettingRemoteState = true
        await syncEngine.cancelOperations()
        syncEngine = makeSyncEngine()
        isResettingRemoteState = false
    }

    private func loadRebuildControl() async throws -> RebuildControl {
        do {
            let record = try await container.privateCloudDatabase.record(
                for: controlRecordID
            )
            guard let payload = record.encryptedValues[Field.payload] as? Data else {
                return RebuildControl(generation: 0, ownerDeviceID: nil, lockedUntil: nil)
            }
            return try CloudSyncCoding.decoder().decode(RebuildControl.self, from: payload)
        } catch {
            guard Self.isMissingZoneOrRecord(error) else { throw error }
            return RebuildControl(generation: 0, ownerDeviceID: nil, lockedUntil: nil)
        }
    }

    private func acquireRebuildLease(
        ownerDeviceID: String,
        localGeneration: Int64
    ) async throws -> CloudSyncRebuildLease {
        for _ in 0..<3 {
            var existingRecord: CKRecord?
            let control: RebuildControl
            do {
                existingRecord = try await container.privateCloudDatabase.record(
                    for: controlRecordID
                )
                if let existingRecord,
                   let payload = existingRecord.encryptedValues[Field.payload] as? Data {
                    control = try CloudSyncCoding.decoder().decode(
                        RebuildControl.self,
                        from: payload
                    )
                } else {
                    control = RebuildControl(
                        generation: localGeneration,
                        ownerDeviceID: nil,
                        lockedUntil: nil
                    )
                }
            } catch {
                guard Self.isMissingZoneOrRecord(error) else { throw error }
                existingRecord = nil
                control = RebuildControl(
                    generation: localGeneration,
                    ownerDeviceID: nil,
                    lockedUntil: nil
                )
            }

            if control.isLocked,
               control.ownerDeviceID != ownerDeviceID {
                throw OperationFailure(message: "另一台设备正在重建 iCloud 数据，请稍后重试")
            }

            let generation = max(control.generation, localGeneration) + 1
            let lockedUntil = Date().addingTimeInterval(30 * 60)
            let lease = CloudSyncRebuildLease(
                generation: generation,
                ownerDeviceID: ownerDeviceID,
                lockedUntil: lockedUntil
            )
            let record = existingRecord ?? CKRecord(
                recordType: Self.recordType,
                recordID: controlRecordID
            )
            try apply(
                RebuildControl(
                    generation: generation,
                    ownerDeviceID: ownerDeviceID,
                    lockedUntil: lockedUntil
                ),
                to: record,
                ownerDeviceID: ownerDeviceID
            )

            do {
                let results = try await container.privateCloudDatabase.modifyRecords(
                    saving: [record],
                    deleting: []
                )
                if let result = results.saveResults[controlRecordID] {
                    _ = try result.get()
                    return lease
                }
            } catch {
                guard Self.isServerRecordChanged(error) else { throw error }
            }
        }
        throw OperationFailure(message: "无法取得 iCloud 重建锁，请稍后重试")
    }

    private func ownsRebuildLease(_ control: RebuildControl) -> Bool {
        guard let rebuildLease else { return false }
        return control.generation == rebuildLease.generation
            && control.ownerDeviceID == rebuildLease.ownerDeviceID
            && rebuildLease.lockedUntil > Date()
    }

    func finishRebuildLease() async {
        guard let rebuildLease else { return }
        do {
            try await releaseRebuildLease(rebuildLease)
        } catch {
            await report(error, operation: "释放 iCloud 重建锁")
        }
    }

    func abortRebuildLease(_ lease: CloudSyncRebuildLease) async {
        do {
            try await releaseRebuildLease(lease)
        } catch {
            await report(error, operation: "释放 iCloud 重建锁")
        }
    }

    private func releaseRebuildLease(_ lease: CloudSyncRebuildLease) async throws {
        let record = try await container.privateCloudDatabase.record(for: controlRecordID)
        guard let payload = record.encryptedValues[Field.payload] as? Data else { return }
        let current = try CloudSyncCoding.decoder().decode(RebuildControl.self, from: payload)
        guard current.generation == lease.generation,
              current.ownerDeviceID == lease.ownerDeviceID else { return }
        try apply(
            RebuildControl(
                generation: lease.generation,
                ownerDeviceID: nil,
                lockedUntil: nil
            ),
            to: record,
            ownerDeviceID: document.deviceID
        )
        let results = try await container.privateCloudDatabase.modifyRecords(
            saving: [record],
            deleting: []
        )
        if let result = results.saveResults[controlRecordID] {
            _ = try result.get()
        }
    }

    private func apply(
        _ control: RebuildControl,
        to record: CKRecord,
        ownerDeviceID: String
    ) throws {
        record[Field.kind] = "rebuildControl" as NSString
        record[Field.entityID] = Self.controlRecordName as NSString
        record[Field.modifiedAt] = Date() as NSDate
        record[Field.deviceID] = ownerDeviceID as NSString
        record[Field.isDeleted] = NSNumber(value: control.isLocked)
        record[Field.schemaVersion] = NSNumber(value: Self.schemaVersion)
        record.encryptedValues[Field.payload] = try CloudSyncCoding.encoder().encode(control) as NSData
    }

    private static func isMissingZoneOrRecord(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: value.code) else { return false }
        return code == .zoneNotFound || code == .unknownItem
    }

    private static func isServerRecordChanged(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == CKErrorDomain,
           let code = CKError.Code(rawValue: value.code),
           code == .serverRecordChanged {
            return true
        }
        guard value.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: value.code),
              code == .partialFailure,
              let errors = value.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: Error] else { return false }
        return errors.values.contains(where: isServerRecordChanged)
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
        try await syncEngine.sendChanges(options)
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

    private func saveDocument() {
        do {
            try stateStore.save(document)
        } catch {
            cloudSyncLogger.error(
                "Unable to persist cloud sync state: \(DiagnosticLogger.errorCode(error), privacy: .public)"
            )
        }
    }

    private func resetSyncState(for account: CKRecord.ID) {
        document.resetForRemoteRebuild(
            accountRecordName: account.recordName,
            rebuildGeneration: 0
        )
        saveDocument()
    }

    private static func isMissingZone(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: value.code) else { return false }
        return code == .zoneNotFound || code == .unknownItem
    }

    private func report(_ error: Error, operation: String) async {
        guard !CloudSyncErrorFormatter.isCancellation(error) else { return }
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
