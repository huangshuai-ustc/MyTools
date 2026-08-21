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

private struct LiveModuleLocalDataCacheCleaner: ModuleLocalDataCacheClearing {
    func clearLocalCache(for module: ToolModule) async {
        switch module {
        case .myStocks:
#if MYTOOLS_FEATURE_STOCKS
            await StockChartService.shared.clearCache()
#endif
            ExchangeRateRepository.clearCachedSnapshot()
            break
        case .sportsLottery:
#if MYTOOLS_FEATURE_SPORTS_LOTTERY
            await SportsLotteryService.shared.clearCache()
#endif
            break
        case .currencyExchange:
            ExchangeRateRepository.clearCachedSnapshot()
            break
        case .personalFinance, .healthRecords, .foodMap,
             .secrets, .documents, .bills:
            break
        }
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
                && CloudKitAvailability.isSupported(
                    containerIdentifier: AppMetadata.iCloudContainerIdentifier
                )
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
            cloudSync: cloudSync,
            moduleLocalDataCacheCleaner: LiveModuleLocalDataCacheCleaner()
        )
    }
}
