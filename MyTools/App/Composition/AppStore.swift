import Foundation
import Combine
import OSLog

private let startupLogger = Logger(
    subsystem: AppMetadata.bundleIdentifier,
    category: "Startup"
)

private struct SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults
}

struct PendingModuleLocalDataDeletion: Identifiable, Equatable, Sendable {
    let id: UUID
    let module: ToolModule
    let expiresAt: Date
}

private struct ModuleLocalDataDeletionSnapshot {
    let module: ToolModule
    let vault: VaultData
    let secrets: [SecretVaultValue]
}

@MainActor
final class AppStore: ObservableObject, VaultMutationNotifying {
    @Published private(set) var isInitialDataLoaded = false
    @Published private(set) var isVaultLoadFailurePresented = false
    @Published private(set) var persistenceError: String?
    @Published private(set) var pendingModuleLocalDataDeletion: PendingModuleLocalDataDeletion?
#if MYTOOLS_FEATURE_STOCKS
    let stockStore: StockStore
#endif
    let exchangeRateStore: ExchangeRateStore
#if MYTOOLS_FEATURE_HEALTH
    let healthStore: HealthStore
#endif
#if MYTOOLS_FEATURE_FINANCE
    let financeStore: FinanceStore
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
    let foodMapStore: FoodMapStore
#endif
#if MYTOOLS_FEATURE_SECRETS
    let secretStore: SecretStore
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
    let documentsStore: DocumentsStore
#endif
#if MYTOOLS_FEATURE_BILLS
    let billsStore: BillsStore
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
    let currencyExchangeStore: CurrencyExchangeStore
#endif
    let cloudSync: CloudSyncCoordinator
    private let persistence: any VaultPersisting
    private let backupProcessor: any VaultBackupProcessing
    private let attachmentStore: AttachmentStore
    private let moduleSettings: ToolModuleSettings
    private let moduleLifecycleRegistry: ModuleLifecycleRegistry
    private let moduleDataCleanupRegistry: ModuleDataCleanupRegistry
    private let cloudSyncPreferences: CloudSyncPreferencesBridge
    private let defaults: UserDefaults
    private let moduleLocalDataCacheCleaner: any ModuleLocalDataCacheClearing
    private var isRestoringBackup = false
    private var isApplyingCloudChanges = false
    private var canPersistVault = true
    private var didLogPersistenceBlocked = false
    private var retainedVault: VaultData
    private var retainedSecrets: [SecretVaultValue]
    private var pendingModuleDeletionSnapshot: ModuleLocalDataDeletionSnapshot?
    private var pendingModuleDeletionTask: Task<Void, Never>?

    init(
        initialVault: VaultData? = nil,
        secretItems: [SecretVaultValue] = [],
        moduleSettings: ToolModuleSettings? = nil,
        stockAppearanceSettings: StockAppearanceSettings? = nil,
        dependencies: AppStoreDependencies
    ) {
        let moduleSettings = moduleSettings ?? ToolModuleSettings(defaults: dependencies.defaults)
        let stockAppearanceSettings = stockAppearanceSettings
            ?? StockAppearanceSettings(defaults: dependencies.defaults)
        self.moduleSettings = moduleSettings
        defaults = dependencies.defaults
        moduleLocalDataCacheCleaner = dependencies.moduleLocalDataCacheCleaner
        retainedVault = initialVault ?? VaultData()
        retainedSecrets = secretItems
        moduleLifecycleRegistry = ModuleLifecycleRegistry()
        moduleDataCleanupRegistry = ModuleDataCleanupRegistry()
        cloudSyncPreferences = CloudSyncPreferencesBridge(
            defaults: dependencies.defaults,
            moduleSettings: moduleSettings,
            stockAppearanceSettings: stockAppearanceSettings
        )
        persistence = dependencies.persistence
        backupProcessor = dependencies.backupProcessor
        let attachmentStore = dependencies.attachmentStore
        self.attachmentStore = attachmentStore
        cloudSync = dependencies.cloudSync ?? .disabled(
            defaults: dependencies.defaults,
            attachmentStore: attachmentStore
        )
        let exchangeRateStore = ExchangeRateStore(
            repository: dependencies.exchangeRateRepository,
            moduleSettings: moduleSettings
        )
        self.exchangeRateStore = exchangeRateStore
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        currencyExchangeStore = CurrencyExchangeStore(
            records: initialVault?.currencyExchangeRecords ?? [],
            rateAlerts: initialVault?.currencyRateAlerts ?? [],
            alertNotifications: dependencies.alertNotifications,
            moduleSettings: moduleSettings,
            exchangeRateStore: exchangeRateStore
        )
#endif
#if MYTOOLS_FEATURE_STOCKS
        stockStore = StockStore(
            stocks: initialVault?.stocks ?? [],
            priceAlerts: initialVault?.stockPriceAlerts ?? [],
            isDataLoaded: initialVault != nil,
            quoteService: dependencies.quoteService,
            alertNotifications: dependencies.alertNotifications,
            refreshInvalidator: dependencies.stockRefreshInvalidator,
            defaults: dependencies.defaults,
            moduleSettings: moduleSettings,
            exchangeRateStore: exchangeRateStore
        )
#endif
#if MYTOOLS_FEATURE_HEALTH
        healthStore = HealthStore(
            medicalRecords: initialVault?.medicalRecords ?? [],
            hospitalProfiles: initialVault?.hospitalProfiles ?? [],
            knownTags: initialVault?.medicalRecordTags ?? [],
            attachmentStore: attachmentStore,
            moduleSettings: moduleSettings
        )
#endif
#if MYTOOLS_FEATURE_FINANCE
        financeStore = FinanceStore(
            accounts: initialVault?.accounts ?? [],
            cards: initialVault?.cards ?? [],
            domesticLoginFieldTemplates: initialVault?.domesticBankLoginFieldTemplates ?? [],
            overseasLoginFieldTemplates: initialVault?.overseasBankLoginFieldTemplates ?? [],
            attachmentStore: attachmentStore
        )
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        foodMapStore = FoodMapStore(
            places: initialVault?.foodPlaces ?? [],
            knownTags: initialVault?.foodPlaceTags ?? [],
            attachmentStore: attachmentStore
        )
#endif
#if MYTOOLS_FEATURE_SECRETS
        secretStore = SecretStore(
            secretItems: secretItems,
            fieldTemplates: initialVault?.secretFieldTemplates ?? [],
            knownTags: initialVault?.secretTags ?? [],
            attachmentStore: attachmentStore
        )
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        documentsStore = DocumentsStore(
            documents: initialVault?.credentialDocuments ?? [],
            fieldTemplates: initialVault?.credentialFieldTemplates ?? [],
            knownTags: initialVault?.credentialTags ?? [],
            attachmentStore: attachmentStore,
            notificationScheduler: dependencies.localNotificationScheduler,
            moduleSettings: moduleSettings
        )
#endif
#if MYTOOLS_FEATURE_BILLS
        billsStore = BillsStore(
            records: initialVault?.billRecords ?? [],
            knownTags: initialVault?.billTags ?? []
        )
#endif
#if MYTOOLS_FEATURE_STOCKS
        moduleLifecycleRegistry.register(stockStore)
#endif
        moduleLifecycleRegistry.register(exchangeRateStore)
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        moduleLifecycleRegistry.register(currencyExchangeStore)
#endif
#if MYTOOLS_FEATURE_HEALTH
        moduleLifecycleRegistry.register(healthStore)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        moduleLifecycleRegistry.register(documentsStore)
#endif
#if MYTOOLS_FEATURE_FINANCE
        moduleDataCleanupRegistry.register(financeStore)
#endif
#if MYTOOLS_FEATURE_HEALTH
        moduleDataCleanupRegistry.register(healthStore)
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        moduleDataCleanupRegistry.register(foodMapStore)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        moduleDataCleanupRegistry.register(documentsStore)
#endif
#if MYTOOLS_FEATURE_STOCKS
        stockStore.attach(mutationNotifier: self)
#endif
#if MYTOOLS_FEATURE_HEALTH
        healthStore.attach(mutationNotifier: self)
#endif
#if MYTOOLS_FEATURE_FINANCE
        financeStore.attach(mutationNotifier: self)
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        foodMapStore.attach(mutationNotifier: self)
#endif
#if MYTOOLS_FEATURE_SECRETS
        secretStore.attach(mutationNotifier: self)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        documentsStore.attach(mutationNotifier: self)
#endif
#if MYTOOLS_FEATURE_BILLS
        billsStore.attach(mutationNotifier: self)
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        currencyExchangeStore.attach(mutationNotifier: self)
        exchangeRateStore.attach(updateObserver: currencyExchangeStore)
#endif
        cloudSync.attach(
            snapshotProvider: { [weak self] in
                guard let self else { return .empty }
                return try await self.makeCloudSyncSnapshot()
            },
            changeHandler: { [weak self] changes in
                try self?.applyCloudSyncChanges(changes)
            }
        )
        moduleSettings.setVisibilityChangeHandler { [weak self] module, isVisible in
            self?.moduleVisibilityChanged(module, isVisible: isVisible)
        }
        moduleSettings.setPreferenceChangeHandler { [weak self] in
            self?.preferenceSettingsDidChange()
        }
        stockAppearanceSettings.setChangeHandler { [weak self] in
            self?.preferenceSettingsDidChange()
        }

        if initialVault != nil {
            isInitialDataLoaded = true
#if MYTOOLS_FEATURE_HEALTH
            healthStore.synchronizeLoadedRecords()
#endif
            cloudSync.localDataDidLoad()
            return
        }

        let defaults = SendableUserDefaults(value: dependencies.defaults)
        let initialLoader = dependencies.initialLoader
        Task { [weak self] in
            let cachedRatesTask = Task.detached(priority: .utility) {
                ExchangeRateRepository.loadCachedSnapshot(defaults: defaults.value)
            }
            let snapshot = await Task.detached(priority: .userInitiated) {
                initialLoader.loadVaultWithMetrics()
            }.value
            guard let self else { return }
            self.applyInitialSnapshot(snapshot)
            self.applyExchangeRateSnapshot(await cachedRatesTask.value)
        }
    }

    func moduleVisibilityChanged(_ module: ToolModule, isVisible: Bool) {
        guard module != .healthRecords || isInitialDataLoaded else { return }
        moduleLifecycleRegistry.notify(module: module, isEnabled: isVisible)
    }

    func preferenceSettingsDidChange() {
        guard !isApplyingCloudChanges else { return }
        cloudSync.localDataDidChange()
    }

    private func isModuleVisible(_ module: ToolModule) -> Bool {
        moduleSettings.isVisible(module)
    }

    private func applyInitialSnapshot(_ snapshot: LocalVaultLoadResult) {
        retainedVault = snapshot.vault
        retainedSecrets = snapshot.secrets
        applyVault(snapshot.vault)
#if MYTOOLS_FEATURE_SECRETS
        secretStore.replace(
            secretItems: snapshot.secrets,
            fieldTemplates: snapshot.vault.secretFieldTemplates,
            knownTags: snapshot.vault.secretTags
        )
#endif
        canPersistVault = snapshot.canPersist
#if MYTOOLS_FEATURE_HEALTH
        healthStore.synchronizeLoadedRecords()
#endif
        isVaultLoadFailurePresented = !snapshot.canPersist
        didLogPersistenceBlocked = false
        isInitialDataLoaded = true
        cloudSync.localDataDidLoad()
        let loadSummary = "Local vault loaded from \(snapshot.source): \(snapshot.byteCount) bytes; read \(snapshot.readMilliseconds) ms, decode \(snapshot.decodeMilliseconds) ms, total \(snapshot.totalMilliseconds) ms"
        startupLogger.info("\(loadSummary, privacy: .public)")
        DiagnosticLogger.shared.log(.startup, loadSummary)
    }

    private func applyExchangeRateSnapshot(_ snapshot: ExchangeRateSnapshot) {
        exchangeRateStore.applyCachedSnapshot(snapshot)
    }

    private func applyVault(_ vault: VaultData) {
        retainedVault = vault
#if MYTOOLS_FEATURE_FINANCE
        financeStore.replace(
            accounts: vault.accounts,
            cards: vault.cards,
            domesticLoginFieldTemplates: vault.domesticBankLoginFieldTemplates,
            overseasLoginFieldTemplates: vault.overseasBankLoginFieldTemplates
        )
#endif
#if MYTOOLS_FEATURE_STOCKS
        stockStore.replace(
            stocks: vault.stocks,
            priceAlerts: vault.stockPriceAlerts,
            isDataLoaded: true
        )
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        currencyExchangeStore.replace(
            records: vault.currencyExchangeRecords,
            rateAlerts: vault.currencyRateAlerts
        )
#endif
#if MYTOOLS_FEATURE_HEALTH
        healthStore.replace(
            medicalRecords: vault.medicalRecords,
            hospitalProfiles: vault.hospitalProfiles,
            knownTags: vault.medicalRecordTags
        )
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        foodMapStore.replace(places: vault.foodPlaces, knownTags: vault.foodPlaceTags)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        documentsStore.replace(
            documents: vault.credentialDocuments,
            fieldTemplates: vault.credentialFieldTemplates,
            knownTags: vault.credentialTags
        )
#endif
#if MYTOOLS_FEATURE_BILLS
        billsStore.replace(records: vault.billRecords, knownTags: vault.billTags)
#endif
    }

    func makeBackupDocument(password: String) async throws -> VaultBackupDocument {
        let includedModules = Set(
            CompiledToolModules.ordered.filter { isModuleVisible($0) }
        )
        let data: Data
        do {
            data = try await backupProcessor.makeBackup(
                vault: currentVaultData(),
                secrets: currentSecrets,
                includedModules: includedModules,
                password: password
            )
        } catch {
            DiagnosticLogger.logError(.backup, operation: "导出加密备份失败", error: error)
            throw error
        }
        return VaultBackupDocument(data: data)
    }

    func restoreBackup(from data: Data, password: String) async throws {
        isRestoringBackup = true
#if MYTOOLS_FEATURE_SECRETS
        secretStore.setBackupRestoreInProgress(true)
#endif
        defer {
#if MYTOOLS_FEATURE_SECRETS
            secretStore.setBackupRestoreInProgress(false)
#endif
            isRestoringBackup = false
        }
        let restoredPayload: VaultBackupPayload
        let enabledModules = self.enabledModules
        do {
            restoredPayload = try await backupProcessor.restorePayload(
                from: data,
                password: password,
                enabledModules: enabledModules
            )
        } catch {
            DiagnosticLogger.logError(.backup, operation: "导入加密备份失败", error: error)
            throw error
        }
        let mergedPayload = AppStoreBackupMerger.merge(
            localVault: currentVaultData(),
            localSecrets: currentSecrets,
            imported: restoredPayload,
            enabledModules: enabledModules
        )
        do {
            try await Task.detached(priority: .userInitiated) { [persistence] in
                try persistence.saveImmediately(
                    mergedPayload.vault,
                    secrets: mergedPayload.secrets
                )
            }.value
        } catch {
            DiagnosticLogger.logError(.backup, operation: "保存增量备份导入结果失败", error: error)
            throw error
        }
        applyVault(mergedPayload.vault)
        retainedSecrets = mergedPayload.secrets
#if MYTOOLS_FEATURE_SECRETS
        secretStore.replace(
            secretItems: mergedPayload.secrets,
            fieldTemplates: mergedPayload.vault.secretFieldTemplates,
            knownTags: mergedPayload.vault.secretTags
        )
#endif
        canPersistVault = true
        didLogPersistenceBlocked = false
        persistenceError = nil
#if MYTOOLS_FEATURE_STOCKS
        if restoredPayload.includedModules.contains(.myStocks) {
            stockStore.clearNotificationState(
                for: Set(restoredPayload.vault.stockPriceAlerts.map(\.id))
            )
        }
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        if restoredPayload.includedModules.contains(.currencyExchange) {
            currencyExchangeStore.clearNotificationState(
                for: Set(restoredPayload.vault.currencyRateAlerts.map(\.id))
            )
        }
#endif
        cloudSync.localDataDidChange()
    }

    func flushPendingPersistence() async {
        if let errorCode = await persistence.flush() {
            persistenceError = "本地数据未能保存（错误码：\(errorCode)）。原有档案仍然保留，请导出调试日志检查。"
        }
    }

    func dismissVaultLoadFailure() {
        isVaultLoadFailurePresented = false
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    func moduleStoreDidMutate() {
        persist()
        if !isApplyingCloudChanges {
            cloudSync.localDataDidChange()
        }
    }

    /// Quote fields are intentionally local-only and excluded from the
    /// CloudKit portfolio snapshot. Persist them without re-encoding every
    /// business record merely to discover that there is nothing to upload.
    func moduleStoreDidMutateLocalOnly() {
        persist()
    }

    func scanRedundantData() -> RedundantDataCleanupReport {
        guard isInitialDataLoaded else { return .empty }
        return moduleDataCleanupRegistry.scan(enabledModules: enabledModules)
    }

    @discardableResult
    func cleanupRedundantData() -> RedundantDataCleanupReport {
        guard isInitialDataLoaded, canPersistVault else { return .empty }
        let report = moduleDataCleanupRegistry.cleanup(enabledModules: enabledModules)
        if !report.isEmpty {
            moduleStoreDidMutate()
        }
        return report
    }

    @discardableResult
    func beginModuleLocalDataDeletion(
        for module: ToolModule,
        undoWindow: TimeInterval = 10
    ) -> PendingModuleLocalDataDeletion? {
        guard isInitialDataLoaded,
              canPersistVault,
              pendingModuleLocalDataDeletion == nil,
              CompiledToolModules.ordered.contains(module) else { return nil }

        let deletion = PendingModuleLocalDataDeletion(
            id: UUID(),
            module: module,
            expiresAt: Date().addingTimeInterval(max(undoWindow, 0))
        )
        pendingModuleDeletionSnapshot = ModuleLocalDataDeletionSnapshot(
            module: module,
            vault: currentVaultData(),
            secrets: currentSecrets
        )
        pendingModuleLocalDataDeletion = deletion
        let didChangeVault = clearLocalData(for: module)
        if didChangeVault {
            persist()
        }

        pendingModuleDeletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(undoWindow, 0)))
            guard !Task.isCancelled else { return }
            await self?.commitModuleLocalDataDeletion(id: deletion.id)
        }
        return deletion
    }

    @discardableResult
    func undoModuleLocalDataDeletion(id: UUID) -> Bool {
        guard let deletion = pendingModuleLocalDataDeletion,
              deletion.id == id,
              Date() < deletion.expiresAt,
              let snapshot = pendingModuleDeletionSnapshot,
              snapshot.module == deletion.module else { return false }

        pendingModuleDeletionTask?.cancel()
        pendingModuleDeletionTask = nil
        restoreLocalData(from: snapshot)
        pendingModuleDeletionSnapshot = nil
        pendingModuleLocalDataDeletion = nil
        persist()
        cloudSync.localDataDidChange()
        return true
    }

    func commitModuleLocalDataDeletion(id: UUID) async {
        guard let deletion = pendingModuleLocalDataDeletion,
              deletion.id == id,
              let snapshot = pendingModuleDeletionSnapshot,
              snapshot.module == deletion.module else { return }

        pendingModuleDeletionTask?.cancel()
        pendingModuleDeletionTask = nil
        pendingModuleDeletionSnapshot = nil
        pendingModuleLocalDataDeletion = nil
        finalizeLocalDataDeletion(snapshot)
        cloudSync.localDataDidChange()
        await moduleLocalDataCacheCleaner.clearLocalCache(for: deletion.module)
    }

    func clearLocalCache(for module: ToolModule) async {
        guard isInitialDataLoaded,
              CompiledToolModules.ordered.contains(module) else { return }

        switch module {
        case .myStocks:
#if MYTOOLS_FEATURE_STOCKS
            stockStore.clearLocalRefreshState()
#endif
            exchangeRateStore.clearLocalCache()
        case .currencyExchange:
            exchangeRateStore.clearLocalCache()
        case .personalFinance, .healthRecords, .foodMap, .secrets,
             .documents, .bills, .sportsLottery:
            break
        }
        await moduleLocalDataCacheCleaner.clearLocalCache(for: module)
    }

    private func persist() {
        guard !isRestoringBackup, canPersistVault else {
            if !canPersistVault, !didLogPersistenceBlocked {
                didLogPersistenceBlocked = true
                DiagnosticLogger.shared.log(
                    .persistence,
                    "本地存档未成功读取，已拦截写入以保护原文件",
                    level: .error
                )
            }
            return
        }
        persistence.schedule(currentVaultData(), secrets: currentSecrets)
    }

    private func currentVaultData() -> VaultData {
        var vault = retainedVault
#if MYTOOLS_FEATURE_FINANCE
        vault.accounts = financeStore.accounts
        vault.cards = financeStore.cards
        vault.domesticBankLoginFieldTemplates = financeStore.domesticLoginFieldTemplates
        vault.overseasBankLoginFieldTemplates = financeStore.overseasLoginFieldTemplates
#endif
#if MYTOOLS_FEATURE_STOCKS
        vault.stocks = stockStore.stocks
        vault.stockPriceAlerts = stockStore.priceAlerts
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        vault.currencyExchangeRecords = currencyExchangeStore.records
        vault.currencyRateAlerts = currencyExchangeStore.rateAlerts
#endif
#if MYTOOLS_FEATURE_HEALTH
        vault.medicalRecords = healthStore.medicalRecords
        vault.hospitalProfiles = healthStore.hospitalProfiles
        vault.medicalRecordTags = healthStore.knownTags
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        vault.foodPlaces = foodMapStore.places
        vault.foodPlaceTags = foodMapStore.knownTags
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        vault.credentialDocuments = documentsStore.documents
        vault.credentialFieldTemplates = documentsStore.fieldTemplates
        vault.credentialTags = documentsStore.knownTags
#endif
#if MYTOOLS_FEATURE_BILLS
        vault.billRecords = billsStore.records
        vault.billTags = billsStore.knownTags
#endif
#if MYTOOLS_FEATURE_SECRETS
        vault.secretFieldTemplates = secretStore.fieldTemplates
        vault.secretTags = secretStore.knownTags
#endif
        return vault
    }

    private var currentSecrets: [SecretVaultValue] {
#if MYTOOLS_FEATURE_SECRETS
        secretStore.secretItems
#else
        retainedSecrets
#endif
    }

    func makeCloudSyncSnapshot() async throws -> CloudSyncSnapshot {
        let vault = currentVaultData()
        let secrets = currentSecrets
        let attachmentStore = self.attachmentStore
        let appPreferences = cloudSyncPreferences.makeSnapshot()
        let enabledModules = cloudSyncModules
        return try await Task.detached(priority: .utility) {
            try CloudSyncSnapshotBuilder.make(
                vault: vault,
                secrets: secrets,
                attachmentStore: attachmentStore,
                appPreferences: appPreferences,
                enabledModules: enabledModules
            )
        }.value
    }

    private func applyCloudSyncChanges(_ changes: [CloudSyncChange]) throws {
        guard canPersistVault else {
            throw CloudSyncApplyError.localVaultUnavailable
        }
        let previousAttachments = attachmentsByID(
            vault: currentVaultData(),
            secrets: currentSecrets
        )
        var incomingPreferences: CloudSyncAppPreferences?
        for change in changes {
            guard case .upsert(let kind, let id, let payload) = change,
                  kind == .appPreferences,
                  id == CloudSyncAppPreferences.itemID else { continue }
            incomingPreferences = try CloudSyncCoding.decoder().decode(
                CloudSyncAppPreferences.self,
                from: payload
            )
        }
        let merged = try CloudSyncMerger.apply(
            changes,
            to: currentVaultData(),
            secrets: currentSecrets,
            enabledModules: cloudSyncModules
        )

        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        applyVault(merged.vault)
        retainedSecrets = merged.secrets
#if MYTOOLS_FEATURE_SECRETS
        secretStore.replace(
            secretItems: merged.secrets,
            fieldTemplates: merged.vault.secretFieldTemplates,
            knownTags: merged.vault.secretTags
        )
#endif
        if let incomingPreferences {
            try cloudSyncPreferences.apply(incomingPreferences)
        }
        let finalVault = currentVaultData()
        let retainedAttachmentIDs = Set(
            attachmentsByID(vault: finalVault, secrets: merged.secrets).keys
        )
        for (id, attachment) in previousAttachments where !retainedAttachmentIDs.contains(id) {
            attachmentStore.delete(attachment)
        }
        persistence.schedule(finalVault, secrets: merged.secrets)
        cloudSync.localDataDidChange()
    }

    private var enabledModules: Set<ToolModule> {
        var modules = Set(CompiledToolModules.ordered.filter { isModuleVisible($0) })
        if let pendingModuleLocalDataDeletion {
            modules.remove(pendingModuleLocalDataDeletion.module)
        }
        return modules
    }

    private var cloudSyncModules: Set<ToolModule> {
        var modules = ToolModuleCatalog.cloudSyncModules
        if let pendingModuleLocalDataDeletion {
            modules.remove(pendingModuleLocalDataDeletion.module)
        }
        return modules
    }

    @discardableResult
    private func clearLocalData(for module: ToolModule) -> Bool {
        var vault = currentVaultData()
        var secrets = currentSecrets

        switch module {
        case .personalFinance:
#if MYTOOLS_FEATURE_FINANCE
            vault.accounts = []
            vault.cards = []
#endif
            break
        case .myStocks:
#if MYTOOLS_FEATURE_STOCKS
            vault.stocks = []
            vault.stockPriceAlerts = []
#endif
            break
        case .currencyExchange:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
            vault.currencyExchangeRecords = []
            vault.currencyRateAlerts = []
#endif
            break
        case .healthRecords:
#if MYTOOLS_FEATURE_HEALTH
            vault.medicalRecords = []
            vault.hospitalProfiles = []
            vault.medicalRecordTags = []
#endif
            break
        case .foodMap:
#if MYTOOLS_FEATURE_FOOD_MAP
            vault.foodPlaces = []
            vault.foodPlaceTags = []
#endif
            break
        case .secrets:
#if MYTOOLS_FEATURE_SECRETS
            secrets = []
            vault.secretFieldTemplates = []
            vault.secretTags = []
#endif
            break
        case .documents:
#if MYTOOLS_FEATURE_DOCUMENTS
            vault.credentialDocuments = []
            vault.credentialFieldTemplates = []
            vault.credentialTags = []
#endif
            break
        case .bills:
#if MYTOOLS_FEATURE_BILLS
            vault.billRecords = []
            vault.billTags = []
#endif
            break
        case .sportsLottery:
            break
        }

        applyVault(vault)
        retainedSecrets = secrets
#if MYTOOLS_FEATURE_SECRETS
        if module == .secrets {
            secretStore.replace(
                secretItems: secrets,
                fieldTemplates: vault.secretFieldTemplates,
                knownTags: vault.secretTags
            )
        }
#endif
        return module.definition.capabilities.contains(.localVault)
    }

    private func restoreLocalData(from snapshot: ModuleLocalDataDeletionSnapshot) {
        var vault = currentVaultData()
        var secrets = currentSecrets

        switch snapshot.module {
        case .personalFinance:
#if MYTOOLS_FEATURE_FINANCE
            vault.accounts = mergingRestored(snapshot.vault.accounts, into: vault.accounts)
            vault.cards = mergingRestored(snapshot.vault.cards, into: vault.cards)
#endif
            break
        case .myStocks:
#if MYTOOLS_FEATURE_STOCKS
            vault.stocks = mergingRestored(snapshot.vault.stocks, into: vault.stocks)
            vault.stockPriceAlerts = mergingRestored(
                snapshot.vault.stockPriceAlerts,
                into: vault.stockPriceAlerts
            )
#endif
            break
        case .currencyExchange:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
            vault.currencyExchangeRecords = mergingRestored(
                snapshot.vault.currencyExchangeRecords,
                into: vault.currencyExchangeRecords
            )
            vault.currencyRateAlerts = mergingRestored(
                snapshot.vault.currencyRateAlerts,
                into: vault.currencyRateAlerts
            )
#endif
            break
        case .healthRecords:
#if MYTOOLS_FEATURE_HEALTH
            vault.medicalRecords = mergingRestored(
                snapshot.vault.medicalRecords,
                into: vault.medicalRecords
            )
            vault.hospitalProfiles = mergingRestored(
                snapshot.vault.hospitalProfiles,
                into: vault.hospitalProfiles
            )
            vault.medicalRecordTags = AppTagSupport.merged(
                vault.medicalRecordTags,
                with: snapshot.vault.medicalRecordTags
            )
#endif
            break
        case .foodMap:
#if MYTOOLS_FEATURE_FOOD_MAP
            vault.foodPlaces = mergingRestored(snapshot.vault.foodPlaces, into: vault.foodPlaces)
            vault.foodPlaceTags = AppTagSupport.merged(
                vault.foodPlaceTags,
                with: snapshot.vault.foodPlaceTags
            )
#endif
            break
        case .secrets:
#if MYTOOLS_FEATURE_SECRETS
            secrets = mergingRestored(snapshot.secrets, into: secrets)
            vault.secretFieldTemplates = mergingRestored(
                snapshot.vault.secretFieldTemplates,
                into: vault.secretFieldTemplates
            )
            vault.secretTags = AppTagSupport.merged(
                vault.secretTags,
                with: snapshot.vault.secretTags
            )
#endif
            break
        case .documents:
#if MYTOOLS_FEATURE_DOCUMENTS
            vault.credentialDocuments = mergingRestored(
                snapshot.vault.credentialDocuments,
                into: vault.credentialDocuments
            )
            vault.credentialFieldTemplates = mergingRestored(
                snapshot.vault.credentialFieldTemplates,
                into: vault.credentialFieldTemplates
            )
            vault.credentialTags = AppTagSupport.merged(
                vault.credentialTags,
                with: snapshot.vault.credentialTags
            )
#endif
            break
        case .bills:
#if MYTOOLS_FEATURE_BILLS
            vault.billRecords = mergingRestored(snapshot.vault.billRecords, into: vault.billRecords)
            vault.billTags = AppTagSupport.merged(
                vault.billTags,
                with: snapshot.vault.billTags
            )
#endif
            break
        case .sportsLottery:
            break
        }

        applyVault(vault)
        retainedSecrets = secrets
#if MYTOOLS_FEATURE_SECRETS
        if snapshot.module == .secrets {
            secretStore.replace(
                secretItems: secrets,
                fieldTemplates: vault.secretFieldTemplates,
                knownTags: vault.secretTags
            )
        }
#endif
    }

    private func finalizeLocalDataDeletion(_ snapshot: ModuleLocalDataDeletionSnapshot) {
        let retainedAttachmentIDs = Set(
            attachmentsByID(vault: currentVaultData(), secrets: currentSecrets).keys
        )
        for attachment in attachments(
            for: snapshot.module,
            vault: snapshot.vault,
            secrets: snapshot.secrets
        ) where !retainedAttachmentIDs.contains(attachment.id) {
            attachmentStore.delete(attachment)
        }

        switch snapshot.module {
        case .myStocks:
#if MYTOOLS_FEATURE_STOCKS
            stockStore.clearNotificationState(for: Set(snapshot.vault.stockPriceAlerts.map(\.id)))
            stockStore.clearLocalRefreshState()
#endif
            break
        case .currencyExchange:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
            currencyExchangeStore.clearNotificationState(
                for: Set(snapshot.vault.currencyRateAlerts.map(\.id))
            )
#endif
            break
        case .sportsLottery:
#if MYTOOLS_FEATURE_SPORTS_LOTTERY
            defaults.removeObject(forKey: SportsLotteryLeaguePreferences.key)
#endif
            break
        case .personalFinance, .healthRecords, .foodMap, .secrets, .documents, .bills:
            break
        }
    }

    private func attachments(
        for module: ToolModule,
        vault: VaultData,
        secrets: [SecretVaultValue]
    ) -> [FileAttachment] {
        ModuleAttachmentReferenceIndex.attachments(
            for: module,
            vault: vault,
            secrets: secrets
        )
    }

    private func mergingRestored<Value: Identifiable>(
        _ previous: [Value],
        into current: [Value]
    ) -> [Value] where Value.ID: Hashable {
        let currentIDs = Set(current.map(\.id))
        return previous.filter { !currentIDs.contains($0.id) } + current
    }

    private func attachmentsByID(
        vault: VaultData,
        secrets: [SecretVaultValue]
    ) -> [UUID: FileAttachment] {
        ModuleAttachmentReferenceIndex.byID(vault: vault, secrets: secrets)
    }

    var referencedAttachmentStoredFileNames: Set<String> {
        ModuleAttachmentReferenceIndex.referencedStoredFileNames(
            vault: currentVaultData(),
            secrets: currentSecrets
        )
    }

}

private enum CloudSyncApplyError: LocalizedError {
    case localVaultUnavailable

    var errorDescription: String? {
        "本地档案尚未成功读取，暂时不能合并 iCloud 数据。"
    }
}
