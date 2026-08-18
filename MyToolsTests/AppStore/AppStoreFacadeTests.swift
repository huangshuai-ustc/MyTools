import Foundation
import Testing
@testable import MyTools

@MainActor
struct AppStoreFacadeTests {
    @Test func startupLoaderFailurePublishesDataButBlocksPersistence() async {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var loadedStock = StockHolding()
        loadedStock.symbol = "LOADED"
        let loadResult = LocalVaultLoadResult(
            vault: VaultData(stocks: [loadedStock]),
            secrets: [],
            byteCount: 128,
            source: "Test failure",
            canPersist: false,
            readMilliseconds: 1,
            decodeMilliseconds: 1,
            totalMilliseconds: 2
        )
        let store = AppStore(
            dependencies: Self.dependencies(
                defaults: defaults,
                persistence: persistence,
                initialLoader: StaticVaultInitialLoader(result: loadResult)
            )
        )

        while !store.isInitialDataLoaded {
            await Task.yield()
        }

        #expect(store.stockStore.stocks.map(\.symbol) == ["LOADED"])
        #expect(store.isVaultLoadFailurePresented)

        loadedStock.name = "Must not persist"
        store.stockStore.upsertStock(loadedStock)

        #expect(persistence.scheduleCount == 0)
    }

    @Test func enablingHealthModuleRunsSynchronizationSkippedAtLaunch() {
        let defaults = Self.makeDefaults()
        let settings = ToolModuleSettings(defaults: defaults)
        settings.setVisible(false, for: .healthRecords)
        let persistence = RecordingVaultPersistence()
        let dependencies = Self.dependencies(defaults: defaults, persistence: persistence)

        var parent = MedicalRecord()
        parent.visitType = .inpatient
        parent.date = Self.date(day: 1)
        parent.inpatientEndDate = Self.date(day: 2)
        parent.hospital = "测试医院"
        let store = AppStore(
            initialVault: VaultData(medicalRecords: [parent]),
            moduleSettings: settings,
            dependencies: dependencies
        )
        settings.setVisibilityChangeHandler { [weak store] module, isVisible in
            store?.moduleVisibilityChanged(module, isVisible: isVisible)
        }

        #expect(store.healthStore.medicalRecords.count == 1)
        #expect(store.healthStore.hospitalProfiles.isEmpty)
        #expect(persistence.scheduleCount == 0)

        settings.setVisible(true, for: .healthRecords)

        #expect(store.healthStore.medicalRecords.filter { $0.isInpatientDailyRecord }.count == 2)
        #expect(store.healthStore.hospitalProfiles.map { $0.name } == ["测试医院"])
        #expect(persistence.scheduleCount == 1)
    }

    @Test func redundantDataCleanupSkipsDisabledModulesAndPersistsOnce() {
        let defaults = Self.makeDefaults()
        let settings = ToolModuleSettings(defaults: defaults)
        settings.setVisible(false, for: .documents)
        let persistence = RecordingVaultPersistence()
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let document = CredentialDocument(
            type: .propertyOwnershipCertificate,
            legacyDateOfBirth: staleDate
        )
        let store = AppStore(
            initialVault: VaultData(credentialDocuments: [document]),
            moduleSettings: settings,
            dependencies: Self.dependencies(defaults: defaults, persistence: persistence)
        )

        #expect(store.scanRedundantData().isEmpty)
        #expect(store.cleanupRedundantData().isEmpty)
        #expect(store.documentsStore.documents.first?.legacyDateOfBirth == staleDate)
        #expect(persistence.scheduleCount == 0)

        settings.setVisible(true, for: .documents)
        let report = store.scanRedundantData()
        let cleanupReport = store.cleanupRedundantData()

        #expect(report.findings.map(\.ruleID) == ["legacy-date-of-birth"])
        #expect(cleanupReport == report)
        #expect(store.documentsStore.documents.first?.legacyDateOfBirth == nil)
        #expect(
            store.documentsStore.documents.first?.fields.first { $0.label == "出生日期" }?.value
                == AppDateFormatter.string(from: staleDate)
        )
        #expect(persistence.scheduleCount == 1)
    }

    @Test func stockMutationUsesModuleStoreAndSchedulesPersistence() {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var stock = StockHolding()
        stock.symbol = "TEST"
        let store = AppStore(
            initialVault: VaultData(stocks: [stock]),
            dependencies: Self.dependencies(defaults: defaults, persistence: persistence)
        )

        stock.name = "Updated"
        store.stockStore.upsertStock(stock)

        #expect(store.stockStore.stocks == [stock])
        #expect(persistence.scheduleCount == 1)
    }

    @Test func stockTransactionMutationUsesModuleStore() {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var stock = StockHolding()
        stock.symbol = "TEST"
        let store = AppStore(
            initialVault: VaultData(stocks: [stock]),
            dependencies: Self.dependencies(defaults: defaults, persistence: persistence)
        )
        var transaction = StockTransaction()
        transaction.type = .buy
        transaction.quantity = 2
        transaction.unitPrice = 10

        let didSave = store.stockStore.upsertTransaction(transaction, in: stock.id)

        #expect(didSave)
        #expect(store.stockStore.stocks.first?.currentShares == 2)
        #expect(persistence.scheduleCount == 1)
    }

    @Test func moduleLocalDataDeletionCanBeUndoneWithoutTouchingOtherModules() async throws {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var stock = StockHolding()
        stock.symbol = "TEST"
        var bill = BillRecord()
        bill.merchant = "保留账单"
        let store = AppStore(
            initialVault: VaultData(stocks: [stock], billRecords: [bill]),
            dependencies: Self.dependencies(defaults: defaults, persistence: persistence)
        )

        let deletion = try #require(
            store.beginModuleLocalDataDeletion(for: .myStocks, undoWindow: 60)
        )
        #expect(store.stockStore.stocks.isEmpty)
        #expect(store.billsStore.records == [bill])
        let pendingCloudSnapshot = try await store.makeCloudSyncSnapshot()
        #expect(!pendingCloudSnapshot.participatingModules.contains(.myStocks))

        #expect(store.undoModuleLocalDataDeletion(id: deletion.id))
        #expect(store.stockStore.stocks == [stock])
        #expect(store.billsStore.records == [bill])
        #expect(store.pendingModuleLocalDataDeletion == nil)
    }

    @Test func hiddenModuleStillParticipatesInCloudSync() async throws {
        let defaults = Self.makeDefaults()
        let settings = ToolModuleSettings(defaults: defaults)
        settings.setVisible(false, for: .myStocks)
        var stock = StockHolding()
        stock.symbol = "SYNC"
        let store = AppStore(
            initialVault: VaultData(stocks: [stock]),
            moduleSettings: settings,
            dependencies: Self.dependencies(
                defaults: defaults,
                persistence: RecordingVaultPersistence()
            )
        )

        let snapshot = try await store.makeCloudSyncSnapshot()

        #expect(snapshot.participatingModules.contains(.myStocks))
        #expect(snapshot.items.contains { $0.kind == .stockHolding && $0.id == stock.id })
    }

    @Test func moduleLocalDataDeletionCommitsAfterUndoWindow() async throws {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var stock = StockHolding()
        stock.symbol = "TEST"
        let store = AppStore(
            initialVault: VaultData(stocks: [stock]),
            dependencies: Self.dependencies(defaults: defaults, persistence: persistence)
        )

        let deletion = try #require(
            store.beginModuleLocalDataDeletion(for: .myStocks, undoWindow: 60)
        )
        await store.commitModuleLocalDataDeletion(id: deletion.id)

        #expect(store.stockStore.stocks.isEmpty)
        #expect(store.pendingModuleLocalDataDeletion == nil)
        let committedCloudSnapshot = try await store.makeCloudSyncSnapshot()
        #expect(committedCloudSnapshot.participatingModules.contains(.myStocks))
    }

    @Test func quoteRefreshPublishesAndPersistsThroughStockStore() async {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var stock = StockHolding()
        stock.market = .unitedStates
        stock.symbol = "TEST"
        let quote = StockQuote(
            symbol: "TEST",
            name: "Test Company",
            latestPrice: 42,
            previousClose: 40,
            changePercent: 5,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            source: "Fixture"
        )
        let store = AppStore(
            initialVault: VaultData(stocks: [stock]),
            dependencies: Self.dependencies(
                defaults: defaults,
                persistence: persistence,
                quoteService: StaticStockQuoteProvider(quotes: [stock.id: quote])
            )
        )

        await store.stockStore.refreshQuotes(
            for: .unitedStates,
            forcedMarkets: [.unitedStates],
            allowClosedMissingData: false
        )

        #expect(store.stockStore.stocks.first?.latestPrice == 42)
        #expect(store.stockStore.stocks.first?.quoteName == "Test Company")
        #expect(store.stockStore.quoteSources[stock.id] == "Fixture")
        #expect(persistence.scheduleCount == 1)
    }

    private static func dependencies(
        defaults: UserDefaults,
        persistence: RecordingVaultPersistence,
        initialLoader: any VaultInitialLoading = EmptyVaultInitialLoader(),
        quoteService: any StockQuoteRefreshing = EmptyStockQuoteProvider(),
        moduleLocalDataCacheCleaner: any ModuleLocalDataCacheClearing = DisabledModuleLocalDataCacheCleaner()
    ) -> AppStoreDependencies {
        AppStoreDependencies(
            initialLoader: initialLoader,
            persistence: persistence,
            quoteService: quoteService,
            exchangeRateRepository: EmptyExchangeRateProvider(),
            alertNotifications: NoopAlertNotificationRouter(),
            stockRefreshInvalidator: NoopStockRefreshInvalidator(),
            backupProcessor: AppStoreBackupProcessor(),
            attachmentStore: AttachmentStore(),
            defaults: defaults,
            moduleLocalDataCacheCleaner: moduleLocalDataCacheCleaner
        )
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!
    }

    private static func date(day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: day,
            hour: 12
        ))!
    }
}

private struct EmptyVaultInitialLoader: VaultInitialLoading {
    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        LocalVaultLoadResult(
            vault: VaultData(),
            secrets: [],
            byteCount: 0,
            source: "Test",
            canPersist: true,
            readMilliseconds: 0,
            decodeMilliseconds: 0,
            totalMilliseconds: 0
        )
    }
}

private struct StaticVaultInitialLoader: VaultInitialLoading {
    let result: LocalVaultLoadResult

    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        result
    }
}

private final class RecordingVaultPersistence: VaultPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedScheduleCount = 0

    var scheduleCount: Int {
        lock.withLock { storedScheduleCount }
    }

    func schedule(_ vault: VaultData, secrets: [SecretItem]) {
        lock.withLock { storedScheduleCount += 1 }
    }

    func saveImmediately(_ vault: VaultData, secrets: [SecretItem]) throws {}

    func flush() async -> String? { nil }
}

private struct EmptyStockQuoteProvider: StockQuoteRefreshing {
    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote] { [:] }
}

private struct StaticStockQuoteProvider: StockQuoteRefreshing {
    let quotes: [UUID: StockQuote]

    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote] { quotes }
}

private actor EmptyExchangeRateProvider: ExchangeRateProviding {
    func fetchSnapshot() throws -> ExchangeRateSnapshot {
        ExchangeRateSnapshot(
            renminbiBuyingRates: [.cny: 1],
            renminbiSellingRates: [.cny: 1],
            updatedAt: nil
        )
    }

    func persist(snapshot: ExchangeRateSnapshot) {}
}

private struct NoopAlertNotificationRouter: AlertNotificationRouting {
    func send(title: String, body: String, ruleID: UUID) {}
    func shouldSend(for ruleID: UUID, condition: Bool) -> Bool { false }
    func clearState(for ruleID: UUID) {}
}

private struct NoopStockRefreshInvalidator: StockRefreshInvalidating {
    func refreshEligibilityChanged() {}
}
