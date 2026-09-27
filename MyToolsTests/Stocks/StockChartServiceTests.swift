import Foundation
import Testing
@testable import MyTools

struct StockChartServiceTests {
    @Test func uncooperativeProviderCannotHoldCallerPastDeadlineOrWriteLateCache() async throws {
        let context = try makeContext(market: .unitedStates, range: .dayK,
                                      providerDelay: .seconds(1), flightTimeout: .milliseconds(30), ignoresCancellation: true)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let start = ContinuousClock.now
        do {
            _ = try await context.service.fetchChart(for: context.stock, range: .dayK, forceRefresh: true)
            Issue.record("Expected deadline")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(start.duration(to: .now) < .milliseconds(700))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await context.service.cachedChart(for: context.stock, range: .dayK) == nil)
    }

    @Test func cancellingOneConsumerPreservesSharedProducerForAnother() async throws {
        let context = try makeContext(market: .unitedStates, range: .dayK, providerDelay: .milliseconds(400))
        defer { try? FileManager.default.removeItem(at: context.root) }
        let first = Task { try await context.service.fetchChart(for: context.stock, range: .dayK, forceRefresh: true) }
        let second = Task { try await context.service.fetchChart(for: context.stock, range: .weekK, forceRefresh: true) }
        try await Task.sleep(for: .milliseconds(80))
        first.cancel()
        do { _ = try await first.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        let result = try await second.value
        #expect(!result.points.isEmpty)
        #expect(await context.recorder.calls() == ["yahoo"])
    }

    @Test func cancellingLastConsumerAllowsFreshRetry() async throws {
        let context = try makeContext(market: .unitedStates, range: .dayK, providerDelay: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: context.root) }
        let first = Task { try await context.service.fetchChart(for: context.stock, range: .dayK, forceRefresh: true) }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        _ = await first.result
        try await Task.sleep(for: .milliseconds(30))
        let result = try await context.service.fetchChart(for: context.stock, range: .dayK, forceRefresh: true)
        #expect(!result.points.isEmpty)
    }
    @Test func requestDeadlineStopsSlowProvider() async throws {
        let context = try makeContext(market: .unitedStates, range: .dayK,
                                      providerDelay: .seconds(5), flightTimeout: .milliseconds(30))
        defer { try? FileManager.default.removeItem(at: context.root) }
        let started = ContinuousClock.now
        do {
            _ = try await context.service.fetchChart(for: context.stock, range: .dayK, forceRefresh: true)
            Issue.record("Expected timeout")
        } catch {
            #expect(error is URLError || error is CancellationError)
        }
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(await context.service.cachedChart(for: context.stock, range: .dayK) == nil)
    }
    @Test func concurrentDailyAndDerivedRequestsShareOneProviderFetch() async throws {
        let context = try makeContext(market: .unitedStates, range: .dayK, providerDelay: .milliseconds(100))
        defer { try? FileManager.default.removeItem(at: context.root) }
        try await withThrowingTaskGroup(of: StockChartSnapshot.self) { group in
            for range in [StockChartRange.dayK, .weekK, .monthK, .quarterK, .yearK] {
                group.addTask {
                    try await context.service.fetchChart(for: context.stock, range: range, forceRefresh: true)
                }
            }
            for try await snapshot in group { #expect(!snapshot.points.isEmpty) }
        }
        #expect(await context.recorder.calls() == ["yahoo"])
        #expect(await context.recorder.ranges() == [.dayK])
    }

    @Test func navigatingBetweenKLineRangesDoesNotRefetchIncompleteHistoryWithinCooldown() async throws {
        let context = try makeContext(market: .unitedStates, range: .dayK)
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try await context.service.fetchChart(for: context.stock, range: .dayK)
        for range in [StockChartRange.weekK, .monthK, .dayK, .yearK] {
            _ = try await context.service.fetchChart(for: context.stock, range: range)
        }
        #expect(await context.recorder.calls() == ["yahoo"])
        _ = try await context.service.fetchChart(for: context.stock, range: .dayK, forceRefresh: true)
        #expect(await context.recorder.calls() == ["yahoo", "yahoo"])
    }
    @Test func nonUSMarketFallsBackFromTencentToEastmoney() async throws {
        let context = try makeContext(market: .aShare, range: .dayK)
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .dayK
        )

        #expect(await context.recorder.calls() == ["tencent", "eastmoney"])
    }

    @Test func USIntradayTriesYahooBeforeNasdaq() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .intraday,
            yahooBehavior: .failure(.noData),
            nasdaqSucceeds: true
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .intraday
        )

        let calls = await context.recorder.calls()
        // The successful Nasdaq response may trigger the normal minute
        // indicator warm-up request. Assert the fallback order without tying
        // this provider-order test to that independent enrichment pass.
        #expect(Set(calls.prefix(2)) == ["tencent", "yahoo"])
        #expect(calls.dropFirst(2).first == "nasdaq")
    }

    @Test func USFiveDaysSkipsNasdaqAndFallsBackToYahoo() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .fiveDays,
            yahooBehavior: nil,
            nasdaqSucceeds: false
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .fiveDays
        )

        #expect(await context.recorder.calls() == ["tencent", "yahoo"])
    }

    @Test func USHistoricalFallsBackToNasdaqAfterYahoo() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .dayK,
            yahooBehavior: .failure(.noData),
            nasdaqSucceeds: true
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .dayK
        )

        #expect(await context.recorder.calls() == ["yahoo", "nasdaq"])
    }

    @Test func USYearKUsesYahooCompleteDailyHistory() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .yearK,
            yahooBehavior: nil,
            nasdaqSucceeds: true
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .yearK
        )

        #expect(await context.recorder.calls() == ["yahoo"])
        #expect(await context.recorder.ranges() == [.dayK])
    }

    @Test func everyDerivedKLineRequestsOnlyCanonicalDailyBars() async throws {
        for range in [
            StockChartRange.weekK,
            .monthK,
            .quarterK,
            .yearK
        ] {
            let context = try makeContext(
                market: .unitedStates,
                range: range,
                yahooBehavior: nil,
                nasdaqSucceeds: true
            )
            defer { try? FileManager.default.removeItem(at: context.root) }

            _ = try await context.service.fetchChart(
                for: context.stock,
                range: range
            )

            #expect(await context.recorder.ranges() == [.dayK])
        }
    }

    @Test func USDayKUsesYahooCompleteDailyHistory() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .dayK,
            yahooBehavior: nil,
            nasdaqSucceeds: true
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .dayK
        )

        #expect(await context.recorder.calls() == ["yahoo"])
    }

    @Test func allProviderFailuresBecomeServiceUnavailable() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .dayK,
            yahooBehavior: .failure(.noData),
            nasdaqSucceeds: false
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        await #expect(throws: StockChartError.serviceUnavailable) {
            _ = try await context.service.fetchChart(
                for: context.stock,
            range: .dayK
            )
        }
        let calls = await context.recorder.calls()
        #expect(Array(calls.prefix(2)) == ["yahoo", "nasdaq"])
    }

    private func makeContext(
        market: StockMarket,
        range: StockChartRange,
        yahooBehavior: FakeStockChartProvider.Behavior? = nil,
        nasdaqSucceeds: Bool = false,
        providerDelay: Duration = .zero,
        flightTimeout: Duration = .seconds(18),
        ignoresCancellation: Bool = false
    ) throws -> (
        root: URL,
        stock: StockHolding,
        service: StockChartService,
        recorder: StockChartProviderCallRecorder
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyToolsServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = StockChartProviderCallRecorder()
        let stock = StockHolding(
            market: market,
            symbol: market == .unitedStates ? "VOO" : "600519",
            name: "Test Stock"
        )
        let success = snapshot(for: stock, range: range)
        let providers = StockChartProviders(
            tencent: FakeStockChartProvider(
                id: "tencent",
                behavior: .failure(.noData),
                recorder: recorder
            ),
            eastmoney: FakeStockChartProvider(
                id: "eastmoney",
                behavior: market == .unitedStates ? .failure(.noData) : .success(success),
                recorder: recorder
            ),
            yahoo: FakeStockChartProvider(
                id: "yahoo",
                behavior: yahooBehavior ?? .success(success),
                recorder: recorder,
                delay: providerDelay,
                ignoresCancellation: ignoresCancellation
            ),
            nasdaq: FakeStockChartProvider(
                id: "nasdaq",
                behavior: nasdaqSucceeds ? .success(success) : .failure(.noData),
                recorder: recorder
            )
        )
        let diskStore = StockChartDiskStore(
            persistentStoreDirectory: root.appendingPathComponent("Persistent")
        )
        return (root, stock, StockChartService(
            diskStore: diskStore,
            providers: providers,
            flightTimeout: flightTimeout
        ), recorder)
    }

    private func snapshot(
        for stock: StockHolding,
        range: StockChartRange
    ) -> StockChartSnapshot {
        let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
        let endDate = StockChartFixtures.date(2026, 8, 7)
        let points = (0..<90).compactMap { index -> StockChartPoint? in
            let baseDate: Date
            if range == .intraday {
                baseDate = calendar.date(
                    byAdding: .day,
                    value: index < 45 ? -1 : 0,
                    to: endDate
                ) ?? endDate
            } else {
                guard let historicalDate = calendar.date(
                    byAdding: .day,
                    value: index - 89,
                    to: endDate
                ) else {
                    return nil
                }
                baseDate = historicalDate
            }
            guard let date = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: baseDate) else {
                return nil
            }
            let pointDate: Date
            if range == .intraday {
                pointDate = calendar.date(
                    bySettingHour: 9,
                    minute: 30,
                    second: index % 60,
                    of: date.addingTimeInterval(Double(index / 60) * 3_600)
                ) ?? date
            } else {
                pointDate = date
            }
            return StockChartFixtures.point(at: pointDate, close: 100 + Double(index))
        }
        return StockChartSnapshot(
            symbol: stock.symbol,
            name: stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: 188,
            points: points,
            indicatorPoints: range == .intraday || range == .fiveDays ? points : nil,
            dailyIndicatorPoints: range == .fiveDays ? points : nil,
            quoteUpdatedAt: points.last!.date,
            fetchedAt: endDate,
            source: "Fake",
            supportsCandlesticks: true
        )
    }
}
