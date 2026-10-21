import CloudKit
import Foundation
import Testing
@testable import MyTools

struct CloudSyncMergerTests {
    @Test func stockCashFlowsRoundTripThroughCloudSnapshot() throws {
        var record = StockCashFlowRecord()
        record.kind = .deposit
        record.currency = .cny
        record.amount = 20_000

        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(stockCashFlowRecords: [record]),
            secrets: [],
            attachmentStore: AttachmentStore(),
            enabledModules: [.myStocks]
        )
        let item = try #require(snapshot.items.first { $0.kind == .stockCashFlowRecord })
        let result = try CloudSyncMerger.apply(
            [.upsert(kind: item.kind, id: item.id, payload: item.payload)],
            to: VaultData(),
            secrets: [],
            enabledModules: [.myStocks]
        )

        #expect(result.vault.stockCashFlowRecords == [record])
    }

    @Test func snapshotContainsOnlyEnabledModuleEntities() throws {
        var account = FinancialInstitution()
        account.bankName = "Account"
        var stock = StockHolding()
        stock.symbol = "TEST"
        var record = MedicalRecord()
        record.hospital = "Hospital"
        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(
                accounts: [account],
                stocks: [stock],
                medicalRecords: [record]
            ),
            secrets: [SecretItem(title: "Secret")],
            attachmentStore: AttachmentStore(),
            enabledModules: [.personalFinance]
        )

        #expect(Set(snapshot.items.map(\.kind)) == [.financialInstitution, .financeMetadata])
        #expect(snapshot.participatingModules == [.personalFinance])
    }

    @Test func remoteChangesForDisabledModulesAreIgnored() throws {
        var localRecord = MedicalRecord()
        localRecord.hospital = "Local"
        var remoteRecord = localRecord
        remoteRecord.hospital = "Remote"
        let payload = try CloudSyncCoding.encoder().encode(remoteRecord)

        let result = try CloudSyncMerger.apply(
            [.upsert(kind: .medicalRecord, id: remoteRecord.id, payload: payload)],
            to: VaultData(medicalRecords: [localRecord]),
            secrets: [],
            enabledModules: [.personalFinance]
        )

        #expect(result.vault.medicalRecords == [localRecord])
    }

    @Test func snapshotAndMergePreserveModuleMetadata() throws {
        var bankTemplate = BankLoginFieldTemplate(name: "自定义网址")
        bankTemplate.isSensitive = true
        let secretTemplate = SecretFieldTemplate(
            category: .login,
            fields: [SecretField(label: "一次性密码", isSensitive: false)]
        )
        let vault = VaultData(
            domesticBankLoginFieldTemplates: [bankTemplate],
            medicalRecordTags: ["心内科"],
            credentialTags: ["重要证件"],
            billTags: ["报销"],
            secretTags: ["工作"],
            secretFieldTemplates: [secretTemplate]
        )

        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: vault,
            secrets: [],
            attachmentStore: AttachmentStore()
        )
        let changes = snapshot.items.compactMap { item -> CloudSyncChange? in
            guard item.kind.module != nil else { return nil }
            return .upsert(kind: item.kind, id: item.id, payload: item.payload)
        }
        let result = try CloudSyncMerger.apply(changes, to: VaultData(), secrets: [])

        #expect(result.vault.domesticBankLoginFieldTemplates == [bankTemplate])
        #expect(result.vault.medicalRecordTags == ["心内科"])
        #expect(result.vault.credentialTags == ["重要证件"])
#if MYTOOLS_FEATURE_BILLS
        #expect(result.vault.billTags == ["报销"])
#endif
        #expect(result.vault.secretTags == ["工作"])
        #expect(result.vault.secretFieldTemplates == [secretTemplate])
    }

    @MainActor
    @Test func preferenceSnapshotRoundTripsThroughCloudPayload() throws {
        let defaults = makeDefaults()
        defaults.set(AppAppearanceMode.dark.rawValue, forKey: AppStorageKey.appearanceMode)
        defaults.set(AppFontSize.accessibility2.rawValue, forKey: AppStorageKey.fontSize)
        let moduleSettings = ToolModuleSettings(defaults: defaults)
        moduleSettings.setVisible(false, for: .healthRecords)
        moduleSettings.moveModules(from: IndexSet(integer: 0), to: moduleSettings.orderedModules.count)
        let stockSettings = StockAppearanceSettings(defaults: defaults)
        stockSettings.setScheme(.greenRiseRedFall, for: .aShare)
        let bridge = CloudSyncPreferencesBridge(
            defaults: defaults,
            moduleSettings: moduleSettings,
            stockAppearanceSettings: stockSettings
        )

        let preferences = bridge.makeSnapshot()
        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(),
            secrets: [],
            attachmentStore: AttachmentStore(),
            appPreferences: preferences
        )
        let item = try #require(snapshot.items.first { $0.kind == .appPreferences })
        let decoded = try CloudSyncCoding.decoder().decode(
            CloudSyncAppPreferences.self,
            from: item.payload
        )

        #expect(item.id == CloudSyncAppPreferences.itemID)
        #expect(item.assetURL == nil)
        #expect(decoded == preferences)
        #expect(decoded.moduleVisibility[ToolModule.healthRecords.rawValue] == false)
        #expect(decoded.appearanceMode == .dark)
        #expect(decoded.fontSize == .accessibility2)
        #expect(decoded.aShareScheme == .greenRiseRedFall)
    }

    @MainActor
    @Test func remotePreferencesApplyAndCompletePartialModuleOrder() throws {
        let defaults = makeDefaults()
        let moduleSettings = ToolModuleSettings(defaults: defaults)
        let stockSettings = StockAppearanceSettings(defaults: defaults)
        let bridge = CloudSyncPreferencesBridge(
            defaults: defaults,
            moduleSettings: moduleSettings,
            stockAppearanceSettings: stockSettings
        )
        var visibilityChanges: [ToolModule] = []
        moduleSettings.setVisibilityChangeHandler { module, _ in
            visibilityChanges.append(module)
        }
        let preferences = CloudSyncAppPreferences(
            moduleOrder: [.healthRecords, .myStocks, .healthRecords],
            moduleVisibility: [
                ToolModule.healthRecords.rawValue: false,
                ToolModule.myStocks.rawValue: false
            ],
            appearanceMode: .light,
            fontSize: .xxLarge,
            aShareScheme: .greenRiseRedFall,
            hongKongScheme: .greenRiseRedFall,
            unitedStatesScheme: .redRiseGreenFall
        )

        try bridge.apply(preferences)

        let expectedOrder: [ToolModule] = [.healthRecords, .myStocks]
            + CompiledToolModules.ordered.filter { module in
                module != .healthRecords && module != .myStocks
            }
        #expect(moduleSettings.orderedModules == expectedOrder)
        #expect(!moduleSettings.isVisible(.healthRecords))
        #expect(!moduleSettings.isVisible(.myStocks))
        #expect(moduleSettings.isVisible(.personalFinance) == ToolModule.personalFinance.defaultIsVisible)
        #expect(Set(visibilityChanges) == [.healthRecords, .myStocks])
        #expect(defaults.string(forKey: AppStorageKey.appearanceMode) == AppAppearanceMode.light.rawValue)
        #expect(defaults.string(forKey: AppStorageKey.fontSize) == AppFontSize.xxLarge.rawValue)
        #expect(stockSettings.aShareScheme == .greenRiseRedFall)
        #expect(stockSettings.hongKongScheme == .greenRiseRedFall)
        #expect(stockSettings.unitedStatesScheme == .redRiseGreenFall)
    }

    // 新版本设置在本机先单独校验，失败只拒收这一条，不能拖垮整批同步。
    @MainActor
    @Test func unsupportedPreferencesSchemaIsRejectedBeforeApplying() {
        let defaults = makeDefaults()
        let bridge = CloudSyncPreferencesBridge(
            defaults: defaults,
            moduleSettings: ToolModuleSettings(defaults: defaults),
            stockAppearanceSettings: StockAppearanceSettings(defaults: defaults)
        )
        let future = CloudSyncAppPreferences(
            schemaVersion: CloudSyncAppPreferences.currentSchemaVersion + 1,
            moduleOrder: [], moduleVisibility: [:], appearanceMode: .dark, fontSize: .xxLarge,
            aShareScheme: .greenRiseRedFall, hongKongScheme: .greenRiseRedFall, unitedStatesScheme: .greenRiseRedFall
        )
        #expect(throws: (any Error).self) { try bridge.validate(future) }
        #expect(throws: (any Error).self) { try bridge.apply(future) }
        #expect(defaults.string(forKey: AppStorageKey.appearanceMode) == nil)
        #expect(throws: Never.self) { try bridge.validate(bridge.makeSnapshot()) }
    }

    @Test func preferencesDoNotMutateVaultEntities() throws {
        var account = FinancialInstitution()
        account.bankName = "Retained"

        let result = try CloudSyncMerger.apply(
            [
                .upsert(
                    kind: .appPreferences,
                    id: CloudSyncAppPreferences.itemID,
                    payload: Data([0x00])
                ),
                .delete(kind: .appPreferences, id: CloudSyncAppPreferences.itemID)
            ],
            to: VaultData(accounts: [account]),
            secrets: []
        )

        #expect(result.vault.financialInstitutions == [account])
        #expect(result.secrets.isEmpty)
    }

    @Test func oldSyncStateForcesOneCompleteReconciliation() {
        let id = UUID()
        let deviceID = "device-a"
        var document = CloudSyncStoredDocument(
            entries: [
                CloudSyncItem.key(kind: .bankAccount, id: id): CloudSyncStoredEntry(
                    kind: .bankAccount,
                    id: id,
                    digest: Data([1]),
                    modifiedAt: Date(timeIntervalSince1970: 10),
                    deviceID: deviceID,
                    isDeleted: false,
                    payload: Data([2]),
                    systemFields: Data([3])
                )
            ],
            deviceID: deviceID,
            accountRecordName: "account-a",
            reconciliationVersion: CloudSyncStoredDocument.currentReconciliationVersion - 1
        )

        let didUpgrade = document.prepareForCurrentReconciliationVersion()
        #expect(didUpgrade)
        #expect(document.entries.isEmpty)
        #expect(document.deviceID == deviceID)
        #expect(document.accountRecordName == "account-a")
        #expect(
            document.reconciliationVersion
                == CloudSyncStoredDocument.currentReconciliationVersion
        )
        let repeatedUpgrade = document.prepareForCurrentReconciliationVersion()
        #expect(!repeatedUpgrade)
    }

    @Test func accountChangeResetsOnlyCloudSyncState() {
        let id = UUID()
        let key = CloudSyncItem.key(kind: .billRecord, id: id)
        var document = CloudSyncStoredDocument(
            entries: [
                key: CloudSyncStoredEntry(
                    kind: .billRecord,
                    id: id,
                    digest: Data([1, 2, 3]),
                    modifiedAt: Date(timeIntervalSince1970: 100),
                    deviceID: "remote-device",
                    isDeleted: false,
                    payload: Data([4, 5, 6]),
                    systemFields: Data([7, 8, 9])
                )
            ],
            deviceID: "local-device",
            accountRecordName: "old-account"
        )

        document.resetForAccountChange(accountRecordName: "current-account")

        #expect(document.entries.isEmpty)
        #expect(document.engineState == nil)
        #expect(document.deviceID == "local-device")
        #expect(document.accountRecordName == "current-account")
        #expect(
            document.reconciliationVersion
                == CloudSyncStoredDocument.currentReconciliationVersion
        )
    }

    @Test func cloudSyncStateUsesCompressedLocalFormatAndRoundTrips() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTools-CloudSyncState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let id = UUID()
        let payload = Data(repeating: 0x41, count: 64 * 1_024)
        let document = CloudSyncStoredDocument(
            entries: [
                CloudSyncItem.key(kind: .billRecord, id: id): CloudSyncStoredEntry(
                    kind: .billRecord,
                    id: id,
                    digest: Data([1, 2, 3]),
                    modifiedAt: Date(timeIntervalSince1970: 10),
                    deviceID: "device-a",
                    isDeleted: false,
                    payload: payload,
                    systemFields: Data(repeating: 0x42, count: 8 * 1_024)
                )
            ],
            deviceID: "device-a",
            accountRecordName: "account-a"
        )
        let store = CloudSyncStateStore(applicationSupportDirectory: baseDirectory)
        try store.save(document)

        let fileURL = baseDirectory
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("cloud-sync-state.json", isDirectory: false)
        let raw = try Data(contentsOf: fileURL)
        #expect(raw.starts(with: Data([0x4D, 0x54, 0x53, 0x43, 0x01])))

        let restored = try store.load()
        let restoredEntry = try #require(restored.entries.values.first)
        #expect(restored.deviceID == document.deviceID)
        #expect(restored.accountRecordName == document.accountRecordName)
        #expect(restoredEntry.payload == payload)
        #expect(restoredEntry.systemFields == document.entries.values.first?.systemFields)
    }

    /// LWW 对带更新时间的实体只使用真实编辑时间；旧同步缓存的对账时间不能把旧内容
    /// 冒充成新编辑，否则恢复出来的旧设备会覆盖云端的新版本。
    @Test func lastWriterTimestampUsesEditTimeWithinBounds() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let previous = CloudSyncStoredEntry(
            kind: .secretItem, id: UUID(), modifiedAt: Date(timeIntervalSince1970: 1_500),
            deviceID: "a", isDeleted: false
        )
        let edited = Date(timeIntervalSince1970: 1_800)
        #expect(CloudSyncStoredEntry.modifiedAt(editedAt: nil, previous: previous, now: now) == now)
        #expect(CloudSyncStoredEntry.modifiedAt(editedAt: edited, previous: nil, now: now) == edited)
        #expect(CloudSyncStoredEntry.modifiedAt(editedAt: edited, previous: previous, now: now) == edited)
        #expect(CloudSyncStoredEntry.modifiedAt(editedAt: Date(timeIntervalSince1970: 1_000), previous: previous, now: now) == Date(timeIntervalSince1970: 1_000))
        #expect(CloudSyncStoredEntry.modifiedAt(editedAt: Date(timeIntervalSince1970: 9_000), previous: nil, now: now) == now)

        var secret = SecretItem()
        secret.updatedAt = edited
        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(), secrets: [secret], attachmentStore: AttachmentStore(), enabledModules: [.secrets]
        )
        #expect(snapshot.items.first { $0.kind == .secretItem }?.editedAt == edited)
    }

    /// AUDIT-086(1)：文件缺失才从空文档开始；文件损坏要报错，不能当作空状态。
    @Test func cloudSyncStateLoadThrowsForUnreadableFileButNotForMissingFile() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTools-CloudSyncState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = CloudSyncStateStore(applicationSupportDirectory: baseDirectory)
        #expect(try store.load().entries.isEmpty)

        let directory = baseDirectory.appendingPathComponent("MyTools", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a sync state".utf8).write(
            to: directory.appendingPathComponent("cloud-sync-state.json", isDirectory: false)
        )
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func cloudSyncStateDropsOnlyNonPendingSystemFields() {
        let pendingID = UUID()
        let completedID = UUID()
        let pendingKey = CloudSyncItem.key(kind: .billRecord, id: pendingID)
        let completedKey = CloudSyncItem.key(kind: .billRecord, id: completedID)
        var document = CloudSyncStoredDocument(entries: [
            pendingKey: CloudSyncStoredEntry(
                kind: .billRecord,
                id: pendingID,
                digest: nil,
                modifiedAt: Date(),
                deviceID: "device-a",
                isDeleted: false,
                payload: Data([1]),
                systemFields: Data([2])
            ),
            completedKey: CloudSyncStoredEntry(
                kind: .billRecord,
                id: completedID,
                digest: nil,
                modifiedAt: Date(),
                deviceID: "device-a",
                isDeleted: false,
                payload: nil,
                systemFields: Data([3])
            )
        ])

        let didDiscard = document.discardSystemFields(excluding: [pendingKey])
        #expect(didDiscard)
        #expect(document.entries[pendingKey]?.systemFields == Data([2]))
        #expect(document.entries[completedKey]?.systemFields == nil)
    }

    // AUDIT-029：zone 被删后，已丢弃 payload 的记录按本地快照重建并全部重新入队。
    @Test func recreatedZoneRebuildsUploadedEntriesFromLocalSnapshot() {
        let uploadedID = UUID()
        let cachedID = UUID()
        let newerID = UUID()
        let uploadedKey = CloudSyncItem.key(kind: .billRecord, id: uploadedID)
        let cachedKey = CloudSyncItem.key(kind: .billRecord, id: cachedID)
        let newerKey = CloudSyncItem.key(kind: .billRecord, id: newerID)
        let then = Date(timeIntervalSince1970: 1_000)
        var document = CloudSyncStoredDocument(entries: [
            uploadedKey: CloudSyncStoredEntry(
                kind: .billRecord, id: uploadedID, modifiedAt: then, deviceID: "device-a",
                isDeleted: false, payload: nil, systemFields: Data([1])
            ),
            cachedKey: CloudSyncStoredEntry(
                kind: .billRecord, id: cachedID, modifiedAt: then, deviceID: "device-b",
                isDeleted: false, payload: Data([2])
            ),
            newerKey: CloudSyncStoredEntry(
                kind: .billRecord, id: newerID, modifiedAt: then, deviceID: "device-c",
                isDeleted: false, payload: Data([3]), pendingLocalApply: true, schemaVersion: 99
            )
        ], deviceID: "device-a")

        let keys = document.prepareForRecreatedZone(
            localItems: [CloudSyncItem(kind: .billRecord, id: uploadedID, payload: Data([9]), assetURL: nil)],
            now: Date()
        )

        #expect(keys == [uploadedKey, cachedKey].sorted())
        #expect(document.entries[uploadedKey]?.payload == Data([9]))
        #expect(document.entries[uploadedKey]?.systemFields == nil)
        #expect(document.entries[cachedKey]?.payload == Data([2]))
        #expect(document.entries[newerKey]?.payload == Data([3]))
    }

    // AUDIT-030：更高 schema 的记录标记为需新版客户端，旧版不回写也不删除。
    @Test func newerSchemaEntriesAreHeldAndExcludedFromDeletion() throws {
        let id = UUID()
        let key = CloudSyncItem.key(kind: .billRecord, id: id)
        let entry = CloudSyncStoredEntry(
            kind: .billRecord, id: id, modifiedAt: Date(), deviceID: "device-b",
            isDeleted: false, payload: Data([1]), pendingLocalApply: true,
            schemaVersion: CloudSyncStoredEntry.supportedSchemaVersion + 1
        )
        #expect(entry.requiresNewerClient)
        #expect(!CloudSyncStoredEntry(kind: .billRecord, id: id, modifiedAt: Date(), deviceID: "a", isDeleted: false).requiresNewerClient)

        let decoded = try JSONDecoder().decode(CloudSyncStoredEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.schemaVersion == entry.schemaVersion)

        let plan = CloudSyncDeletionPlanner.plan(
            entries: [key: entry],
            currentKeys: [],
            authorizedModules: [],
            allowsBulkDeletion: true,
            isActive: { _, _ in true }
        )
        #expect(plan.keys.isEmpty)
    }

    @Test func missingCloudKitEntitlementErrorHasActionableMessage() {
        let error = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.missingEntitlement.rawValue
        )

        let message = CloudSyncErrorFormatter.message(
            for: error,
            operation: "手动同步"
        )

        #expect(message.contains("CKErrorDomain 8"))
        #expect(message.contains("iCloud 容器权限"))
    }

    @Test func cancelledCloudKitOperationsAreNotUserFacingFailures() {
        let cloudKitCancellation = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.operationCancelled.rawValue
        )
        let networkFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkFailure.rawValue
        )

        #expect(CloudSyncErrorFormatter.isCancellation(CancellationError()))
        #expect(CloudSyncErrorFormatter.isCancellation(cloudKitCancellation))
        #expect(!CloudSyncErrorFormatter.isCancellation(networkFailure))
    }

    @Test func partialFailureIsCancellationOnlyWhenEveryChildWasCancelled() {
        let cancelled = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.operationCancelled.rawValue
        )
        let networkFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkFailure.rawValue
        )
        let cancellationOnly = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: ["record": cancelled]]
        )
        let mixedFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    "cancelled": cancelled,
                    "network": networkFailure
                ]
            ]
        )

        #expect(CloudSyncErrorFormatter.isCancellation(cancellationOnly))
        #expect(!CloudSyncErrorFormatter.isCancellation(mixedFailure))
    }

    @Test func selfHealingPartialFailureIsLoggedWithMaskedIDsButNotReported() throws {
        func cloudKitError(_ code: CKError.Code) -> NSError {
            NSError(domain: CKErrorDomain, code: code.rawValue)
        }
        func partial(_ errors: [AnyHashable: Error]) -> NSError {
            NSError(
                domain: CKErrorDomain,
                code: CKError.Code.partialFailure.rawValue,
                userInfo: [CKPartialErrorsByItemIDKey: errors]
            )
        }
        let zoneID = CKRecordZone.ID(zoneName: "MyToolsData", ownerName: CKCurrentUserDefaultName)
        let id = UUID()
        let changed = CKRecord.ID(recordName: "financialInstitution.\(id.uuidString)", zoneID: zoneID)
        let missing = CKRecord.ID(recordName: "document.\(UUID().uuidString)", zoneID: zoneID)
        let batch = CKRecord.ID(recordName: "secret.\(UUID().uuidString)", zoneID: zoneID)
        let selfHealing = partial([
            changed: cloudKitError(.serverRecordChanged),
            missing: cloudKitError(.unknownItem),
            batch: cloudKitError(.batchRequestFailed)
        ])
        #expect(CloudSyncErrorFormatter.isSelfHealingPartialFailure(selfHealing))
        #expect(!CloudSyncErrorFormatter.isSelfHealingPartialFailure(partial([
            changed: cloudKitError(.serverRecordChanged),
            missing: cloudKitError(.quotaExceeded)
        ])))
        // A batch of only `batchRequestFailed` hides its real cause.
        #expect(!CloudSyncErrorFormatter.isSelfHealingPartialFailure(partial([
            batch: cloudKitError(.batchRequestFailed)
        ])))
        #expect(!CloudSyncErrorFormatter.isSelfHealingPartialFailure(cloudKitError(.unknownItem)))

        let summary = try #require(CloudSyncErrorFormatter.partialFailureSummary(selfHealing))
        #expect(summary.contains("共 3 条"))
        #expect(summary.contains("financialInstitution CKErrorDomain(14)×1"))
        #expect(summary.contains("document CKErrorDomain(11)×1"))
        #expect(summary.contains(String(id.uuidString.prefix(4)) + "…"))
        #expect(!summary.contains(id.uuidString))
    }

    @Test func remoteRecordUpdatesOnlyItsMatchingEntity() throws {
        var account = FinancialInstitution()
        account.bankName = "Before"
        var otherAccount = FinancialInstitution()
        otherAccount.bankName = "Other"
        var remoteAccount = account
        remoteAccount.bankName = "After"

        let payload = try CloudSyncCoding.encoder().encode(remoteAccount)
        let result = try CloudSyncMerger.apply(
            [.upsert(kind: .financialInstitution, id: account.id, payload: payload)],
            to: VaultData(accounts: [account, otherAccount]),
            secrets: []
        )

        #expect(result.vault.financialInstitutions.map(\.bankName) == ["After", "Other"])
    }

    @Test func remoteDeletionRemovesOnlyTheMatchingRecord() throws {
        let retained = CurrencyRateAlert(threshold: 6.5)
        let removed = CurrencyRateAlert(threshold: 7)

        let result = try CloudSyncMerger.apply(
            [.delete(kind: .currencyRateAlert, id: removed.id)],
            to: VaultData(currencyRateAlerts: [retained, removed]),
            secrets: []
        )

        #expect(result.vault.currencyRateAlerts == [retained])
    }

    @Test func portfolioSyncDoesNotOverwriteDeviceLocalQuote() throws {
        var local = StockHolding()
        local.symbol = "TEST"
        local.latestPrice = 42
        local.previousClose = 40
        local.quoteName = "Provider Name"

        var remote = local
        remote.name = "My Name"
        remote.latestPrice = nil
        remote.previousClose = nil
        remote.quoteName = ""
        let payload = try CloudSyncCoding.encoder().encode(remote)

        let result = try CloudSyncMerger.apply(
            [.upsert(kind: .stockHolding, id: local.id, payload: payload)],
            to: VaultData(stocks: [local]),
            secrets: []
        )

        #expect(result.vault.stocks.first?.name == "My Name")
        #expect(result.vault.stocks.first?.latestPrice == 42)
        #expect(result.vault.stocks.first?.previousClose == 40)
        #expect(result.vault.stocks.first?.quoteName == "Provider Name")
    }

    @Test func remoteNewStockIsAppendedToAnOlderPortfolio() throws {
        var existing = StockHolding()
        existing.symbol = "OLD"
        var incoming = StockHolding()
        incoming.symbol = "NEW"
        incoming.name = "后来新增的股票"
        let stockItem = try #require(
            CloudSyncSnapshotBuilder
                .make(
                    vault: VaultData(stocks: [incoming]),
                    secrets: [],
                    attachmentStore: AttachmentStore(),
                    enabledModules: [.myStocks]
                )
                .items
                .first { $0.kind == .stockHolding }
        )
        let payload = stockItem.payload

        // The payload is decoded from the same portfolio-only shape that is
        // sent to CloudKit. A device with an older snapshot must append it by
        // UUID instead of replacing or dropping its existing holdings.
        let result = try CloudSyncMerger.apply(
            [.upsert(kind: .stockHolding, id: incoming.id, payload: payload)],
            to: VaultData(stocks: [existing]),
            secrets: [],
            enabledModules: [.myStocks]
        )

        #expect(result.vault.stocks.map(\.symbol) == ["OLD", "NEW"])
        #expect(result.vault.stocks.last?.name == "后来新增的股票")
    }

    @Test func snapshotStoresAttachmentsAsAssetsAndRemovesEveryBackupPayload() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let attachmentStore = AttachmentStore(directoryURL: temporaryDirectory)
        var attachment = FileAttachment()
        attachment.storedFileName = "report.pdf"
        attachment.fileName = "report.pdf"
        attachment.backupData = Data([1, 2, 3])
        try attachmentStore.write(Data([1, 2, 3]), to: attachment)
        var record = MedicalRecord()
        record.attachments = [attachment]
        var statement = CreditCardStatement()
        statement.attachment = attachment
        let institution = FinancialInstitution()
        var card = BankCard()
        card.accountID = institution.id
        card.statements = [statement]
        let secret = SecretItem(attachments: [attachment])

        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(accounts: [institution], cards: [card], medicalRecords: [record]),
            secrets: [secret],
            attachmentStore: attachmentStore
        )
        let attachmentItem = try #require(
            snapshot.items.first(where: { $0.kind == .attachment })
        )
        let metadata = try CloudSyncCoding.decoder().decode(
            FileAttachment.self,
            from: attachmentItem.payload
        )
        // Schema 3 syncs cards embedded in their institution record.
        let institutionPayload = try #require(
            snapshot.items.first(where: { $0.kind == .financialInstitution })?.payload
        )
        let syncedCard = try #require(
            try CloudSyncCoding.decoder().decode(FinancialInstitution.self, from: institutionPayload).cards.first
        )
        let recordPayload = try #require(
            snapshot.items.first(where: { $0.kind == .medicalRecord })?.payload
        )
        let syncedRecord = try CloudSyncCoding.decoder().decode(MedicalRecord.self, from: recordPayload)
        let secretPayload = try #require(
            snapshot.items.first(where: { $0.kind == .secretItem })?.payload
        )
        let syncedSecret = try CloudSyncCoding.decoder().decode(SecretItem.self, from: secretPayload)

        #expect(metadata.backupData == nil)
        #expect(syncedCard.statements.first?.attachment?.backupData == nil)
        #expect(syncedRecord.attachments.first?.backupData == nil)
        #expect(syncedSecret.attachments.first?.backupData == nil)
        #expect(attachmentItem.assetURL == attachmentStore.url(for: attachment))
    }

    @Test func replacingDownloadedAttachmentRemovesItsOldStoredFile() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let attachmentStore = AttachmentStore(directoryURL: temporaryDirectory)
        var previous = FileAttachment()
        previous.storedFileName = "old.pdf"
        var replacement = previous
        replacement.storedFileName = "new.pdf"

        try attachmentStore.write(Data([1]), to: previous)
        try attachmentStore.write(Data([2]), to: replacement, replacing: previous)

        #expect(!FileManager.default.fileExists(atPath: attachmentStore.url(for: previous).path))
        #expect(try attachmentStore.data(for: replacement) == Data([2]))
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!
    }
}

/// AUDIT-002: CloudKit deletions must be explicit and never inferred from a failed local apply.
struct CloudSyncDeletionSafetyTests {
    @Test func undecodableRemoteRecordIsRejectedWithoutBlockingOthers() throws {
        var record = MedicalRecord()
        record.hospital = "Remote"
        let broken = UUID()
        let result = try CloudSyncMerger.apply(
            [
                .upsert(kind: .medicalRecord, id: broken, payload: Data("not-json".utf8)),
                .upsert(kind: .medicalRecord, id: record.id, payload: CloudSyncCoding.encoder().encode(record))
            ],
            to: VaultData(),
            secrets: [],
            enabledModules: [.healthRecords]
        )
        #expect(result.vault.medicalRecords.map(\.hospital) == ["Remote"])
        #expect(result.rejectedKeys == [CloudSyncItem.key(kind: .medicalRecord, id: broken)])
    }

    @Test func pendingLocalApplyIsNeverDeletedAndRoundTrips() throws {
        let entries = makeEntries(count: 3, pendingLocalApply: true)
        let plan = CloudSyncDeletionPlanner.plan(
            entries: entries, currentKeys: [], authorizedModules: [],
            allowsBulkDeletion: false, isActive: { _, _ in true }
        )
        #expect(plan == .init(keys: [], pausedCount: 0))

        let entry = try #require(entries.values.first)
        let decoded = try JSONDecoder().decode(CloudSyncStoredEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.pendingLocalApply)
    }

    @Test func bulkDropIsPausedUntilConfirmed() {
        let entries = makeEntries(count: 40)
        let missing = Set(entries.keys.sorted().prefix(20))
        let current = Set(entries.keys).subtracting(missing)
        func plan(authorized: Set<ToolModule> = [], allowsBulk: Bool = false) -> CloudSyncDeletionPlanner.Plan {
            CloudSyncDeletionPlanner.plan(
                entries: entries, currentKeys: current, authorizedModules: authorized,
                allowsBulkDeletion: allowsBulk, isActive: { _, _ in true }
            )
        }
        #expect(plan() == .init(keys: [], pausedCount: 20))
        #expect(Set(plan(authorized: [.healthRecords]).keys) == missing)
        #expect(Set(plan(allowsBulk: true).keys) == missing)
    }

    @Test func smallOrProportionallyMinorDeletionsAreNotPaused() {
        let few = makeEntries(count: 30)
        let fewMissing = Set(few.keys.sorted().prefix(19))
        let fewPlan = CloudSyncDeletionPlanner.plan(
            entries: few, currentKeys: Set(few.keys).subtracting(fewMissing), authorizedModules: [],
            allowsBulkDeletion: false, isActive: { _, _ in true }
        )
        #expect(Set(fewPlan.keys) == fewMissing)

        let many = makeEntries(count: 100)
        let manyMissing = Set(many.keys.sorted().prefix(20))
        let manyPlan = CloudSyncDeletionPlanner.plan(
            entries: many, currentKeys: Set(many.keys).subtracting(manyMissing), authorizedModules: [],
            allowsBulkDeletion: false, isActive: { _, _ in true }
        )
        #expect(manyPlan.pausedCount == 0)
        #expect(Set(manyPlan.keys) == manyMissing)
    }

    @Test func remoteHardDeletionKeepsOnlyUnsentLocalChanges() {
        let local = CloudSyncStoredEntry(
            kind: .credentialDocument, id: UUID(), module: .documents, modifiedAt: Date(),
            deviceID: "this-device", isDeleted: false, payload: Data([1])
        )
        func keeps(_ entry: CloudSyncStoredEntry, pending: Bool) -> Bool {
            CloudSyncDeletionPlanner.keepsLocalCopy(
                against: entry, deviceID: "this-device", hasPendingSave: pending
            )
        }
        #expect(keeps(local, pending: true))
        var retrying = local
        retrying.needsRetry = true
        #expect(keeps(retrying, pending: false))

        // Already uploaded (payload dropped), written elsewhere, or deleted here.
        #expect(!keeps(local, pending: false))
        var uploaded = local
        uploaded.payload = nil
        #expect(!keeps(uploaded, pending: true))
        var remote = local
        remote.deviceID = "other-device"
        #expect(!keeps(remote, pending: true))
        var deleted = local
        deleted.isDeleted = true
        #expect(!keeps(deleted, pending: true))
    }

    @Test func restoredRecordOutranksTheDeletionThatRemovedIt() {
        let now = Date(timeIntervalSince1970: 2_000)
        let deletion = CloudSyncStoredEntry(
            kind: .credentialDocument, id: UUID(), modifiedAt: Date(timeIntervalSince1970: 1_500),
            deviceID: "server", isDeleted: true
        )
        let edited = Date(timeIntervalSince1970: 1_000)
        #expect(CloudSyncStoredEntry.modifiedAt(editedAt: edited, previous: deletion, now: now) == now)
    }

    @Test func deletionSummaryGroupsByKindWithMaskedIDs() {
        let id = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000000")!
        let keys = [
            CloudSyncItem.key(kind: .medicalRecord, id: id),
            CloudSyncItem.key(kind: .medicalRecord, id: UUID()),
            CloudSyncItem.key(kind: .credentialDocument, id: id)
        ]
        let summary = CloudSyncDeletionPlanner.summary(of: keys)
        #expect(summary.hasPrefix("共 3 条："))
        #expect(summary.contains("credentialDocument×1 eg="))
        #expect(summary.contains("medicalRecord×2 eg="))
        #expect(!summary.contains(id.uuidString) && !summary.contains(id.uuidString.lowercased()))
    }

    private func makeEntries(count: Int, pendingLocalApply: Bool = false) -> [String: CloudSyncStoredEntry] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { _ in
            let id = UUID()
            return (CloudSyncItem.key(kind: .medicalRecord, id: id), CloudSyncStoredEntry(
                kind: .medicalRecord, id: id, module: .healthRecords, modifiedAt: Date(),
                deviceID: "device-a", isDeleted: false, payload: Data([1]),
                pendingLocalApply: pendingLocalApply
            ))
        })
    }
}
