import Foundation
import Testing
@testable import MyTools

struct StockChartServiceTests {
    @Test func nonUSMarketFallsBackFromTencentToEastmoney() async throws {
        let context = try makeContext(market: .aShare, range: .oneMonth)
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .oneMonth
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

        #expect(await context.recorder.calls() == ["tencent", "yahoo", "nasdaq"])
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

    @Test func USHistoricalUsesNasdaqBeforeYahoo() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .oneYear,
            yahooBehavior: nil,
            nasdaqSucceeds: true
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        _ = try await context.service.fetchChart(
            for: context.stock,
            range: .oneYear
        )

        #expect(await context.recorder.calls() == ["tencent", "nasdaq"])
    }

    @Test func allProviderFailuresBecomeServiceUnavailable() async throws {
        let context = try makeContext(
            market: .unitedStates,
            range: .oneYear,
            yahooBehavior: .failure(.noData),
            nasdaqSucceeds: false
        )
        defer { try? FileManager.default.removeItem(at: context.root) }

        await #expect(throws: StockChartError.serviceUnavailable) {
            _ = try await context.service.fetchChart(
                for: context.stock,
                range: .oneYear
            )
        }
        #expect(await context.recorder.calls() == ["tencent", "nasdaq", "yahoo"])
    }

    private func makeContext(
        market: StockMarket,
        range: StockChartRange,
        yahooBehavior: FakeStockChartProvider.Behavior? = nil,
        nasdaqSucceeds: Bool = false
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
                recorder: recorder
            ),
            nasdaq: FakeStockChartProvider(
                id: "nasdaq",
                behavior: nasdaqSucceeds ? .success(success) : .failure(.noData),
                recorder: recorder
            )
        )
        let diskStore = StockChartDiskStore(
            persistentStoreDirectory: root.appendingPathComponent("Persistent"),
            legacyCacheDirectory: root.appendingPathComponent("Legacy")
        )
        return (root, stock, StockChartService(
            diskStore: diskStore,
            providers: providers
        ), recorder)
    }

    private func snapshot(
        for stock: StockHolding,
        range: StockChartRange
    ) -> StockChartSnapshot {
        let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
        let endDate = StockChartFixtures.date(2026, 8, 7)
        let points = (0..<90).compactMap { index -> StockChartPoint? in
            guard let date = calendar.date(byAdding: .day, value: index - 89, to: endDate) else {
                return nil
            }
            return StockChartFixtures.point(at: date, close: 100 + Double(index))
        }
        return StockChartSnapshot(
            symbol: stock.symbol,
            name: stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: 188,
            points: points,
            indicatorPoints: range == .intraday || range == .fiveDays ? points : nil,
            quoteUpdatedAt: points.last!.date,
            fetchedAt: endDate,
            source: "Fake",
            supportsCandlesticks: true
        )
    }
}
