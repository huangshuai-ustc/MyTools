import CloudKit
import Foundation
import Testing
@testable import MyTools

struct CloudSyncMergerTests {
    @Test func snapshotContainsOnlyEnabledModuleEntities() throws {
        var account = BankAccount()
        account.name = "Account"
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

        #expect(Set(snapshot.items.map(\.kind)) == [.bankAccount])
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

    @MainActor
    @Test func preferenceSnapshotRoundTripsThroughCloudPayload() throws {
        let defaults = makeDefaults()
        defaults.set(AppAppearanceMode.dark.rawValue, forKey: AppStorageKey.appearanceMode)
        defaults.set(AppFontSize.accessibility2.rawValue, forKey: AppStorageKey.fontSize)
        let moduleSettings = ToolModuleSettings(defaults: defaults)
        moduleSettings.setVisible(false, for: .healthRecords)
        moduleSettings.moveModules(from: IndexSet(integer: 0), to: ToolModule.allCases.count)
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

    @Test func preferencesDoNotMutateVaultEntities() throws {
        var account = BankAccount()
        account.name = "Retained"

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

        #expect(result.vault.accounts == [account])
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

    @Test func remoteRecordUpdatesOnlyItsMatchingEntity() throws {
        var account = BankAccount()
        account.name = "Before"
        var otherAccount = BankAccount()
        otherAccount.name = "Other"
        var remoteAccount = account
        remoteAccount.name = "After"

        let payload = try CloudSyncCoding.encoder().encode(remoteAccount)
        let result = try CloudSyncMerger.apply(
            [.upsert(kind: .bankAccount, id: account.id, payload: payload)],
            to: VaultData(accounts: [account, otherAccount]),
            secrets: []
        )

        #expect(result.vault.accounts.map(\.name) == ["After", "Other"])
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
        var card = BankCard()
        card.statements = [statement]
        let secret = SecretItem(attachments: [attachment])

        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(cards: [card], medicalRecords: [record]),
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
        let cardPayload = try #require(
            snapshot.items.first(where: { $0.kind == .bankCard })?.payload
        )
        let syncedCard = try CloudSyncCoding.decoder().decode(BankCard.self, from: cardPayload)
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
