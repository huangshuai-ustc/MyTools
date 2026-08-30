import Foundation
import Testing
@testable import MyTools

struct StockChartDiskStoreTests {
    @Test func persistedSeriesCanBeRenderedByANewStoreInstance() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let points = samplePoints(count: 80)
        let snapshot = StockChartSnapshot(
            symbol: key.symbol,
            name: "Vanguard S&P 500 ETF",
            currencyCode: "USD",
            previousClose: 500,
            points: Array(points.suffix(20)),
            indicatorPoints: points,
            dailyIndicatorPoints: points,
            quoteUpdatedAt: points.last!.date,
            fetchedAt: StockChartFixtures.date(2026, 8, 7),
            source: "Test",
            supportsCandlesticks: true
        )
        var writer = makeStore(directories)
        let persisted = writer.merging(
            snapshot,
            range: .dayK,
            for: key,
            into: nil
        )

        writer.save(persisted, for: key)

        var reader = makeStore(directories)
        let loadedStore = reader.load(for: key)
        let reloaded = try #require(loadedStore)
        let rendered = try #require(
            reader.renderedSnapshot(from: reloaded, range: .dayK)
        )
        #expect(rendered.symbol == key.symbol)
        #expect(rendered.points == StockChartSeriesProcessor.visiblePoints(
            from: points,
            for: .dayK,
            market: key.market
        ))
        #expect(rendered.indicatorPoints?.count == 80)
        #expect(rendered.dailyIndicatorPoints?.count == 80)
        #expect(rendered.cachedDailyTechnicalIndicators?.count == 80)
        #expect(
            reloaded.technicalIndicatorCacheVersion
                == StockChartPersistedStore.currentTechnicalIndicatorCacheVersion
        )
        #expect(FileManager.default.fileExists(atPath: reader.persistentStoreURL(for: key).path))
    }

    @Test func legacyTechnicalIndicatorsAreRebuiltFromLocalOHLCVAndPersistedOnce() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let points = varyingSamplePoints(count: 100)
        let metadata = StockChartStoredRangeMetadata(
            symbol: key.symbol,
            name: "VOO",
            currencyCode: "USD",
            previousClose: 99,
            quoteUpdatedAt: points.last!.date,
            fetchedAt: points.last!.date,
            source: "Legacy Cache",
            supportsCandlesticks: true,
            indicatorPointCount: nil,
            dailyIndicatorPointCount: points.count
        )
        let legacyIndicators = points.map {
            StockTechnicalIndicatorPoint(
                date: $0.date,
                movingAverage5: nil,
                movingAverage20: nil,
                movingAverage60: nil,
                bollingerMiddle: nil,
                bollingerUpper: nil,
                bollingerLower: nil,
                macdLine: 0,
                macdSignal: 0,
                macdHistogram: 0,
                rsi14: nil,
                rsi30: nil
            )
        }
        let legacyStore = StockChartPersistedStore(
            version: StockChartPersistedStore.currentVersion,
            market: key.market,
            symbol: key.symbol,
            series: [StockChartSeriesKind.daily.rawValue: points],
            technicalIndicators: ["daily": legacyIndicators],
            technicalIndicatorCacheVersion: nil,
            rangeMetadata: [StockChartRange.dayK.rawValue: metadata]
        )
        var store = makeStore(directories)
        let url = store.persistentStoreURL(for: key)
        try FileManager.default.createDirectory(
            at: directories.persistent,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(legacyStore).write(to: url, options: .atomic)

        let loaded = store.load(for: key)
        let migrated = try #require(loaded)
        let daily = try #require(migrated.technicalIndicators["daily"])
        #expect(
            migrated.technicalIndicatorCacheVersion
                == StockChartPersistedStore.currentTechnicalIndicatorCacheVersion
        )
        #expect(daily.count == points.count)
        #expect(daily.last?.stochasticK != nil)
        #expect(daily.last?.williamsR != nil)
        #expect(daily.last?.commodityChannelIndex != nil)
        #expect(daily.last?.averageDirectionalIndex != nil)
        #expect(daily.last?.momentum != nil)
        #expect(daily.last?.trix != nil)
        #expect(daily.last?.onBalanceVolume != nil)
        #expect(daily.last?.moneyFlowIndex != nil)
        #expect(daily.last?.accumulationDistribution != nil)
        #expect(daily.last?.chaikinMoneyFlow != nil)
        #expect(daily.last?.psychologicalLine != nil)
        #expect(daily.last?.rateOfChange != nil)

        let persisted = try JSONDecoder().decode(
            StockChartPersistedStore.self,
            from: Data(contentsOf: url)
        )
        #expect(
            persisted.technicalIndicatorCacheVersion
                == StockChartPersistedStore.currentTechnicalIndicatorCacheVersion
        )
        #expect(persisted.technicalIndicators["daily"]?.last?.trix != nil)
    }

    @Test func unsupportedPersistentStoreVersionIsIgnored() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let unsupported = StockChartPersistedStore(
            version: StockChartPersistedStore.currentVersion + 1,
            market: key.market,
            symbol: key.symbol,
            series: [:],
            rangeMetadata: [:]
        )
        var store = makeStore(directories)
        let url = store.persistentStoreURL(for: key)
        try FileManager.default.createDirectory(
            at: directories.persistent,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(unsupported).write(to: url, options: .atomic)

        #expect(store.load(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func minuteMetadataWithoutIndicatorCountRequiresRefresh() {
        let point = StockChartFixtures.point(
            at: StockChartFixtures.date(2026, 8, 7, hour: 10)
        )
        let metadata = StockChartStoredRangeMetadata(
            symbol: "VOO",
            name: "VOO",
            currencyCode: "USD",
            previousClose: 500,
            quoteUpdatedAt: point.date,
            fetchedAt: point.date,
            source: "Old Cache",
            supportsCandlesticks: true,
            indicatorPointCount: nil
        )
        let persisted = StockChartPersistedStore(
            version: StockChartPersistedStore.currentVersion,
            market: .unitedStates,
            symbol: "VOO",
            series: [StockChartSeriesKind.intraday.rawValue: [point]],
            rangeMetadata: [StockChartRange.intraday.rawValue: metadata]
        )
        let store = StockChartDiskStore()

        #expect(!store.hasRequestedCoverage(in: persisted, for: .intraday))
    }

    @Test func fiveDaysSharesTheRawIntradaySeries() {
        let points = (0..<30).map { index in
            StockChartFixtures.point(
                at: StockChartFixtures.date(
                    2026,
                    8,
                    7,
                    hour: 10,
                    minute: index,
                    timeZone: "America/New_York"
                )
            )
        }
        let snapshot = StockChartSnapshot(
            symbol: "VOO",
            name: "VOO",
            currencyCode: "USD",
            previousClose: nil,
            points: Array(points.suffix(10)),
            indicatorPoints: points,
            quoteUpdatedAt: points.last!.date,
            fetchedAt: points.last!.date,
            source: "Test",
            supportsCandlesticks: true
        )
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let store = StockChartDiskStore()
        let persisted = store.merging(
            snapshot,
            range: .fiveDays,
            for: key,
            into: nil
        )

        #expect(persisted.series[StockChartSeriesKind.intraday.rawValue] == points)
        #expect(
            persisted.derivedSeries[StockChartSeriesKind.fiveDayMinute.rawValue] != nil
        )
    }

    @Test func weeklyRangeUsesDailyRawSeriesAndCachesDerivedBars() throws {
        let inception = StockChartFixtures.date(2023, 1, 3)
        let middle = StockChartFixtures.date(2023, 1, 6)
        let latest = StockChartFixtures.date(2026, 8, 7)
        let dailyPoints = [
            StockChartFixtures.point(at: inception, close: 20),
            StockChartFixtures.point(at: middle, close: 30),
            StockChartFixtures.point(at: latest, close: 40)
        ]
        let metadata = StockChartStoredRangeMetadata(
            symbol: "NBIS",
            name: "Nebius",
            currencyCode: "USD",
            previousClose: nil,
            quoteUpdatedAt: latest,
            fetchedAt: latest,
            source: "Test",
            supportsCandlesticks: true,
            indicatorPointCount: nil
        )
        let persisted = StockChartPersistedStore(
            version: StockChartPersistedStore.currentVersion,
            market: .unitedStates,
            symbol: "NBIS",
            series: [StockChartSeriesKind.daily.rawValue: dailyPoints],
            rangeMetadata: [StockChartRange.weekK.rawValue: metadata]
        )

        let store = StockChartDiskStore()
        let rendered = try #require(
            store.renderedSnapshot(from: persisted, range: .weekK)
        )

        #expect(rendered.points.map(\.date) == [middle, latest])
        #expect(
            Set(persisted.series.keys) == Set([StockChartSeriesKind.daily.rawValue])
        )
    }

    @Test func yearKIsAggregatedFromDailyRawSeries() throws {
        let earliestYear = StockChartFixtures.date(2010, 1, 4)
        let recentMonth = StockChartFixtures.date(2024, 1, 2)
        let latest = StockChartFixtures.date(2026, 8, 7)
        let dailyPoints = [
            StockChartFixtures.point(at: earliestYear, close: 10),
            StockChartFixtures.point(at: recentMonth, close: 30),
            StockChartFixtures.point(at: latest, close: 40)
        ]
        let metadata = StockChartStoredRangeMetadata(
            symbol: "TEST",
            name: "Test",
            currencyCode: "USD",
            previousClose: nil,
            quoteUpdatedAt: latest,
            fetchedAt: latest,
            source: "Test",
            supportsCandlesticks: true,
            indicatorPointCount: nil
        )
        let persisted = StockChartPersistedStore(
            version: StockChartPersistedStore.currentVersion,
            market: .unitedStates,
            symbol: "TEST",
            series: [StockChartSeriesKind.daily.rawValue: dailyPoints],
            rangeMetadata: [StockChartRange.yearK.rawValue: metadata]
        )

        let store = StockChartDiskStore()
        let rendered = try #require(
            store.renderedSnapshot(from: persisted, range: .yearK)
        )

        #expect(rendered.points.map(\.date) == [earliestYear, recentMonth, latest])
    }

    @Test func allKLineRangesReuseOneCompleteDailySeries() throws {
        let first = StockChartFixtures.point(
            at: StockChartFixtures.date(2010, 9, 9),
            close: 100
        )
        let latest = StockChartFixtures.point(
            at: StockChartFixtures.date(2026, 8, 7),
            close: 500
        )
        let snapshot = StockChartSnapshot(
            symbol: "VOO",
            name: "Vanguard S&P 500 ETF",
            currencyCode: "USD",
            previousClose: nil,
            points: [first, latest],
            indicatorPoints: nil,
            dailyIndicatorPoints: [first, latest],
            quoteUpdatedAt: latest.date,
            fetchedAt: latest.date,
            source: "Yahoo Finance",
            supportsCandlesticks: true
        )
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let store = StockChartDiskStore()
        let persisted = store.merging(snapshot, range: .dayK, for: key, into: nil)

        #expect(
            Set(persisted.series.keys) == Set([StockChartSeriesKind.daily.rawValue])
        )

        for range in StockChartRange.allCases where range.isKLineRange {
            let rendered = try #require(store.renderedSnapshot(from: persisted, range: range))
            let renderedFirst = try #require(rendered.points.first)
            #expect(renderedFirst.date >= first.date)
            #expect(rendered.points.last?.date == latest.date)
            #expect(store.hasRequestedCoverage(in: persisted, for: range))
        }
    }

    @Test func dailyUpdatesRefreshOnlyAffectedDerivedKLineBucket() throws {
        let monday = StockChartFixtures.date(
            2026, 8, 3, timeZone: "America/New_York"
        )
        let tuesday = StockChartFixtures.date(
            2026, 8, 4, timeZone: "America/New_York"
        )
        let first = StockChartFixtures.point(at: monday, close: 10)
        let second = StockChartFixtures.point(at: tuesday, close: 20)
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let store = StockChartDiskStore()

        let initial = StockChartSnapshot(
            symbol: key.symbol,
            name: "VOO",
            currencyCode: "USD",
            previousClose: nil,
            points: [first, second],
            indicatorPoints: nil,
            dailyIndicatorPoints: [first, second],
            quoteUpdatedAt: second.date,
            fetchedAt: second.date,
            source: "Yahoo Finance",
            supportsCandlesticks: true
        )
        let persisted = store.merging(initial, range: .dayK, for: key, into: nil)

        let replacement = StockChartFixtures.point(at: tuesday, close: 30)
        let updated = StockChartSnapshot(
            symbol: key.symbol,
            name: "VOO",
            currencyCode: "USD",
            previousClose: nil,
            points: [replacement],
            indicatorPoints: nil,
            dailyIndicatorPoints: [replacement],
            quoteUpdatedAt: replacement.date,
            fetchedAt: replacement.date,
            source: "Yahoo Finance",
            supportsCandlesticks: true
        )
        let updatedStore = store.merging(
            updated,
            range: .dayK,
            for: key,
            into: persisted
        )

        #expect(updatedStore.series[StockChartSeriesKind.daily.rawValue]?.last?.close == 30)
        #expect(
            updatedStore.derivedSeries[StockChartSeriesKind.weekly.rawValue]?.last?.close == 30
        )
        let weekly = try #require(
            store.renderedSnapshot(from: updatedStore, range: .weekK)
        )
        #expect(weekly.points.last?.close == 30)
    }

    @Test func derivedKLinesAreCachedFromDailySource() throws {
        let first = StockChartFixtures.point(
            at: StockChartFixtures.date(2024, 8, 1, timeZone: "America/New_York"),
            close: 10
        )
        let latest = StockChartFixtures.point(
            at: StockChartFixtures.date(2026, 8, 3, timeZone: "America/New_York"),
            close: 20
        )
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let store = StockChartDiskStore()
        let snapshot = StockChartSnapshot(
            symbol: key.symbol,
            name: "VOO",
            currencyCode: "USD",
            previousClose: nil,
            points: [first, latest],
            indicatorPoints: nil,
            dailyIndicatorPoints: [first, latest],
            quoteUpdatedAt: latest.date,
            fetchedAt: latest.date,
            source: "Yahoo Finance",
            supportsCandlesticks: true
        )
        let persisted = store.merging(snapshot, range: .dayK, for: key, into: nil)
        #expect(persisted.series[StockChartSeriesKind.yearly.rawValue] == nil)
        #expect(persisted.derivedSeries[StockChartSeriesKind.yearly.rawValue] != nil)
        let yearly = try #require(
            store.renderedSnapshot(from: persisted, range: .yearK)
        )
        #expect(yearly.points.count == 2)
        #expect(yearly.points.last?.close == 20)
    }

    @Test func removeAllDeletesPersistentCacheDirectory() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let point = StockChartFixtures.point(at: StockChartFixtures.date(2026, 8, 7))
        let snapshot = StockChartSnapshot(
            symbol: key.symbol,
            name: "VOO",
            currencyCode: "USD",
            previousClose: 500,
            points: [point],
            indicatorPoints: nil,
            quoteUpdatedAt: point.date,
            fetchedAt: point.date,
            source: "Test",
            supportsCandlesticks: true
        )
        var store = makeStore(directories)
        let persisted = store.merging(snapshot, range: .dayK, for: key, into: nil)
        let didSave = store.save(persisted, for: key)
        #expect(didSave)

        store.removeAll()

        #expect(!FileManager.default.fileExists(atPath: store.persistentStoreURL(for: key).path))
        #expect(store.load(for: key) == nil)
    }

    private func samplePoints(count: Int) -> [StockChartPoint] {
        let start = StockChartFixtures.date(2026, 5, 20)
        return (0..<count).map { index in
            StockChartFixtures.point(
                at: start.addingTimeInterval(TimeInterval(index * 86_400)),
                close: 100 + Double(index)
            )
        }
    }

    private func varyingSamplePoints(count: Int) -> [StockChartPoint] {
        let start = StockChartFixtures.date(2026, 1, 1)
        return (0..<count).map { index in
            let close = 100 + Double(index) * 0.2 + sin(Double(index) / 3)
            return StockChartFixtures.point(
                at: start.addingTimeInterval(TimeInterval(index * 86_400)),
                open: close - 0.3,
                high: close + 1,
                low: close - 1,
                close: close,
                volume: 1_000 + Double(index * 10)
            )
        }
    }

    private func temporaryDirectories() throws -> (root: URL, persistent: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyToolsTests-\(UUID().uuidString)", isDirectory: true)
        let persistent = root.appendingPathComponent("Persistent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, persistent)
    }

    private func makeStore(
        _ directories: (root: URL, persistent: URL)
    ) -> StockChartDiskStore {
        StockChartDiskStore(
            persistentStoreDirectory: directories.persistent
        )
    }
}
