import Foundation

protocol VaultInitialLoading: Sendable {
    func loadVaultWithMetrics() -> LocalVaultLoadResult
}

protocol VaultPersisting: Sendable {
    func schedule(_ vault: VaultData, secrets: [SecretItem])
    func saveImmediately(_ vault: VaultData, secrets: [SecretItem]) throws
    func flush() async -> String?
}

protocol StockQuoteRefreshing: Sendable {
    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote]
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
        secrets: [SecretItem],
        includedModules: Set<ToolModule>,
        password: String
    ) async throws -> Data

    func restorePayload(from data: Data, password: String) async throws -> VaultBackupPayload
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
    let cloudSync: CloudSyncCoordinator?

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
        cloudSync: CloudSyncCoordinator? = nil
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
        self.cloudSync = cloudSync
    }
}
