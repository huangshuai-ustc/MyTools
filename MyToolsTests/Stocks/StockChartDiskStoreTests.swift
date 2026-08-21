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
            range: .oneMonth,
            for: key,
            into: nil
        )

        writer.save(persisted, for: key)

        var reader = makeStore(directories)
        let loadedStore = reader.load(for: key)
        let reloaded = try #require(loadedStore)
        let rendered = try #require(
            reader.renderedSnapshot(from: reloaded, range: .oneMonth)
        )
        #expect(rendered.symbol == key.symbol)
        #expect(rendered.points == StockChartSeriesProcessor.visiblePoints(
            from: points,
            for: .oneMonth,
            market: key.market
        ))
        #expect(rendered.indicatorPoints?.count == 80)
        #expect(rendered.dailyIndicatorPoints?.count == 80)
        #expect(FileManager.default.fileExists(atPath: reader.persistentStoreURL(for: key).path))
    }

    @Test func legacyRangeCacheMigratesIntoPersistentTimeSeriesFile() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .aShare, symbol: "600519")
        let points = samplePoints(count: 30)
        let snapshot = StockChartSnapshot(
            symbol: key.symbol,
            name: "示例股票",
            currencyCode: "CNY",
            previousClose: 100,
            points: points,
            indicatorPoints: nil,
            quoteUpdatedAt: points.last!.date,
            fetchedAt: StockChartFixtures.date(2026, 8, 7),
            source: "Legacy",
            supportsCandlesticks: true
        )
        let legacyEntry = StockChartLegacyCacheEntry(
            market: key.market,
            symbol: key.symbol,
            range: .oneMonth,
            snapshot: snapshot
        )
        var store = makeStore(directories)
        let legacyURL = store.legacyCacheURL(for: StockChartCacheKey(
            market: key.market,
            symbol: key.symbol,
            range: .oneMonth
        ))
        try FileManager.default.createDirectory(
            at: directories.legacy,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(legacyEntry).write(to: legacyURL, options: .atomic)

        let loadedStore = store.load(for: key)
        let migrated = try #require(loadedStore)

        #expect(migrated.version == StockChartPersistedStore.currentVersion)
        #expect(migrated.series[StockChartSeriesKind.daily.rawValue] == points)
        #expect(FileManager.default.fileExists(atPath: store.persistentStoreURL(for: key).path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
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
    }

    @Test func oldMinuteMetadataWithoutIndicatorCountRequiresRefresh() {
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

    @Test func longerRangesAreClampedToTheInceptionSeries() throws {
        let inception = StockChartFixtures.date(2023, 1, 3)
        let oldWeekly = StockChartFixtures.date(2015, 1, 6)
        let latest = StockChartFixtures.date(2026, 8, 7)
        let monthlyPoints = [
            StockChartFixtures.point(at: inception, close: 20),
            StockChartFixtures.point(at: latest, close: 40)
        ]
        let weeklyPoints = [
            StockChartFixtures.point(at: oldWeekly, close: 10),
            StockChartFixtures.point(at: inception, close: 20),
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
            series: [
                StockChartSeriesKind.monthly.rawValue: monthlyPoints,
                StockChartSeriesKind.weekly.rawValue: weeklyPoints
            ],
            rangeMetadata: [StockChartRange.tenYears.rawValue: metadata]
        )

        let store = StockChartDiskStore()
        let rendered = try #require(
            store.renderedSnapshot(from: persisted, range: .tenYears)
        )

        #expect(rendered.points.map(\.date) == [inception, latest])
    }

    @Test func yearKUsesYearlySeriesAsTheInceptionBoundary() throws {
        let earliestYear = StockChartFixtures.date(2010, 1, 4)
        let recentMonth = StockChartFixtures.date(2024, 1, 2)
        let latest = StockChartFixtures.date(2026, 8, 7)
        let yearlyPoints = [
            StockChartFixtures.point(at: earliestYear, close: 10),
            StockChartFixtures.point(at: latest, close: 40)
        ]
        let monthlyPoints = [
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
            series: [
                StockChartSeriesKind.yearly.rawValue: yearlyPoints,
                StockChartSeriesKind.monthly.rawValue: monthlyPoints
            ],
            rangeMetadata: [StockChartRange.yearK.rawValue: metadata]
        )

        let store = StockChartDiskStore()
        let rendered = try #require(
            store.renderedSnapshot(from: persisted, range: .yearK)
        )

        #expect(rendered.points.map(\.date) == [earliestYear, latest])
    }

    @Test func yearKCacheFromLimitedProviderRequiresCompleteHistoryRefresh() {
        let point = StockChartFixtures.point(at: StockChartFixtures.date(2026, 8, 7))
        let metadata = StockChartStoredRangeMetadata(
            symbol: "VOO",
            name: "Vanguard S&P 500 ETF",
            currencyCode: "USD",
            previousClose: nil,
            quoteUpdatedAt: point.date,
            fetchedAt: point.date,
            source: "腾讯证券",
            supportsCandlesticks: true,
            indicatorPointCount: nil,
            historyCoverageRevision: 0
        )
        let persisted = StockChartPersistedStore(
            version: StockChartPersistedStore.currentVersion,
            market: .unitedStates,
            symbol: "VOO",
            series: [StockChartSeriesKind.yearly.rawValue: [point]],
            rangeMetadata: [StockChartRange.yearK.rawValue: metadata]
        )

        #expect(!StockChartDiskStore().hasRequestedCoverage(in: persisted, for: .yearK))
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
        #expect(updatedStore.series[StockChartSeriesKind.weekly.rawValue]?.last?.close == 30)
    }

    @Test func incompleteDerivedSeriesIsRebuiltFromCanonicalDailySource() throws {
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
        var persisted = store.merging(snapshot, range: .dayK, for: key, into: nil)
        persisted.series[StockChartSeriesKind.yearly.rawValue] = [first]

        let repaired = store.merging(
            snapshot,
            range: .dayK,
            for: key,
            into: persisted
        )

        #expect(repaired.series[StockChartSeriesKind.yearly.rawValue]?.count == 2)
        #expect(repaired.series[StockChartSeriesKind.yearly.rawValue]?.last?.close == 20)
    }

    @Test func removeAllDeletesPersistentAndLegacyCacheDirectories() throws {
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
        let persisted = store.merging(snapshot, range: .oneMonth, for: key, into: nil)
        let didSave = store.save(persisted, for: key)
        #expect(didSave)
        let legacyURL = store.legacyCacheURL(for: StockChartCacheKey(
            market: key.market,
            symbol: key.symbol,
            range: .oneMonth
        ))
        try FileManager.default.createDirectory(at: directories.legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyURL)

        store.removeAll()

        #expect(!FileManager.default.fileExists(atPath: store.persistentStoreURL(for: key).path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
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

    private func temporaryDirectories() throws -> (root: URL, persistent: URL, legacy: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyToolsTests-\(UUID().uuidString)", isDirectory: true)
        let persistent = root.appendingPathComponent("Persistent", isDirectory: true)
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, persistent, legacy)
    }

    private func makeStore(
        _ directories: (root: URL, persistent: URL, legacy: URL)
    ) -> StockChartDiskStore {
        StockChartDiskStore(
            persistentStoreDirectory: directories.persistent,
            legacyCacheDirectory: directories.legacy
        )
    }
}
