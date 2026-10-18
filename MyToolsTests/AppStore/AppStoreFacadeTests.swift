import Foundation
import Testing
@testable import MyTools

struct DiagnosticMaintenanceTests {
    @Test func repeatedLogRotationBoundsFileSizeAndKeepsNewestCompleteLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticStress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("system.log")
        let maximum = 4 * 1024 * 1024
        let retained = 3 * 1024 * 1024
        let chunk = Data(String(repeating: "历史日志测试 abcdefghijklmnopqrstuvwxyz\n", count: 100_000).utf8)
        try chunk.write(to: url)
        for index in 0..<12 {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
            try handle.write(contentsOf: Data("最新记录-\(index)\n".utf8))
            try handle.close()
            try DiagnosticMaintenance.trimLog(at: url, maximumBytes: maximum, retainedBytes: retained)
            let data = try Data(contentsOf: url)
            #expect(data.count <= maximum)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.hasSuffix("最新记录-\(index)\n"))
            #expect(text.hasPrefix("历史日志测试"))
        }
    }

    @Test @MainActor func clearingKeepsMainActorResponsiveAndAttemptsOtherArtifactsAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticClear-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("temporary.log")
        try Data(repeating: 0x61, count: 32 * 1024 * 1024).write(to: url)
        let release = DispatchSemaphore(value: 0)
        let work = Task {
            await DiagnosticMaintenance.clear([
                {
                    #expect(!Thread.isMainThread)
                    #expect(release.wait(timeout: .now() + 2) == .success)
                    try FileManager.default.removeItem(at: url)
                },
                { throw CocoaError(.fileReadNoPermission) }
            ])
        }
        try await Task.sleep(for: .milliseconds(30))
        release.signal()
        let errors = await work.value
        #expect(errors.count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
struct AppStoreFacadeTests {
    @Test func unavailableFinanceDoesNotParticipateInSyncDeletionOrNormalBackup() async throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.isolateVaultModules] = true
        let vault = try decoder.decode(VaultData.self, from: Data(#"{"accounts":"future-finance","billTags":["retained"]}"#.utf8))
        let store = AppStore(initialVault: vault, dependencies: Self.dependencies(defaults: Self.makeDefaults(), persistence: RecordingVaultPersistence()))
        #expect(store.unavailableModules == [.personalFinance])
        #expect(store.beginModuleLocalDataDeletion(for: .personalFinance) == nil)
        let snapshot = try await store.makeCloudSyncSnapshot()
        #expect(!snapshot.participatingModules.contains(.personalFinance))
        #expect(snapshot.participatingModules.contains(.myStocks))
        do {
            _ = try await store.makeBackupDocument(password: "test-password")
            Issue.record("An unavailable visible module must not be exported as a normal empty backup")
        } catch {}
    }
    @Test func financeAttachmentCleanupRequiresSuccessfulPersistenceAndNoGlobalReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceRemoval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = AttachmentStore(directoryURL: root)
        let pdf = try attachments.save(data: Data("%PDF-test".utf8), originalFileName: "test.pdf", contentType: .pdf)
        var account = FinancialInstitution()
        account.bankName = "Test"
        var card = BankCard()
        card.accountID = account.id
        var statement = CreditCardStatement()
        statement.attachment = pdf
        card.statements = [statement]
        let persistence = RecordingVaultPersistence()
        persistence.flushError = "simulated-failure"
        let store = AppStore(initialVault: VaultData(accounts: [account], cards: [card]), dependencies:
            Self.dependencies(defaults: Self.makeDefaults(), persistence: persistence, attachmentStore: attachments))
        store.financeStore.deleteAccount(id: account.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(FileManager.default.fileExists(atPath: attachments.url(for: pdf).path))
        persistence.flushError = nil
        try store.financeStore.saveInstitution(account, cards: [card], expected: nil, expectedCards: [])
        store.scheduleAttachmentRemovalAfterPersistence([pdf])
        try await Task.sleep(for: .milliseconds(50))
        #expect(FileManager.default.fileExists(atPath: attachments.url(for: pdf).path))
        store.financeStore.deleteAccount(id: account.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: attachments.url(for: pdf).path))
    }
    @Test(arguments: [true, false])
    func homeManualRefreshUpdatesIntradayAndFiveDaysAcrossMarkets(isOpen: Bool) async {
        let charts = RecordingStockCharts()
        let quotes = CountingClosedQuoteProvider()
        var archived = StockHolding(market: .hongKong, symbol: "00005")
        archived.archivedAt = Date()
        let stocks = [StockHolding(market: .aShare, symbol: "600000"),
                      StockHolding(market: .hongKong, symbol: "03033"),
                      StockHolding(market: .unitedStates, symbol: "AAPL")]
        let store = StockStore(stocks: stocks + [archived], isDataLoaded: true, quoteService: quotes,
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: charts, defaults: Self.makeDefaults())
        let coordinator = StockRefreshCoordinator(chartService: charts)
        coordinator.attach(store: store)
        let now = StockChartFixtures.date(2026, 9, isOpen ? 24 : 26, hour: 11)
        await coordinator.refreshManually(refreshMarketCharts: true, refreshFiveDayCharts: true, at: now)
        let requests = await charts.requests
        for stock in stocks {
            #expect(requests.filter { $0.stockID == stock.id && $0.range == .intraday && $0.forceRefresh }.count == 1)
            #expect(requests.filter { $0.stockID == stock.id && $0.range == .fiveDays && $0.forceRefresh }.count == 1)
            #expect(store.chartCacheRevisionByStockID[stock.id, default: 0] >= 2)
        }
        #expect(!requests.contains { $0.stockID == archived.id })
    }

    @Test func homeManualRefreshKeepsIntradayWhenFiveDaysFailsAndRespectsMarket() async {
        let charts = RecordingStockCharts(failingRanges: [.fiveDays])
        let quotes = CountingClosedQuoteProvider()
        let hk = StockHolding(market: .hongKong, symbol: "03033")
        let us = StockHolding(market: .unitedStates, symbol: "AAPL")
        let store = StockStore(stocks: [hk, us], isDataLoaded: true, quoteService: quotes,
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: charts, defaults: Self.makeDefaults())
        let coordinator = StockRefreshCoordinator(chartService: charts)
        coordinator.attach(store: store)
        await coordinator.refreshManually(for: .hongKong, refreshMarketCharts: true, refreshFiveDayCharts: true,
            at: StockChartFixtures.date(2026, 9, 26))
        let requests = await charts.requests
        #expect(requests.map(\.range) == [.intraday, .fiveDays])
        #expect(requests.allSatisfy { $0.stockID == hk.id })
        #expect(store.chartCacheRevisionByStockID[hk.id, default: 0] > 0)
        // 五日失败只记在五日上，不能盖掉分时的成功。
        #expect(store.fiveDayRefreshErrors[hk.id] != nil)
        #expect(store.chartRefreshErrors[hk.id] == nil)
    }

    /// 持仓页下拉只刷新持仓中的股票，持股为零的看盘股不发请求；各市场合并成一批并行。
    @Test func pageScopedManualRefreshSkipsStocksOffThePage() async {
        let charts = RecordingStockCharts()
        let quotes = CountingClosedQuoteProvider()
        let held = [StockHolding(market: .aShare, symbol: "600000"),
                    StockHolding(market: .unitedStates, symbol: "AAPL")]
        let watchOnly = StockHolding(market: .hongKong, symbol: "00700")
        let store = StockStore(stocks: held + [watchOnly], isDataLoaded: true, quoteService: quotes,
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: charts, defaults: Self.makeDefaults())
        let coordinator = StockRefreshCoordinator(chartService: charts)
        coordinator.attach(store: store)
        await coordinator.refreshManually(stockIDs: Set(held.map(\.id)), refreshMarketCharts: true,
            refreshFiveDayCharts: true, at: StockChartFixtures.date(2026, 9, 26, hour: 11))
        let requests = await charts.requests
        #expect(!requests.contains { $0.stockID == watchOnly.id })
        #expect(Set(requests.filter { $0.range == .intraday }.map(\.stockID)) == Set(held.map(\.id)))
        #expect(await charts.peakConcurrentRequests >= 2)
        #expect(await quotes.count == 1)
    }

    @Test(arguments: [true, false])
    func staleExtendedHoursCacheReadDoesNotOverrideLiveMinuteResult(refreshPrices: Bool) async {
        let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
        let today = calendar.startOfDay(for: Date())
        let preDate = today.addingTimeInterval(5 * 3600)
        let regularDate = today.addingTimeInterval(9 * 3600 + 30 * 60)
        func snapshot(_ price: Double) -> StockChartSnapshot {
            StockChartSnapshot(symbol: "AAPL", name: "Fixture", currencyCode: "USD", previousClose: 100,
                points: [StockChartFixtures.point(at: regularDate, close: price),
                         StockChartFixtures.point(at: regularDate.addingTimeInterval(60), close: price)],
                preMarketPoints: [StockChartFixtures.point(at: preDate, close: price),
                                 StockChartFixtures.point(at: preDate.addingTimeInterval(60), close: price)],
                postMarketPoints: [StockChartFixtures.point(at: today.addingTimeInterval(16 * 3600), close: price),
                                  StockChartFixtures.point(at: today.addingTimeInterval(16 * 3600 + 60), close: price)],
                indicatorPoints: nil, quoteUpdatedAt: preDate, fetchedAt: Date(), source: "Fixture", supportsCandlesticks: true)
        }
        let charts = RecordingStockCharts(cachedSnapshot: snapshot(101), fetchedSnapshot: snapshot(110), suspendFirstCacheRead: true)
        let stock = StockHolding(market: .unitedStates, symbol: "AAPL")
        let store = StockStore(stocks: [stock], isDataLoaded: true, quoteService: CountingClosedQuoteProvider(),
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: charts, defaults: Self.makeDefaults())
        let oldRead = Task {
            if refreshPrices { await store.refreshExtendedHoursPerformance() }
            else { await store.refreshSparklines() }
        }
        await charts.waitUntilCacheReadStarted()
        await store.refreshIntradayCharts(stockID: stock.id, forceRefresh: true)
        #expect(store.extendedHoursPerformance[stock.id]?.preMarketPrice == 110)
        let liveSparkline = store.intradaySparklines[stock.id]
        let livePerformance = store.extendedHoursPerformance[stock.id]
        await charts.finishSuspendedCacheRead()
        await oldRead.value
        #expect(store.extendedHoursPerformance[stock.id]?.preMarketPrice == 110)
        #expect(store.intradaySparklines[stock.id] == liveSparkline)
        #expect(store.extendedHoursPerformance[stock.id] == livePerformance)
    }

    /// 休市数据已完整（含五日）时，反复下拉不再发任何请求。
    @Test(arguments: [false, true])
    func completeClosedMarketRefreshUsesCacheWithoutNetwork(includesFiveDays: Bool) async {
        let close = StockChartFixtures.date(2026, 9, 24, hour: 16)
        var stock = StockHolding(market: .hongKong, symbol: "03033")
        stock.latestPrice = 5
        stock.previousClose = 4
        stock.lastQuoteAt = close
        let snapshot = StockChartSnapshot(symbol: stock.symbol, name: "Test", currencyCode: "HKD",
            previousClose: 4, points: [StockChartFixtures.point(at: close, close: 5)], indicatorPoints: nil,
            quoteUpdatedAt: close, fetchedAt: close, source: "Fixture", supportsCandlesticks: true)
        let charts = RecordingStockCharts(cachedSnapshot: snapshot)
        let quotes = CountingClosedQuoteProvider()
        let store = StockStore(stocks: [stock], isDataLoaded: true, quoteService: quotes,
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: charts, defaults: Self.makeDefaults())
        let coordinator = StockRefreshCoordinator(chartService: charts)
        coordinator.attach(store: store)
        for _ in 0..<3 {
            await coordinator.refreshManually(for: .hongKong, prioritizedStockID: stock.id,
                refreshFiveDayCharts: includesFiveDays, at: close.addingTimeInterval(120))
        }
        #expect(await charts.fetchCount == 0)
        #expect(await quotes.count == 0)
    }

    /// AUDIT-053：执行者被取消时，排队的手动刷新要交给等待者执行，而不是被当作已完成。
    @Test func cancelledQuoteDrainHandsQueuedRequestToWaiter() async {
        let stock = StockHolding(market: .hongKong, symbol: "03033")
        let quotes = GatedQuoteProvider()
        let store = StockStore(stocks: [stock], isDataLoaded: true, quoteService: quotes,
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: RecordingStockCharts(), defaults: Self.makeDefaults())
        let first = Task { await store.refreshQuotes(forceRefresh: true) }
        await quotes.waitUntilStarted()
        let second = Task { await store.refreshQuotes(stockID: stock.id, forceRefresh: true) }
        for _ in 0..<10 { await Task.yield() }
        first.cancel()
        await quotes.release()
        await first.value
        await second.value
        #expect(await quotes.count == 2)
        #expect(!store.isRefreshingQuotes)
    }

    @Test func queuedSingleStockRefreshIsNotWidenedByOtherMarket() async {
        let hk = StockHolding(market: .hongKong, symbol: "03033")
        let us = StockHolding(market: .unitedStates, symbol: "VOO")
        let quotes = GatedQuoteProvider()
        let store = StockStore(stocks: [hk, us], isDataLoaded: true, quoteService: quotes,
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: RecordingStockCharts(), defaults: Self.makeDefaults())
        let first = Task { await store.refreshQuotes(stockID: hk.id, forceRefresh: true) }
        await quotes.waitUntilStarted()
        let second = Task { await store.refreshQuotes(stockID: hk.id, forceRefresh: true) }
        let third = Task { await store.refreshQuotes(stockID: us.id, forceRefresh: true) }
        for _ in 0..<10 { await Task.yield() }
        await quotes.release()
        await first.value; await second.value; await third.value
        // AUDIT-052：两个排队请求各自只请求自己的股票，不合并成全部股票。
        #expect(await quotes.requestedSizes == [1, 1, 1])
    }

    @Test func lunchAndWeekendCoverageUseActualCompletedSession() {
        var stock = StockHolding(market: .hongKong, symbol: "03033")
        let morning = StockChartFixtures.date(2026, 9, 24, hour: 12)
        stock.latestPrice = 5; stock.previousClose = 4; stock.lastQuoteAt = morning
        #expect(!StockRefreshCoordinator.needsClosedQuoteRefresh(stock: stock, at: morning.addingTimeInterval(60)))
        #expect(StockRefreshCoordinator.needsClosedQuoteRefresh(stock: stock, at: StockChartFixtures.date(2026, 9, 24, hour: 17)))
        let friday = StockChartFixtures.date(2026, 9, 25, hour: 16)
        stock.lastQuoteAt = friday
        #expect(!StockRefreshCoordinator.needsClosedQuoteRefresh(stock: stock, at: StockChartFixtures.date(2026, 9, 27)))
        let incomplete = StockChartSnapshot(symbol: stock.symbol, name: "Test", currencyCode: "HKD",
            previousClose: 4, points: [StockChartFixtures.point(at: friday.addingTimeInterval(-60), close: 5)],
            indicatorPoints: nil, quoteUpdatedAt: friday, fetchedAt: friday, source: "Fixture", supportsCandlesticks: true)
        #expect(StockRefreshCoordinator.needsClosedChartRefresh(stock: stock, snapshot: incomplete, at: friday.addingTimeInterval(120)))
    }
    @Test func closedMarketManualRefreshRepairsSelectedChartAndQuote() async {
        let stock = StockHolding(market: .hongKong, symbol: "03033")
        let other = StockHolding(market: .hongKong, symbol: "00700")
        let charts = RecordingStockCharts()
        let closed = StockChartFixtures.date(2026, 9, 24, hour: 17)
        let quote = StockQuote(symbol: stock.symbol, name: "Test", latestPrice: 5,
                               previousClose: 4, changePercent: 25, updatedAt: closed, source: "Fixture")
        let store = StockStore(stocks: [stock, other], isDataLoaded: true,
            quoteService: StaticStockQuoteProvider(quotes: [stock.id: quote]),
            alertNotifications: NoopAlertNotificationRouter(), refreshInvalidator: NoopStockRefreshInvalidator(),
            chartService: charts, defaults: Self.makeDefaults())
        let coordinator = StockRefreshCoordinator(chartService: charts)
        coordinator.attach(store: store)
        await coordinator.refreshManually(for: .hongKong, prioritizedStockID: stock.id, at: closed)
        #expect(await charts.fetchCount == 1)
        #expect(store.stocks.first?.latestPrice == 5)
        #expect(store.chartCacheRevisionByStockID[stock.id] != nil)
        #expect(store.chartCacheRevisionByStockID[other.id] == nil)
    }
    @Test func stockRefreshWaitsForQueuedMinuteWorkAndThrottlesReentry() async {
        let stock = StockHolding(market: .unitedStates, symbol: "TEST")
        let charts = RecordingStockCharts()
        let store = StockStore(stocks: [stock], isDataLoaded: true,
                               quoteService: StaticStockQuoteProvider(quotes: [:]),
                               alertNotifications: NoopAlertNotificationRouter(),
                               refreshInvalidator: NoopStockRefreshInvalidator(),
                               chartService: charts, defaults: Self.makeDefaults())
        async let first: Void = store.refreshIntradayCharts(stockID: stock.id, forceRefresh: false)
        async let second: Void = store.refreshIntradayCharts(stockID: stock.id, forceRefresh: false)
        await first
        await second
        #expect(await charts.fetchCount == 1)
        #expect(!store.isRefreshingCharts)
        #expect(store.chartCacheRevisionByStockID[stock.id] != nil)
        await store.refreshIntradayCharts(stockID: stock.id, forceRefresh: false)
        #expect(await charts.fetchCount == 1)
        await store.refreshIntradayCharts(stockID: stock.id, forceRefresh: true)
        #expect(await charts.fetchCount == 2)
    }

    @Test func failedAutomaticMinuteRefreshKeepsCooldownButAllowsManualRetry() async {
        let stock = StockHolding(market: .unitedStates, symbol: "TEST")
        let charts = RecordingStockCharts(fails: true)
        let store = StockStore(stocks: [stock], isDataLoaded: true,
            quoteService: StaticStockQuoteProvider(quotes: [:]),
            alertNotifications: NoopAlertNotificationRouter(),
            refreshInvalidator: NoopStockRefreshInvalidator(), chartService: charts, defaults: Self.makeDefaults())
        for _ in 0..<3 { await store.refreshIntradayCharts(stockID: stock.id, forceRefresh: false) }
        #expect(await charts.fetchCount == 1)
        #expect(store.chartRefreshErrors[stock.id] != nil)
        await store.refreshIntradayCharts(stockID: stock.id, forceRefresh: true)
        #expect(await charts.fetchCount == 2)
    }

    @Test func stockChartRequestsUseConcurrentWorkersAndRespectLoadedState() async {
        let stocks = (0..<5).map { StockHolding(market: .unitedStates, symbol: "TEST\($0)") }
        let charts = RecordingStockCharts()
        let store = StockStore(stocks: stocks, isDataLoaded: false,
                               quoteService: StaticStockQuoteProvider(quotes: [:]),
                               alertNotifications: NoopAlertNotificationRouter(),
                               refreshInvalidator: NoopStockRefreshInvalidator(),
                               chartService: charts, defaults: Self.makeDefaults())
        await store.refreshIntradayCharts()
        #expect(await charts.fetchCount == 0)
        store.replace(stocks: stocks, priceAlerts: [], returnAlerts: [], isDataLoaded: true)
        await store.refreshIntradayCharts(stockIDs: Set(stocks.prefix(3).map(\.id)), forceRefresh: false)
        #expect(await charts.fetchCount == 3)
        #expect(await charts.peakConcurrentRequests > 1)
        #expect(store.chartCacheRevisionByStockID.count == 3)
    }

    @Test func chartCompletionCannotRestoreDeletedStockProjection() async {
        let stock = StockHolding(market: .unitedStates, symbol: "TEST")
        let charts = RecordingStockCharts()
        let store = StockStore(stocks: [stock], isDataLoaded: true,
                               quoteService: StaticStockQuoteProvider(quotes: [:]),
                               alertNotifications: NoopAlertNotificationRouter(),
                               refreshInvalidator: NoopStockRefreshInvalidator(),
                               chartService: charts, defaults: Self.makeDefaults())
        let work = Task { await store.refreshIntradayCharts() }
        await charts.waitUntilStarted()
        store.deleteStocks(ids: [stock.id])
        await work.value
        #expect(store.stocks.isEmpty)
        #expect(store.chartCacheRevisionByStockID[stock.id] == nil)
        #expect(store.intradaySparklines[stock.id] == nil)
    }

    @Test func chartObservationIgnoresUnrelatedStockUpdates() {
        let first = StockHolding(market: .unitedStates, symbol: "FIRST")
        var second = StockHolding(market: .unitedStates, symbol: "SECOND")
        let store = StockStore(stocks: [first, second], isDataLoaded: true,
                               quoteService: StaticStockQuoteProvider(quotes: [:]),
                               alertNotifications: NoopAlertNotificationRouter(),
                               refreshInvalidator: NoopStockRefreshInvalidator(), defaults: Self.makeDefaults())
        let observation = StockWatchObservation(store: store, stockID: first.id)
        var emissions = 0
        let subscription = observation.$stock.sink { _ in emissions += 1 }
        second.latestPrice = 123
        store.upsertStock(second)
        #expect(emissions == 1)
        observation.select(second.id)
        #expect(observation.stock?.latestPrice == 123)
        subscription.cancel()
    }

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

        do {
            _ = try await store.makeCloudSyncSnapshot()
            Issue.record("本地档案读取失败时不应生成云同步快照")
        } catch {
            // Expected: an empty in-memory fallback must never become a cloud
            // deletion snapshot while the original file is protected.
        }

        loadedStock.name = "Must not persist"
        store.stockStore.upsertStock(loadedStock)

        #expect(persistence.scheduleCount == 0)
    }

    @Test func backupRestoreIsRejectedWhileLocalVaultIsUnreadable() async throws {
        // AUDIT-003: merging into the empty fallback would overwrite the protected original.
        let persistence = RecordingVaultPersistence()
        let failed = LocalVaultLoadResult(
            vault: VaultData(), secrets: [], byteCount: 311_255,
            source: "存档读取失败（原文件已保留）", canPersist: false,
            readMilliseconds: 1, decodeMilliseconds: 0, totalMilliseconds: 2,
            failure: .unrecoverable
        )
        let store = AppStore(dependencies: Self.dependencies(
            defaults: Self.makeDefaults(),
            persistence: persistence,
            initialLoader: StaticVaultInitialLoader(result: failed)
        ))
        while !store.isInitialDataLoaded { await Task.yield() }

        await #expect(throws: VaultBackupError.localVaultUnavailable) {
            try await store.restoreBackup(from: Data("unused".utf8), password: "password")
        }
        #expect(persistence.saveImmediatelyCount == 0)
        #expect(persistence.scheduleCount == 0)
    }

    @Test func mutationsBeforeInitialLoadAreNotPersisted() async throws {
        // AUDIT-011: placeholder stores must not be written over the real vault.
        let persistence = RecordingVaultPersistence()
        let loader = GatedVaultInitialLoader(result: LocalVaultLoadResult(
            vault: VaultData(), secrets: [], byteCount: 0, source: "Test", canPersist: true,
            readMilliseconds: 0, decodeMilliseconds: 0, totalMilliseconds: 0
        ))
        let store = AppStore(dependencies: Self.dependencies(
            defaults: Self.makeDefaults(),
            persistence: persistence,
            initialLoader: loader
        ))
        var early = StockHolding()
        early.symbol = "EARLY"
        store.stockStore.upsertStock(early)
        #expect(!store.isInitialDataLoaded)
        #expect(persistence.scheduleCount == 0)

        loader.open()
        while !store.isInitialDataLoaded { await Task.yield() }
    }

    @Test func failedVaultLoadCanRetryAndRestoreOriginalData() async throws {
        let defaults = Self.makeDefaults()
        let failed = LocalVaultLoadResult(
            vault: VaultData(), secrets: [], byteCount: 311_255,
            source: "存档读取失败（原文件已保留）", canPersist: false,
            readMilliseconds: 1, decodeMilliseconds: 0, totalMilliseconds: 2,
            failure: .unrecoverable
        )
        var recoveredStock = StockHolding()
        recoveredStock.symbol = "RECOVERED"
        let recovered = LocalVaultLoadResult(
            vault: VaultData(stocks: [recoveredStock]), secrets: [], byteCount: 311_255,
            source: "Application Support（已加密）", canPersist: true,
            readMilliseconds: 1, decodeMilliseconds: 2, totalMilliseconds: 3
        )
        let loader = SequencedVaultInitialLoader(results: [failed, recovered])
        let store = AppStore(dependencies: Self.dependencies(
            defaults: defaults,
            persistence: RecordingVaultPersistence(),
            initialLoader: loader
        ))

        while !store.isInitialDataLoaded { await Task.yield() }
        #expect(store.isVaultLoadFailurePresented)

        store.retryVaultLoadAfterFailure()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while store.stockStore.stocks.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.stockStore.stocks.map(\.symbol) == ["RECOVERED"])
        #expect(!store.isVaultLoadFailurePresented)
        #expect(loader.loadCount >= 2)
    }

    @Test func protectedDataDelayRetriesWithoutPublishingAnEmptyVault() async throws {
        let defaults = Self.makeDefaults()
        var loadedStock = StockHolding()
        loadedStock.symbol = "RETRIED"
        let delayed = LocalVaultLoadResult(
            vault: VaultData(),
            secrets: [],
            byteCount: 256,
            source: "等待设备解锁后重试",
            canPersist: false,
            readMilliseconds: 1,
            decodeMilliseconds: 0,
            totalMilliseconds: 1,
            failure: .protectedDataUnavailable
        )
        let recovered = LocalVaultLoadResult(
            vault: VaultData(stocks: [loadedStock]),
            secrets: [],
            byteCount: 256,
            source: "Test recovered",
            canPersist: true,
            readMilliseconds: 1,
            decodeMilliseconds: 1,
            totalMilliseconds: 2
        )
        let loader = SequencedVaultInitialLoader(results: [delayed, recovered])
        let persistence = RecordingVaultPersistence()
        let store = AppStore(
            dependencies: Self.dependencies(
                defaults: defaults,
                persistence: persistence,
                initialLoader: loader
            )
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !store.isInitialDataLoaded, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.isInitialDataLoaded)
        #expect(!store.isVaultLoadFailurePresented)
        #expect(store.stockStore.stocks.map { $0.symbol } == ["RETRIED"])
        #expect(loader.loadCount >= 2)
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

    @Test func legacyRemovedModuleDataIsListedAndClearedWithItsAttachments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyData-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = AttachmentStore(directoryURL: root)
        let photo = try attachments.save(data: Data("jpeg".utf8), originalFileName: "shop.jpg", contentType: .jpeg)
        let kept = try attachments.save(data: Data("pdf".utf8), originalFileName: "kept.pdf", contentType: .pdf)
        var record = MedicalRecord()
        record.attachments = [kept]
        var vault = VaultData(medicalRecords: [record])
        vault.foodPlaces = [.object([
            "id": .string("F1"),
            "shopName": .string("老店"),
            "photos": .array([.object(["storedFileName": .string(photo.storedFileName)])])
        ])]
        vault.foodPlaceTags = ["面馆"]
        vault.partnershipBooks = [.object(["id": .string("P1"), "name": .string("合伙账本")])]
        vault.unknownPayloads["legacyField"] = .string("old")
        let persistence = RecordingVaultPersistence()
        let store = AppStore(initialVault: vault, dependencies:
            Self.dependencies(defaults: Self.makeDefaults(), persistence: persistence, attachmentStore: attachments))
        #expect(store.referencedAttachmentStoredFileNames.contains(photo.storedFileName))

        let report = store.scanLegacyData()
        #expect(report.findings.map(\.id) == ["foodMap", "partnership", "unknownPayloads"])
        #expect(report.findings[0].items.map(\.title) == ["老店", "标签：面馆"])
        #expect(report.findings[0].items[0].attachmentStoredFileNames == [photo.storedFileName])
        #expect(report.findings[1].items.map(\.id) == ["partnershipBook.P1"])
        #expect(report.findings[2].items.map(\.title) == ["legacyField"])
        #expect(report.attachmentStoredFileNames == [photo.storedFileName])

        #expect(store.cleanupLegacyData() == report)
        #expect(store.scanLegacyData().isEmpty)
        #expect(persistence.scheduleCount == 1)
        #expect(!store.referencedAttachmentStoredFileNames.contains(photo.storedFileName))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: attachments.url(for: photo).path))
        #expect(FileManager.default.fileExists(atPath: attachments.url(for: kept).path))
    }

    @Test func quarantinedLegacyPayloadIsListedAndClearedButCompiledQuarantineIsKept() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.isolateVaultModules] = true
        let raw = #"{"foodPlaces":{"broken":{"storedFileName":"lost.jpg"}},"stocks":"bad-stocks"}"#
        let vault = try decoder.decode(VaultData.self, from: Data(raw.utf8))
        #expect(vault.unavailableModules == ["foodMap", "myStocks"])

        let report = LegacyVaultData.scan(vault)
        #expect(report.findings.map(\.id) == ["foodMap"])
        #expect(report.attachmentStoredFileNames == ["lost.jpg"])
        let cleaned = LegacyVaultData.removing(from: vault)
        #expect(cleaned.unavailableModules == ["myStocks"])
        #expect(cleaned.preservedModulePayloads.keys.sorted() == ["stocks"])
        #expect(LegacyVaultData.scan(cleaned).isEmpty)
    }

    @Test func storageScanListsEachOrphanAndMissingAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("MyTools/Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, size) in [("a.pdf", 3), ("b.jpg", 5), ("c.png", 7)] {
            try Data(repeating: 1, count: size).write(to: directory.appendingPathComponent(name))
        }
        let service = StorageUsageService(applicationSupportDirectory: root, cachesDirectory: root.appendingPathComponent("Caches"))

        let result = try service.scan(referencedStoredFileNames: ["a.pdf", "gone.pdf", "also-gone.heic"])
        #expect(result.orphanAttachments.map(\.storedFileName) == ["b.jpg", "c.png"])
        #expect(result.orphanAttachments.map(\.byteCount) == [5, 7])
        #expect(result.orphanAttachments.allSatisfy { $0.modifiedAt != nil })
        #expect(result.missingAttachments.map(\.storedFileName) == ["also-gone.heic", "gone.pdf"])
        #expect(result.usage.attachmentCount == 3)

        #expect(try service.deleteOrphans([result.orphanAttachments[0]]) == 5)
        let rescanned = try service.scan(referencedStoredFileNames: ["a.pdf"])
        #expect(rescanned.orphanAttachments.map(\.storedFileName) == ["c.png"])
        #expect(rescanned.missingAttachments.isEmpty)
    }

    // AUDIT-084：诊断目录整体计入，系统日志抄本与 CallStacks 不会两头漏算。
    @Test func storageScanCountsTheWholeDiagnosticsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = root.appendingPathComponent("MyTools/Diagnostics", isDirectory: true)
        let callStacks = diagnostics.appendingPathComponent("CallStacks", isDirectory: true)
        try FileManager.default.createDirectory(at: callStacks, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: diagnostics.appendingPathComponent("MyTools-Diagnostics.log"))
        try Data(repeating: 1, count: 5).write(to: diagnostics.appendingPathComponent("MyTools-SystemLog.log"))
        try Data(repeating: 1, count: 7).write(to: callStacks.appendingPathComponent("stack.txt"))
        let service = StorageUsageService(applicationSupportDirectory: root, cachesDirectory: root.appendingPathComponent("Caches"))

        let usage = try service.scan(referencedStoredFileNames: []).usage
        #expect(usage.diagnosticsBytes == 15)
        #expect(usage.otherBytes == 0)
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
        transaction.tradedAt = Date(timeIntervalSince1970: 1_700_000_000)
        transaction.quantity = 2
        transaction.unitPrice = 10

        let didSave = store.stockStore.upsertTransaction(transaction, in: stock.id)

        #expect(didSave)
        #expect(store.stockStore.stocks.first?.currentShares == 2)
        #expect(persistence.scheduleCount == 1)
    }

    @Test func archivingClosedStockKeepsHistoryAndTotalProfit() throws {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var stock = StockHolding(symbol: "TEST")
        var buy = StockTransaction()
        buy.type = .buy
        buy.tradedAt = Date(timeIntervalSince1970: 1)
        buy.quantity = 2
        buy.unitPrice = 10
        var sell = StockTransaction()
        sell.type = .sell
        sell.tradedAt = Date(timeIntervalSince1970: 2)
        sell.quantity = 2
        sell.unitPrice = 12
        stock.transactions = [buy, sell]
        let store = AppStore(
            initialVault: VaultData(stocks: [stock]),
            dependencies: Self.dependencies(defaults: defaults, persistence: persistence)
        )

        #expect(store.stockStore.archiveStock(id: stock.id, at: Date(timeIntervalSince1970: 10)))
        let archived = try #require(store.stockStore.stocks.first)
        #expect(archived.isArchived)
        #expect(archived.realizedProfitLoss == 4)
        #expect(
            StockPortfolioSummary(market: .aShare, stocks: store.stockStore.stocks).totalProfitLoss == 4
        )
        #expect(persistence.scheduleCount == 1)
    }

    @Test func moduleLocalDataDeletionCanBeUndoneWithoutTouchingOtherModules() async throws {
        let defaults = Self.makeDefaults()
        let persistence = RecordingVaultPersistence()
        var stock = StockHolding()
        stock.symbol = "TEST"
        var record = MedicalRecord()
        record.hospital = "保留记录"
        let store = AppStore(
            initialVault: VaultData(stocks: [stock], medicalRecords: [record]),
            dependencies: Self.dependencies(defaults: defaults, persistence: persistence)
        )

        let deletion = try #require(
            store.beginModuleLocalDataDeletion(for: .myStocks, undoWindow: 60)
        )
        #expect(store.stockStore.stocks.isEmpty)
        #expect(store.healthStore.medicalRecords == [record])
        let pendingCloudSnapshot = try await store.makeCloudSyncSnapshot()
        #expect(!pendingCloudSnapshot.participatingModules.contains(.myStocks))

        #expect(store.undoModuleLocalDataDeletion(id: deletion.id))
        #expect(store.stockStore.stocks == [stock])
        #expect(store.healthStore.medicalRecords == [record])
        #expect(store.pendingModuleLocalDataDeletion == nil)
    }

    @Test func hiddenModuleStillParticipatesInCloudSync() async throws {
        let defaults = Self.makeDefaults()
        let settings = ToolModuleSettings(defaults: defaults)
        settings.setVisible(false, for: .myStocks)
        settings.setVisible(true, for: .healthRecords)
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

    @Test func hiddenModuleIsExcludedFromBackup() async throws {
        // 产品契约：隐藏模块不参与加密备份（与 CloudKit 参与范围不同）。
        let defaults = Self.makeDefaults()
        let settings = ToolModuleSettings(defaults: defaults)
        settings.setVisible(false, for: .myStocks)
        settings.setVisible(true, for: .healthRecords)
        var stock = StockHolding()
        stock.symbol = "HIDDEN"
        var record = MedicalRecord()
        record.hospital = "可见记录"
        let store = AppStore(
            initialVault: VaultData(stocks: [stock], medicalRecords: [record]),
            moduleSettings: settings,
            dependencies: Self.dependencies(
                defaults: defaults,
                persistence: RecordingVaultPersistence()
            )
        )

        let document = try await store.makeBackupDocument(password: "test-password-123")
        let payload = try await AppStoreBackupProcessor().restorePayload(
            from: document.data,
            password: "test-password-123",
            enabledModules: ToolModuleCatalog.allModules
        )

        #expect(!payload.includedModules.contains(.myStocks))
        #expect(payload.includedModules.contains(.healthRecords))
        #expect(payload.vault.stocks.isEmpty)
        #expect(payload.vault.medicalRecords.map(\.hospital) == ["可见记录"])
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
            allowClosedMissingData: false,
            forceRefresh: true
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
        moduleLocalDataCacheCleaner: any ModuleLocalDataCacheClearing = DisabledModuleLocalDataCacheCleaner(),
        attachmentStore: AttachmentStore = AttachmentStore()
    ) -> AppStoreDependencies {
        AppStoreDependencies(
            initialLoader: initialLoader,
            persistence: persistence,
            quoteService: quoteService,
            exchangeRateRepository: EmptyExchangeRateProvider(),
            alertNotifications: NoopAlertNotificationRouter(),
            stockRefreshInvalidator: NoopStockRefreshInvalidator(),
            backupProcessor: AppStoreBackupProcessor(),
            attachmentStore: attachmentStore,
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

/// Holds the initial load until the test opens the gate.
private final class GatedVaultInitialLoader: VaultInitialLoading, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    let result: LocalVaultLoadResult

    init(result: LocalVaultLoadResult) {
        self.result = result
    }

    func open() { gate.signal() }

    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        gate.wait()
        return result
    }
}

private final class SequencedVaultInitialLoader: VaultInitialLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [LocalVaultLoadResult]
    private var index = 0

    init(results: [LocalVaultLoadResult]) {
        self.results = results
    }

    var loadCount: Int {
        lock.withLock { index }
    }

    func loadVaultWithMetrics() -> LocalVaultLoadResult {
        lock.withLock {
            let result = results[min(index, results.count - 1)]
            index += 1
            return result
        }
    }
}

private final class RecordingVaultPersistence: VaultPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedScheduleCount = 0
    private var storedSaveImmediatelyCount = 0
    private var storedFlushError: String?
    var flushError: String? {
        get { lock.withLock { storedFlushError } }
        set { lock.withLock { storedFlushError = newValue } }
    }

    var scheduleCount: Int {
        lock.withLock { storedScheduleCount }
    }

    func schedule(_ vault: VaultData, secrets: [SecretItem]) {
        lock.withLock { storedScheduleCount += 1 }
    }

    var saveImmediatelyCount: Int {
        lock.withLock { storedSaveImmediatelyCount }
    }

    func saveImmediately(_ vault: VaultData, secrets: [SecretItem], preservingOriginal: Bool) throws {
        lock.withLock { storedSaveImmediatelyCount += 1 }
    }

    func flush() async -> String? { flushError }
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

private actor CountingClosedQuoteProvider: StockQuoteRefreshing {
    private(set) var count = 0
    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote] {
        count += 1
        return [:]
    }
}

/// 第一次请求挂起直到 `release()`，之后的请求立即返回。
private actor GatedQuoteProvider: StockQuoteRefreshing {
    private(set) var count = 0
    private(set) var requestedSizes: [Int] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote] {
        count += 1
        requestedSizes.append(stocks.count)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if count == 1 { await withCheckedContinuation { gate = $0 } }
        return [:]
    }
    func waitUntilStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        gate?.resume()
        gate = nil
    }
}

private actor RecordingStockCharts: StockChartServing {
    private let cachedSnapshot: StockChartSnapshot?
    private let fetchedSnapshot: StockChartSnapshot?
    private let suspendFirstCacheRead: Bool
    private var cacheReadStarted = false
    private var cacheReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedCacheRead: CheckedContinuation<StockChartSnapshot?, Never>?
    func waitUntilCacheReadStarted() async {
        if cacheReadStarted { return }
        await withCheckedContinuation { cacheReadWaiters.append($0) }
    }
    func finishSuspendedCacheRead() {
        suspendedCacheRead?.resume(returning: cachedSnapshot)
        suspendedCacheRead = nil
    }
    struct Request: Sendable {
        let stockID: UUID
        let range: StockChartRange
        let forceRefresh: Bool
    }
    private(set) var requests: [Request] = []
    private let fails: Bool
    private let failingRanges: Set<StockChartRange>
    init(cachedSnapshot: StockChartSnapshot? = nil, fails: Bool = false, failingRanges: Set<StockChartRange> = [], fetchedSnapshot: StockChartSnapshot? = nil, suspendFirstCacheRead: Bool = false) {
        self.cachedSnapshot = cachedSnapshot
        self.fetchedSnapshot = fetchedSnapshot
        self.suspendFirstCacheRead = suspendFirstCacheRead
        self.fails = fails
        self.failingRanges = failingRanges
    }
    private(set) var fetchCount = 0
    private(set) var peakConcurrentRequests = 0
    private var active = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        if fetchCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func cachedChart(for stock: StockHolding, range: StockChartRange) async -> StockChartSnapshot? {
        if suspendFirstCacheRead, !cacheReadStarted, range == .intraday {
            cacheReadStarted = true
            for waiter in cacheReadWaiters { waiter.resume() }
            cacheReadWaiters.removeAll()
            return await withCheckedContinuation { suspendedCacheRead = $0 }
        }
        return cachedSnapshot
    }
    func fetchChart(for stock: StockHolding, range: StockChartRange, forceRefresh: Bool) async throws -> StockChartSnapshot {
        fetchCount += 1
        requests.append(Request(stockID: stock.id, range: range, forceRefresh: forceRefresh))
        active += 1
        peakConcurrentRequests = max(peakConcurrentRequests, active)
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(80))
        if fails || failingRanges.contains(range) { throw StockChartError.serviceUnavailable }
        if let fetchedSnapshot { return fetchedSnapshot }
        return StockChartSnapshot(symbol: stock.symbol, name: stock.displayName,
                                  currencyCode: stock.market.currencyCode, previousClose: 99,
                                  points: [StockChartFixtures.point(at: Date(), close: 100)],
                                  indicatorPoints: nil, quoteUpdatedAt: Date(), fetchedAt: Date(),
                                  source: "Fixture", supportsCandlesticks: true)
    }
    func refreshAfterFinalSession(for stock: StockHolding) async throws {}
    func isChartStale(for stock: StockHolding) async -> Bool { false }
    func clearCache(for stock: StockHolding) async {}
}
