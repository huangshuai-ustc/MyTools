import Foundation
import Testing
@testable import MyTools

struct StockChartDiskStoreTests {
    @Test func unchangedRefreshSkipsWriteAndOnlyFetchTimesWaitForCheckpoint() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        var disk = makeStore(directories)
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let now = StockChartFixtures.date(2026, 8, 7)
        let points = samplePoints(count: 80)
        let snapshot = StockChartSnapshot(symbol: key.symbol, name: "VOO", currencyCode: "USD", previousClose: 10,
            points: points, indicatorPoints: nil, quoteUpdatedAt: points.last!.date, fetchedAt: now, source: "Test", supportsCandlesticks: true)
        var stored = disk.merging(snapshot, range: .dayK, for: key, into: nil)
        let firstSave = disk.save(stored, for: key, at: now)
        #expect(firstSave)
        let url = disk.partURL(for: key, part: .daily)
        let original = try Data(contentsOf: url)
        let window = StockChartStorePart.daily.coalescingWindow
        for seconds in [60, 600, window - 1] {
            stored.rangeMetadata[StockChartRange.dayK.rawValue]?.fetchedAt = now.addingTimeInterval(seconds)
            let saved = disk.save(stored, for: key, at: now.addingTimeInterval(seconds))
            #expect(saved)
            #expect(try Data(contentsOf: url) == original)
        }
        let memory = disk.load(for: key)
        #expect(memory?.rangeMetadata[StockChartRange.dayK.rawValue]?.fetchedAt == now.addingTimeInterval(window - 1))
        stored.rangeMetadata[StockChartRange.dayK.rawValue]?.fetchedAt = now.addingTimeInterval(window)
        let checkpoint = disk.save(stored, for: key, at: now.addingTimeInterval(window))
        #expect(checkpoint)
        #expect(try decodePart(url).rangeMetadata[StockChartRange.dayK.rawValue]?.fetchedAt == now.addingTimeInterval(window))
        // Same-count historical corrections are real data, and must write immediately.
        stored.series["daily"]?[0] = StockChartFixtures.point(at: points[0].date, close: 123)
        let correction = disk.save(stored, for: key, at: now.addingTimeInterval(window + 1))
        #expect(correction)
        #expect(try decodePart(url).series["daily"]?.first?.close == 123)
    }

    // AUDIT-057：分钟刷新与只动最新一根日线的刷新合并写盘；历史修正立即写入，且两份文件互不牵连。
    @Test func minuteAndLatestDailyBarChangesAreCoalescedPerPart() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        var disk = makeStore(directories)
        let key = StockChartStoreKey(market: .aShare, symbol: "600000")
        let now = StockChartFixtures.date(2026, 8, 7, hour: 10)
        var stored = disk.emptyStore(for: key)
        stored.series[StockChartSeriesKind.daily.rawValue] = samplePoints(count: 3)
        stored.series[StockChartSeriesKind.intraday.rawValue] = [StockChartFixtures.point(at: now)]
        let first = disk.save(stored, for: key, at: now)
        #expect(first)
        let dailyURL = disk.partURL(for: key, part: .daily)
        let minuteURL = disk.partURL(for: key, part: .minute)
        let originalDaily = try Data(contentsOf: dailyURL)
        let originalMinute = try Data(contentsOf: minuteURL)

        stored.series[StockChartSeriesKind.intraday.rawValue]?.append(StockChartFixtures.point(at: now.addingTimeInterval(60)))
        let lastDaily = try #require(stored.series[StockChartSeriesKind.daily.rawValue]?.last)
        stored.series[StockChartSeriesKind.daily.rawValue]?[2] = StockChartFixtures.point(at: lastDaily.date, close: 77)
        let coalesced = disk.save(stored, for: key, at: now.addingTimeInterval(60))
        #expect(coalesced)
        #expect(try Data(contentsOf: minuteURL) == originalMinute)
        #expect(try Data(contentsOf: dailyURL) == originalDaily)
        #expect(disk.pendingWriteCount == 2)
        let memory = disk.load(for: key)
        #expect(memory?.series[StockChartSeriesKind.intraday.rawValue]?.count == 2)

        let minuteWindow = StockChartStorePart.minute.coalescingWindow
        let checkpointSaved = disk.save(stored, for: key, at: now.addingTimeInterval(minuteWindow))
        #expect(checkpointSaved)
        #expect(try decodePart(minuteURL).series[StockChartSeriesKind.intraday.rawValue]?.count == 2)
        #expect(try Data(contentsOf: dailyURL) == originalDaily)

        stored.series[StockChartSeriesKind.daily.rawValue]?[0] = StockChartFixtures.point(at: samplePoints(count: 1)[0].date, close: 99)
        let correctionSaved = disk.save(stored, for: key, at: now.addingTimeInterval(minuteWindow + 20))
        #expect(correctionSaved)
        let corrected = try decodePart(dailyURL)
        #expect(corrected.series[StockChartSeriesKind.daily.rawValue]?.first?.close == 99)
        #expect(corrected.series[StockChartSeriesKind.daily.rawValue]?.last?.close == 77)
        #expect(disk.pendingWriteCount == 0)
    }

    @Test func pendingWritesAreFlushedAndWriteTimeSurvivesRelaunch() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        var disk = makeStore(directories)
        let key = StockChartStoreKey(market: .aShare, symbol: "600000")
        let now = Date()
        var stored = disk.emptyStore(for: key)
        stored.series[StockChartSeriesKind.intraday.rawValue] = [StockChartFixtures.point(at: now)]
        let first = disk.save(stored, for: key, at: now)
        #expect(first)
        let minuteURL = disk.partURL(for: key, part: .minute)
        stored.series[StockChartSeriesKind.intraday.rawValue]?.append(StockChartFixtures.point(at: now.addingTimeInterval(60)))
        let deferred = disk.save(stored, for: key, at: now.addingTimeInterval(60))
        #expect(deferred)
        #expect(try decodePart(minuteURL).series[StockChartSeriesKind.intraday.rawValue]?.count == 1)
        #expect(disk.flushPendingWrites() == 1)
        #expect(disk.pendingWriteCount == 0)
        #expect(try decodePart(minuteURL).series[StockChartSeriesKind.intraday.rawValue]?.count == 2)

        // A new process seeds the last write time from the file date, so the
        // first refresh after launch does not rewrite a fresh file.
        var relaunched = makeStore(directories)
        let relaunchedValue = relaunched.load(for: key)
        var reloaded = try #require(relaunchedValue)
        let written = try Data(contentsOf: minuteURL)
        reloaded.series[StockChartSeriesKind.intraday.rawValue]?.append(StockChartFixtures.point(at: now.addingTimeInterval(120)))
        let saved = relaunched.save(reloaded, for: key)
        #expect(saved)
        #expect(try Data(contentsOf: minuteURL) == written)
        #expect(relaunched.pendingWriteCount == 1)
    }

    @Test func failedWriteIsRetriedEvenWhenNextSnapshotIsIdentical() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        var disk = makeStore(directories)
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let url = disk.partURL(for: key, part: .daily)
        var stored = disk.emptyStore(for: key)
        let initial = disk.save(stored, for: key)
        #expect(initial)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        stored.series["daily"] = samplePoints(count: 2)
        let failed = disk.save(stored, for: key)
        #expect(!failed)
        try FileManager.default.removeItem(at: url)
        let retried = disk.save(stored, for: key)
        #expect(retried)
        #expect(try decodePart(url).series["daily"] == stored.series["daily"])
    }

    @Test func versionSixWireFormatPreservesDailyHistory() throws {
        // Schema captured from StockChartPersistedStore at commit 3da08dc.
        // Keep literal bytes: do not generate legacy fixtures with today's encoder.
        let original = Data(#"{"version":6,"market":"unitedStates","symbol":"VOO","series":{"daily":[{"date":600000000,"open":10,"high":12,"low":9,"close":11,"volume":100}]},"derivedSeries":{},"technicalIndicators":{},"technicalIndicatorCacheVersion":1,"rangeMetadata":{}}"#.utf8)
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        var store = makeStore(directories)
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let url = store.legacyStoreURL(for: key)
        try FileManager.default.createDirectory(at: directories.persistent, withIntermediateDirectories: true)
        try original.write(to: url)
        let loaded = store.load(for: key)
        #expect(loaded?.series["daily"] == [StockChartFixtures.point(at: Date(timeIntervalSinceReferenceDate: 600000000))])
        #expect(try Data(contentsOf: url.appendingPathExtension("v6.recovery")) == original)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try decodePart(store.partURL(for: key, part: .daily)).series["daily"] == loaded?.series["daily"])
    }

    // 拆分存储（v9）：v8 单文件迁移后旧文件删除，派生 K 线与指标只在内存重建、不落盘。
    @Test func versionEightSingleFileIsSplitAndDerivedDataIsNotPersisted() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let daily = varyingSamplePoints(count: 100)
        let minute = [StockChartFixtures.point(at: StockChartFixtures.date(
            2026, 8, 7, hour: 10, timeZone: "America/New_York"
        ))]
        let metadata = StockChartStoredRangeMetadata(
            symbol: key.symbol, name: "VOO", currencyCode: "USD", previousClose: 100,
            quoteUpdatedAt: daily.last!.date, fetchedAt: daily.last!.date,
            source: "Version 8", supportsCandlesticks: true, indicatorPointCount: nil,
            dailyIndicatorPointCount: daily.count
        )
        let legacy = StockChartPersistedStore(
            version: 8, market: key.market, symbol: key.symbol,
            series: [StockChartSeriesKind.daily.rawValue: daily, StockChartSeriesKind.intraday.rawValue: minute],
            rangeMetadata: [StockChartRange.dayK.rawValue: metadata, StockChartRange.intraday.rawValue: metadata]
        )
        var store = makeStore(directories)
        let url = store.legacyStoreURL(for: key)
        try FileManager.default.createDirectory(at: directories.persistent, withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)

        let loaded = store.load(for: key)
        let migrated = try #require(loaded)
        #expect(migrated.version == StockChartPersistedStore.currentVersion)
        #expect(migrated.series == legacy.series)
        #expect(migrated.technicalIndicators["daily"]?.count == daily.count)
        #expect(migrated.derivedSeries[StockChartSeriesKind.weekly.rawValue]?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("v8.recovery").path))

        let dailyData = try Data(contentsOf: store.partURL(for: key, part: .daily))
        let dailyJSON = try #require(JSONSerialization.jsonObject(with: dailyData) as? [String: Any])
        #expect(dailyJSON["technicalIndicators"] == nil)
        #expect(dailyJSON["derivedSeries"] == nil)
        let dailyPart = try decodePart(store.partURL(for: key, part: .daily))
        #expect(Set(dailyPart.series.keys) == [StockChartSeriesKind.daily.rawValue])
        #expect(Set(dailyPart.rangeMetadata.keys) == [StockChartRange.dayK.rawValue])
        let minutePart = try decodePart(store.partURL(for: key, part: .minute))
        #expect(minutePart.series[StockChartSeriesKind.intraday.rawValue] == minute)
        #expect(Set(minutePart.rangeMetadata.keys) == [StockChartRange.intraday.rawValue])

        var reopened = makeStore(directories)
        let reloadedValue = reopened.load(for: key)
        let reloaded = try #require(reloadedValue)
        #expect(reloaded.series == migrated.series)
        #expect(reloaded.technicalIndicators == migrated.technicalIndicators)
        #expect(reloaded.derivedSeries == migrated.derivedSeries)
    }

    @Test func rawMemoryCacheIsBoundedAndEvictedStocksReloadFromDisk() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        var disk = StockChartDiskStore(persistentStoreDirectory: directories.root, memoryCapacity: 2)
        let keys = (0..<8).map { StockChartStoreKey(market: .unitedStates, symbol: "TEST\($0)") }
        for key in keys {
            let saved = disk.save(disk.emptyStore(for: key), for: key)
            #expect(saved)
            #expect(disk.cachedStockCount <= 2)
        }
        let reloaded = disk.load(for: keys[0])
        #expect(reloaded?.symbol == keys[0].symbol)
        #expect(disk.cachedStockCount <= 2)
    }
    @Test func fiveDayCoverageDistinguishesOneDayCacheFromExplicitShortHistory() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let disk = makeStore(directories)
        let key = StockChartStoreKey(market: .aShare, symbol: "600000")
        let date = StockChartFixtures.date(2026, 8, 7, hour: 10)
        let points = (0..<60).map { StockChartFixtures.point(at: date.addingTimeInterval(Double($0) * 60)) }
        let snapshot = StockChartSnapshot(symbol: key.symbol, name: "Test", currencyCode: "CNY",
            previousClose: 10, points: points, indicatorPoints: points,
            quoteUpdatedAt: points.last!.date, fetchedAt: date.addingTimeInterval(3600), source: "Test", supportsCandlesticks: true)
        let oneDay = disk.merging(snapshot, range: .intraday, for: key, into: nil)
        #expect(disk.hasRequestedCoverage(in: oneDay, for: .intraday))
        #expect(!disk.hasRequestedCoverage(in: oneDay, for: .fiveDays))
        let explicitHistory = disk.merging(snapshot, range: .fiveDays, for: key, into: oneDay)
        #expect(disk.hasRequestedCoverage(in: explicitHistory, for: .fiveDays))
    }
    @Test func sameCountHistoricalCorrectionRebuildsIndicatorsAndDerivedBars() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let disk = makeStore(directories)
        let key = StockChartStoreKey(market: .unitedStates, symbol: "TEST")
        let points = varyingSamplePoints(count: 100)
        func snapshot(_ values: [StockChartPoint]) -> StockChartSnapshot {
            StockChartSnapshot(symbol: key.symbol, name: "Test", currencyCode: "USD",
                               previousClose: 99, points: values, indicatorPoints: values,
                               dailyIndicatorPoints: values, quoteUpdatedAt: values.last!.date,
                               fetchedAt: StockChartFixtures.date(2026, 8, 7), source: "Test",
                               supportsCandlesticks: true)
        }
        let first = disk.merging(snapshot(points), range: .dayK, for: key, into: nil)
        let repeated = disk.merging(snapshot(points), range: .dayK, for: key, into: first)
        #expect(first.technicalIndicators == repeated.technicalIndicators)
        #expect(first.derivedSeries == repeated.derivedSeries)
        var corrected = points
        let original = corrected[corrected.count - 2]
        corrected[corrected.count - 2] = StockChartFixtures.point(at: original.date, close: original.close + 10)
        let changed = disk.merging(snapshot(corrected), range: .dayK, for: key, into: repeated)
        #expect(changed.technicalIndicators["daily"] != repeated.technicalIndicators["daily"])
        #expect(changed.series[StockChartSeriesKind.daily.rawValue]?.count == points.count)
        #expect(changed.series[StockChartSeriesKind.daily.rawValue]?.last == points.last)
    }
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
        #expect(FileManager.default.fileExists(atPath: reader.partURL(for: key, part: .daily).path))
    }

    @Test func legacyTechnicalIndicatorsAreRebuiltFromLocalOHLCVAndNotPersisted() throws {
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
            version: 8,
            market: key.market,
            symbol: key.symbol,
            series: [StockChartSeriesKind.daily.rawValue: points],
            technicalIndicators: ["daily": legacyIndicators],
            technicalIndicatorCacheVersion: nil,
            rangeMetadata: [StockChartRange.dayK.rawValue: metadata]
        )
        var store = makeStore(directories)
        let url = store.legacyStoreURL(for: key)
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

        // Indicators are rebuilt on every load since version 9, never persisted.
        let persisted = try Data(contentsOf: store.partURL(for: key, part: .daily))
        let json = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        #expect(json["technicalIndicators"] == nil)
        #expect(try decodePart(store.partURL(for: key, part: .daily)).series["daily"] == points)
    }

    @Test func unsupportedPersistentStoreVersionIsIgnored() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let unsupported = StockChartStoredPart(
            version: StockChartPersistedStore.currentVersion + 1,
            market: key.market,
            symbol: key.symbol,
            part: .daily,
            series: [:],
            rangeMetadata: [:]
        )
        var store = makeStore(directories)
        let url = store.partURL(for: key, part: .daily)
        try FileManager.default.createDirectory(
            at: directories.persistent,
            withIntermediateDirectories: true
        )
        let original = try JSONEncoder().encode(unsupported)
        try original.write(to: url, options: .atomic)

        #expect(store.load(for: key) == nil)
        #expect(try Data(contentsOf: url) == original)
        let saved = store.save(store.emptyStore(for: key), for: key)
        #expect(!saved)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: [6, 7]) func legacyCacheMigratesWithoutDiscardingLocalChart(version: Int) throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let regular = [StockChartFixtures.point(at: StockChartFixtures.date(
            2026, 8, 7, hour: 10, timeZone: "America/New_York"
        ))]
        let preMarket = [StockChartFixtures.point(at: StockChartFixtures.date(
            2026, 8, 7, hour: 8, timeZone: "America/New_York"
        ))]
        let boundary = StockChartFixtures.point(at: StockChartFixtures.date(
            2026, 8, 7, hour: 16, timeZone: "America/New_York"
        ))
        let daily = [StockChartFixtures.point(at: StockChartFixtures.date(2020, 1, 2))]
        let metadata = StockChartStoredRangeMetadata(
            symbol: key.symbol,
            name: "VOO",
            currencyCode: "USD",
            previousClose: 100,
            preMarketPoints: preMarket,
            quoteUpdatedAt: regular[0].date,
            fetchedAt: regular[0].date,
            source: "Version 7",
            supportsCandlesticks: true,
            indicatorPointCount: regular.count
        )
        let legacy = StockChartPersistedStore(
            version: version,
            market: key.market,
            symbol: key.symbol,
            series: [StockChartSeriesKind.intraday.rawValue: regular + (version == 6 ? [boundary] : []),
                     StockChartSeriesKind.daily.rawValue: daily],
            rangeMetadata: [StockChartRange.intraday.rawValue: metadata,
                            StockChartRange.dayK.rawValue: StockChartStoredRangeMetadata(
                                symbol: key.symbol, name: "VOO", currencyCode: "USD", previousClose: 100,
                                quoteUpdatedAt: boundary.date, fetchedAt: boundary.date,
                                source: "Daily", supportsCandlesticks: true, indicatorPointCount: nil)]
        )
        var store = makeStore(directories)
        let url = store.legacyStoreURL(for: key)
        try FileManager.default.createDirectory(
            at: directories.persistent,
            withIntermediateDirectories: true
        )
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: url, options: .atomic)

        let loaded = store.load(for: key)
        let migrated = try #require(loaded)
        #expect(migrated.version == StockChartPersistedStore.currentVersion)
        #expect(migrated.series[StockChartSeriesKind.intraday.rawValue] == regular)
        #expect(migrated.series[StockChartSeriesKind.preMarketMinute.rawValue] == preMarket)
        #expect(migrated.series[StockChartSeriesKind.daily.rawValue] == daily)
        if version == 6 {
            #expect(migrated.series[StockChartSeriesKind.postMarketMinute.rawValue] == [boundary])
        }
        #expect(try Data(contentsOf: url.appendingPathExtension("v\(version).recovery")) == original)
        var reopened = makeStore(directories)
        let reloadedValue = reopened.load(for: key)
        let reloaded = try #require(reloadedValue)
        #expect(reloaded.series == migrated.series)
        #expect(store.renderedSnapshot(from: migrated, range: .intraday) != nil)
    }

    @Test func corruptCacheIsPreservedEvenWhenFreshQuotesArrive() throws {
        let directories = try temporaryDirectories()
        defer { try? FileManager.default.removeItem(at: directories.root) }
        var store = makeStore(directories)
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let url = store.legacyStoreURL(for: key)
        try FileManager.default.createDirectory(at: directories.persistent, withIntermediateDirectories: true)
        let original = Data("{\"version\":8,\"series\":".utf8)
        try original.write(to: url)
        let loaded = store.load(for: key)
        #expect(loaded == nil)
        let saved = store.save(store.emptyStore(for: key), for: key)
        #expect(!saved)
        #expect(try Data(contentsOf: url) == original)
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

    @Test func minuteCacheKeepsSevenTradingDaysForEveryUSSession() throws {
        let days = [3, 4, 5, 6, 7, 10, 11, 12]
        let regular = days.map {
            StockChartFixtures.point(at: StockChartFixtures.date(
                2026, 8, $0, hour: 10, timeZone: "America/New_York"
            ))
        }
        let preMarket = days.map {
            StockChartFixtures.point(at: StockChartFixtures.date(
                2026, 8, $0, hour: 8, timeZone: "America/New_York"
            ))
        }
        let postMarket = days.map {
            StockChartFixtures.point(at: StockChartFixtures.date(
                2026, 8, $0, hour: 17, timeZone: "America/New_York"
            ))
        }
        let snapshot = StockChartSnapshot(
            symbol: "VOO",
            name: "VOO",
            currencyCode: "USD",
            previousClose: 100,
            points: regular,
            preMarketPoints: preMarket,
            postMarketPoints: postMarket,
            indicatorPoints: regular,
            quoteUpdatedAt: postMarket.last!.date,
            fetchedAt: postMarket.last!.date,
            source: "Test",
            supportsCandlesticks: true
        )
        let key = StockChartStoreKey(market: .unitedStates, symbol: "VOO")
        let store = StockChartDiskStore()
        let persisted = store.merging(snapshot, range: .fiveDays, for: key, into: nil)

        #expect(persisted.series[StockChartSeriesKind.intraday.rawValue]?.count == 7)
        #expect(persisted.series[StockChartSeriesKind.preMarketMinute.rawValue]?.count == 7)
        #expect(persisted.series[StockChartSeriesKind.postMarketMinute.rawValue]?.count == 7)
        #expect(persisted.series[StockChartSeriesKind.intraday.rawValue]?.first?.date == regular[1].date)

        let rendered = try #require(
            store.renderedSnapshot(from: persisted, range: .fiveDays)
        )
        #expect(rendered.preMarketPoints == [preMarket.last!])
        #expect(rendered.postMarketPoints == [postMarket.last!])
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

        for part in StockChartStorePart.allCases {
            #expect(!FileManager.default.fileExists(atPath: store.partURL(for: key, part: part).path))
        }
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

    private func decodePart(_ url: URL) throws -> StockChartStoredPart {
        try JSONDecoder().decode(StockChartStoredPart.self, from: Data(contentsOf: url))
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
