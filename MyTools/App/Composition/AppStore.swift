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

@MainActor
final class AppStore: ObservableObject, VaultMutationNotifying {
    @Published private(set) var isInitialDataLoaded = false
    @Published private(set) var isVaultLoadFailurePresented = false
    @Published private(set) var persistenceError: String?
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
    private var isRestoringBackup = false
    private var isApplyingCloudChanges = false
    private var canPersistVault = true
    private var didLogPersistenceBlocked = false
    private var retainedVault: VaultData
    private var retainedSecrets: [SecretVaultValue]

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
            attachmentStore: attachmentStore,
            moduleSettings: moduleSettings
        )
#endif
#if MYTOOLS_FEATURE_FINANCE
        financeStore = FinanceStore(
            accounts: initialVault?.accounts ?? [],
            cards: initialVault?.cards ?? [],
            attachmentStore: attachmentStore
        )
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        foodMapStore = FoodMapStore(
            places: initialVault?.foodPlaces ?? [],
            attachmentStore: attachmentStore
        )
#endif
#if MYTOOLS_FEATURE_SECRETS
        secretStore = SecretStore(
            secretItems: secretItems,
            attachmentStore: attachmentStore
        )
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        documentsStore = DocumentsStore(
            documents: initialVault?.credentialDocuments ?? [],
            attachmentStore: attachmentStore,
            notificationScheduler: dependencies.localNotificationScheduler,
            moduleSettings: moduleSettings
        )
#endif
#if MYTOOLS_FEATURE_BILLS
        billsStore = BillsStore(records: initialVault?.billRecords ?? [])
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
                return try self.makeCloudSyncSnapshot()
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
        secretStore.replace(secretItems: snapshot.secrets)
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
        financeStore.replace(accounts: vault.accounts, cards: vault.cards)
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
            hospitalProfiles: vault.hospitalProfiles
        )
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        foodMapStore.replace(places: vault.foodPlaces)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        documentsStore.replace(documents: vault.credentialDocuments)
#endif
#if MYTOOLS_FEATURE_BILLS
        billsStore.replace(records: vault.billRecords)
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
        secretStore.replace(secretItems: mergedPayload.secrets)
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
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        vault.foodPlaces = foodMapStore.places
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        vault.credentialDocuments = documentsStore.documents
#endif
#if MYTOOLS_FEATURE_BILLS
        vault.billRecords = billsStore.records
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

    private func makeCloudSyncSnapshot() throws -> CloudSyncSnapshot {
        try CloudSyncSnapshotBuilder.make(
            vault: currentVaultData(),
            secrets: currentSecrets,
            attachmentStore: attachmentStore,
            appPreferences: cloudSyncPreferences.makeSnapshot(),
            enabledModules: enabledModules
        )
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
            enabledModules: enabledModules
        )

        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        applyVault(merged.vault)
        retainedSecrets = merged.secrets
#if MYTOOLS_FEATURE_SECRETS
        secretStore.replace(secretItems: merged.secrets)
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
        Set(CompiledToolModules.ordered.filter { isModuleVisible($0) })
    }

    private func attachmentsByID(
        vault: VaultData,
        secrets: [SecretVaultValue]
    ) -> [UUID: FileAttachment] {
        var values: [FileAttachment] = []
#if MYTOOLS_FEATURE_FINANCE
        values += vault.cards.flatMap(\.statements).compactMap(\.attachment)
#endif
#if MYTOOLS_FEATURE_HEALTH
        values += vault.medicalRecords.flatMap(\.attachments)
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        values += vault.foodPlaces.flatMap(\.photos)
#endif
#if MYTOOLS_FEATURE_SECRETS
        values += secrets.flatMap(\.attachments)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        values += vault.credentialDocuments.flatMap(\.attachmentFiles)
#endif
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    var referencedAttachmentStoredFileNames: Set<String> {
        let vault = currentVaultData()
        var result = vault.opaqueAttachmentStoredFileNames
#if MYTOOLS_FEATURE_FINANCE
        result.formUnion(
            vault.cards.flatMap(\.statements).compactMap(\.attachment).map(\.storedFileName)
        )
#endif
#if MYTOOLS_FEATURE_HEALTH
        result.formUnion(vault.medicalRecords.flatMap(\.attachments).map(\.storedFileName))
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        result.formUnion(vault.foodPlaces.flatMap(\.photos).map(\.storedFileName))
#endif
#if MYTOOLS_FEATURE_SECRETS
        result.formUnion(currentSecrets.flatMap(\.attachments).map(\.storedFileName))
#else
        result.formUnion(currentSecrets.flatMap(\.attachmentStoredFileNames))
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        result.formUnion(vault.credentialDocuments.flatMap(\.attachmentFiles).map(\.storedFileName))
#endif
        return result.filter { !$0.isEmpty }
    }

}

private enum CloudSyncApplyError: LocalizedError {
    case localVaultUnavailable

    var errorDescription: String? {
        "本地档案尚未成功读取，暂时不能合并 iCloud 数据。"
    }
}
