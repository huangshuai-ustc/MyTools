import Foundation

#if MYTOOLS_FEATURE_STOCKS
typealias StockQuoteRefreshHolding = StockHolding
typealias StockQuoteRefreshValue = StockQuote
#else
typealias StockQuoteRefreshHolding = OpaqueModuleValue
struct StockQuoteRefreshValue: Sendable {}

struct DisabledStockQuoteService: StockQuoteRefreshing {
    func fetchQuotes(
        for stocks: [StockQuoteRefreshHolding]
    ) async -> [UUID: StockQuoteRefreshValue] {
        [:]
    }
}

@MainActor
struct DisabledStockRefreshInvalidator: StockRefreshInvalidating {
    func refreshEligibilityChanged() {}
}
#endif

protocol VaultInitialLoading: Sendable {
    func loadVaultWithMetrics() -> LocalVaultLoadResult
}

protocol VaultPersisting: Sendable {
    func schedule(_ vault: VaultData, secrets: [SecretVaultValue])
    func saveImmediately(_ vault: VaultData, secrets: [SecretVaultValue]) throws
    func flush() async -> String?
}

protocol StockQuoteRefreshing: Sendable {
    func fetchQuotes(
        for stocks: [StockQuoteRefreshHolding]
    ) async -> [UUID: StockQuoteRefreshValue]
}

protocol ExchangeRateProviding: Sendable {
    func fetchSnapshot() async throws -> ExchangeRateSnapshot
    func persist(snapshot: ExchangeRateSnapshot) async
}

@MainActor
protocol AlertNotificationRouting {
    func send(title: String, body: String, ruleID: UUID)
    func shouldSend(for ruleID: UUID, condition: Bool) -> Bool
    func clearState(for ruleID: UUID)
}

@MainActor
protocol StockRefreshInvalidating {
    func refreshEligibilityChanged()
}

protocol VaultBackupProcessing: Sendable {
    func makeBackup(
        vault: VaultData,
        secrets: [SecretVaultValue],
        includedModules: Set<ToolModule>,
        password: String
    ) async throws -> Data

    func restorePayload(
        from data: Data,
        password: String,
        enabledModules: Set<ToolModule>
    ) async throws -> VaultBackupPayload
}

protocol ModuleLocalDataCacheClearing: Sendable {
    func clearLocalCache(for module: ToolModule) async
}

struct DisabledModuleLocalDataCacheCleaner: ModuleLocalDataCacheClearing {
    func clearLocalCache(for module: ToolModule) async {}
}

struct AppStoreDependencies {
    let initialLoader: any VaultInitialLoading
    let persistence: any VaultPersisting
    let quoteService: any StockQuoteRefreshing
    let exchangeRateRepository: any ExchangeRateProviding
    let alertNotifications: any AlertNotificationRouting
    let stockRefreshInvalidator: any StockRefreshInvalidating
    let backupProcessor: any VaultBackupProcessing
    let attachmentStore: AttachmentStore
    let defaults: UserDefaults
    let localNotificationScheduler: any LocalNotificationScheduling
    let cloudSync: CloudSyncCoordinator?
    let moduleLocalDataCacheCleaner: any ModuleLocalDataCacheClearing

    @MainActor
    init(
        initialLoader: any VaultInitialLoading,
        persistence: any VaultPersisting,
        quoteService: any StockQuoteRefreshing,
        exchangeRateRepository: any ExchangeRateProviding,
        alertNotifications: any AlertNotificationRouting,
        stockRefreshInvalidator: any StockRefreshInvalidating,
        backupProcessor: any VaultBackupProcessing,
        attachmentStore: AttachmentStore,
        defaults: UserDefaults,
        localNotificationScheduler: any LocalNotificationScheduling = DisabledLocalNotificationScheduler(),
        cloudSync: CloudSyncCoordinator? = nil,
        moduleLocalDataCacheCleaner: any ModuleLocalDataCacheClearing = DisabledModuleLocalDataCacheCleaner()
    ) {
        self.initialLoader = initialLoader
        self.persistence = persistence
        self.quoteService = quoteService
        self.exchangeRateRepository = exchangeRateRepository
        self.alertNotifications = alertNotifications
        self.stockRefreshInvalidator = stockRefreshInvalidator
        self.backupProcessor = backupProcessor
        self.attachmentStore = attachmentStore
        self.defaults = defaults
        self.localNotificationScheduler = localNotificationScheduler
        self.cloudSync = cloudSync
        self.moduleLocalDataCacheCleaner = moduleLocalDataCacheCleaner
    }
}
