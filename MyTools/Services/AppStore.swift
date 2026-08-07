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
    let stockStore: StockStore
    let exchangeRateStore: ExchangeRateStore
    let healthStore: HealthStore
    let financeStore: FinanceStore
    let secretStore: SecretStore
    let currencyExchangeStore: CurrencyExchangeStore
    private let persistence: any VaultPersisting
    private let backupProcessor: any VaultBackupProcessing
    private weak var moduleSettings: ToolModuleSettings?
    private var isRestoringBackup = false
    private var canPersistVault = true
    private var didLogPersistenceBlocked = false

    init(
        initialVault: VaultData? = nil,
        secretItems: [SecretItem] = [],
        moduleSettings: ToolModuleSettings? = nil,
        dependencies: AppStoreDependencies
    ) {
        self.moduleSettings = moduleSettings
        persistence = dependencies.persistence
        backupProcessor = dependencies.backupProcessor
        let attachmentStore = dependencies.attachmentStore
        let exchangeRateStore = ExchangeRateStore(
            repository: dependencies.exchangeRateRepository,
            moduleSettings: moduleSettings
        )
        self.exchangeRateStore = exchangeRateStore
        currencyExchangeStore = CurrencyExchangeStore(
            records: initialVault?.currencyExchangeRecords ?? [],
            rateAlerts: initialVault?.currencyRateAlerts ?? [],
            alertNotifications: dependencies.alertNotifications,
            moduleSettings: moduleSettings,
            exchangeRateStore: exchangeRateStore
        )
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
        healthStore = HealthStore(
            medicalRecords: initialVault?.medicalRecords ?? [],
            hospitalProfiles: initialVault?.hospitalProfiles ?? [],
            attachmentStore: attachmentStore,
            moduleSettings: moduleSettings
        )
        financeStore = FinanceStore(
            accounts: initialVault?.accounts ?? [],
            cards: initialVault?.cards ?? [],
            attachmentStore: attachmentStore
        )
        secretStore = SecretStore(
            secretItems: secretItems,
            attachmentStore: attachmentStore
        )
        stockStore.attach(mutationNotifier: self)
        healthStore.attach(mutationNotifier: self)
        financeStore.attach(mutationNotifier: self)
        secretStore.attach(mutationNotifier: self)
        currencyExchangeStore.attach(mutationNotifier: self)
        exchangeRateStore.attach(updateObserver: currencyExchangeStore)

        if initialVault != nil {
            isInitialDataLoaded = true
            healthStore.synchronizeLoadedRecords()
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
        switch module {
        case .myStocks:
            stockStore.moduleVisibilityChanged()
            exchangeRateStore.moduleVisibilityChanged()
        case .currencyExchange:
            exchangeRateStore.moduleVisibilityChanged()
            currencyExchangeStore.moduleVisibilityChanged(isVisible: isVisible)
        case .healthRecords:
            if isInitialDataLoaded {
                healthStore.moduleVisibilityChanged(isVisible: isVisible)
            }
        case .personalFinance, .secrets:
            break
        }
    }

    private func isModuleVisible(_ module: ToolModule) -> Bool {
        moduleSettings?.isVisible(module) ?? true
    }

    private func applyInitialSnapshot(_ snapshot: LocalVaultLoadResult) {
        applyVault(snapshot.vault)
        secretStore.replace(secretItems: snapshot.secrets)
        canPersistVault = snapshot.canPersist
        healthStore.synchronizeLoadedRecords()
        isVaultLoadFailurePresented = !snapshot.canPersist
        didLogPersistenceBlocked = false
        isInitialDataLoaded = true
        let loadSummary = "Local vault loaded from \(snapshot.source): \(snapshot.byteCount) bytes; read \(snapshot.readMilliseconds) ms, decode \(snapshot.decodeMilliseconds) ms, total \(snapshot.totalMilliseconds) ms"
        startupLogger.info("\(loadSummary, privacy: .public)")
        DiagnosticLogger.shared.log(.startup, loadSummary)
    }

    private func applyExchangeRateSnapshot(_ snapshot: ExchangeRateSnapshot) {
        exchangeRateStore.applyCachedSnapshot(snapshot)
    }

    private func applyVault(_ vault: VaultData) {
        financeStore.replace(accounts: vault.accounts, cards: vault.cards)
        stockStore.replace(
            stocks: vault.stocks,
            priceAlerts: vault.stockPriceAlerts,
            isDataLoaded: true
        )
        currencyExchangeStore.replace(
            records: vault.currencyExchangeRecords,
            rateAlerts: vault.currencyRateAlerts
        )
        healthStore.replace(
            medicalRecords: vault.medicalRecords,
            hospitalProfiles: vault.hospitalProfiles
        )
    }

    func makeBackupDocument(password: String) async throws -> VaultBackupDocument {
        let includedModules = Set(
            ToolModule.allCases.filter { isModuleVisible($0) }
        )
        let data: Data
        do {
            data = try await backupProcessor.makeBackup(
                vault: currentVaultData(),
                secrets: secretStore.secretItems,
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
        secretStore.setBackupRestoreInProgress(true)
        defer {
            secretStore.setBackupRestoreInProgress(false)
            isRestoringBackup = false
        }
        let restoredPayload: VaultBackupPayload
        do {
            restoredPayload = try await backupProcessor.restorePayload(
                from: data,
                password: password
            )
        } catch {
            DiagnosticLogger.logError(.backup, operation: "导入加密备份失败", error: error)
            throw error
        }
        let mergedPayload = AppStoreBackupMerger.merge(
            localVault: currentVaultData(),
            localSecrets: secretStore.secretItems,
            imported: restoredPayload
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
        secretStore.replace(secretItems: mergedPayload.secrets)
        canPersistVault = true
        didLogPersistenceBlocked = false
        persistenceError = nil
        if restoredPayload.includedModules.contains(.myStocks) {
            stockStore.clearNotificationState(
                for: Set(restoredPayload.vault.stockPriceAlerts.map(\.id))
            )
        }
        if restoredPayload.includedModules.contains(.currencyExchange) {
            currencyExchangeStore.clearNotificationState(
                for: Set(restoredPayload.vault.currencyRateAlerts.map(\.id))
            )
        }
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
        persistence.schedule(currentVaultData(), secrets: secretStore.secretItems)
    }

    private func currentVaultData() -> VaultData {
        VaultData(
            accounts: financeStore.accounts,
            cards: financeStore.cards,
            stocks: stockStore.stocks,
            currencyExchangeRecords: currencyExchangeStore.records,
            medicalRecords: healthStore.medicalRecords,
            hospitalProfiles: healthStore.hospitalProfiles,
            currencyRateAlerts: currencyExchangeStore.rateAlerts,
            stockPriceAlerts: stockStore.priceAlerts
        )
    }

}
