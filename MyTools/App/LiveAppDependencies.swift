import Foundation

private struct SecureStoreInitialLoader: VaultInitialLoading {
    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        SecureStore().loadVaultWithMetrics()
    }
}

extension VaultPersistenceCoordinator: VaultPersisting {}
extension StockQuoteService: StockQuoteRefreshing {}
extension AppNotificationService: AlertNotificationRouting {}
extension StockRefreshCoordinator: StockRefreshInvalidating {}

extension ExchangeRateRepository: ExchangeRateProviding {
    func persist(snapshot: ExchangeRateSnapshot) async {
        save(snapshot)
    }
}

extension AppStoreDependencies {
    @MainActor
    static var live: Self {
        Self(
            initialLoader: SecureStoreInitialLoader(),
            persistence: VaultPersistenceCoordinator(),
            quoteService: StockQuoteService(),
            exchangeRateRepository: ExchangeRateRepository(),
            alertNotifications: AppNotificationService.shared,
            stockRefreshInvalidator: StockRefreshCoordinator.shared,
            backupProcessor: AppStoreBackupProcessor(),
            attachmentStore: AttachmentStore(),
            defaults: .standard
        )
    }
}
