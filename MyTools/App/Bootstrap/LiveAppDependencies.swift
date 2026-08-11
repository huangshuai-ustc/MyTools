import Foundation

private struct SecureStoreInitialLoader: VaultInitialLoading {
    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        SecureStore().loadVaultWithMetrics()
    }
}

extension VaultPersistenceCoordinator: VaultPersisting {}
#if MYTOOLS_FEATURE_STOCKS
extension StockQuoteService: StockQuoteRefreshing {}
#endif
extension AppNotificationService: AlertNotificationRouting {}
#if MYTOOLS_FEATURE_STOCKS
extension StockRefreshCoordinator: StockRefreshInvalidating {}
#endif

extension ExchangeRateRepository: ExchangeRateProviding {
    func persist(snapshot: ExchangeRateSnapshot) async {
        save(snapshot)
    }
}

extension AppStoreDependencies {
    @MainActor
    static var live: Self {
        let attachmentStore = AttachmentStore()
#if MYTOOLS_FEATURE_STOCKS
        let quoteService: any StockQuoteRefreshing = StockQuoteService()
        let stockRefreshInvalidator: any StockRefreshInvalidating = StockRefreshCoordinator.shared
#else
        let quoteService: any StockQuoteRefreshing = DisabledStockQuoteService()
        let stockRefreshInvalidator: any StockRefreshInvalidating = DisabledStockRefreshInvalidator()
#endif
        let cloudSync = CloudSyncCoordinator(
            defaults: .standard,
            attachmentStore: attachmentStore,
            containerIdentifier: AppMetadata.iCloudContainerIdentifier,
            isSupported: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        )
        return Self(
            initialLoader: SecureStoreInitialLoader(),
            persistence: VaultPersistenceCoordinator(),
            quoteService: quoteService,
            exchangeRateRepository: ExchangeRateRepository(),
            alertNotifications: AppNotificationService.shared,
            stockRefreshInvalidator: stockRefreshInvalidator,
            backupProcessor: AppStoreBackupProcessor(),
            attachmentStore: attachmentStore,
            defaults: .standard,
            localNotificationScheduler: AppNotificationService.shared,
            cloudSync: cloudSync
        )
    }
}
