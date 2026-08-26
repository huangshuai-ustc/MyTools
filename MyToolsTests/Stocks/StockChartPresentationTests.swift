import Foundation
import Testing
@testable import MyTools

struct StockChartPresentationTests {
    @Test func displayModeCompatibilityKeepsOnlyComposablePriceLayers() {
        #expect(StockChartDisplayMode.line.isCompatible(with: .movingAverage))
        #expect(StockChartDisplayMode.candlestick.isCompatible(with: .bollingerBands))
        #expect(!StockChartDisplayMode.line.isCompatible(with: .candlestick))
        #expect(!StockChartDisplayMode.line.isCompatible(with: .volume))
        #expect(!StockChartDisplayMode.macd.isCompatible(with: .rsi))
    }

    @Test func extendedHoursCompatibilityFollowsCurrentMarketSession() {
        #expect(!StockChartDisplayMode.preMarket.isCompatible(
            with: .line,
            session: .preMarket
        ))
        #expect(StockChartDisplayMode.preMarket.isCompatible(
            with: .line,
            session: .regular
        ))
        #expect(!StockChartDisplayMode.postMarket.isCompatible(
            with: .line,
            session: .regular
        ))
        #expect(StockChartDisplayMode.isCompatibleSet(
            [.preMarket, .line, .postMarket],
            session: .postMarket
        ))
        #expect(!StockChartDisplayMode.isCompatibleSet(
            [.preMarket, .line],
            session: .preMarket
        ))
        #expect(StockChartDisplayMode.isCompatibleSet(
            [.preMarket, .line],
            session: .regular
        ))
        #expect(!StockChartDisplayMode.isCompatibleSet(
            [.preMarket, .line, .postMarket],
            session: .regular
        ))
        #expect(!StockChartDisplayMode.isCompatibleSet(
            [.preMarket, .postMarket],
            session: .postMarket
        ))
    }

    @Test func defaultDisplayModesAlwaysStartWithTrendLine() {
        #expect(StockChartDisplayMode.defaultModes(for: .preMarket) == [.line])
        #expect(StockChartDisplayMode.defaultModes(for: .regular) == [.line])
        #expect(StockChartDisplayMode.defaultModes(for: .postMarket) == [.line])
        #expect(StockChartDisplayMode.defaultModes(for: .closed) == [.line])
        #expect(
            StockChartDisplayMode.defaultModes(
                for: .dayK,
                session: .closed
            ) == [.line]
        )
        #expect(
            StockChartDisplayMode.defaultModes(
                for: .fiveDays,
                session: .postMarket
            ) == [.line]
        )
        let snapshot = makeSnapshot(
            points: [point(day: 7)],
            preMarketPoints: [point(day: 7, hour: 9, minute: 20)]
        )
        #expect(!StockChartPresentation.isModeAvailable(
            .preMarket,
            in: snapshot,
            range: .fiveDays,
            market: .unitedStates
        ))
    }

    @Test func extendedHoursChartModesAreOnlyAvailableForUSStocks() {
        let snapshot = makeSnapshot(
            points: [point(day: 7)],
            preMarketPoints: [point(day: 7, hour: 9, minute: 20)],
            postMarketPoints: [point(day: 7, hour: 16)]
        )

        #expect(StockChartPresentation.isModeAvailable(
            .preMarket,
            in: snapshot,
            range: .intraday,
            market: .unitedStates
        ))
        #expect(StockChartPresentation.isModeAvailable(
            .postMarket,
            in: snapshot,
            range: .intraday,
            market: .unitedStates
        ))
        #expect(!StockChartPresentation.isModeAvailable(
            .preMarket,
            in: snapshot,
            range: .intraday,
            market: .aShare
        ))
        #expect(!StockChartPresentation.isModeAvailable(
            .postMarket,
            in: snapshot,
            range: .intraday,
            market: .hongKong
        ))
    }

    @Test func minuteRangesUseDenseIndexDomainInsteadOfWallClockGaps() {
        let points = [
            point(day: 7, hour: 9, minute: 30),
            point(day: 7, hour: 11, minute: 30),
            point(day: 7, hour: 13),
            point(day: 7, hour: 15)
        ]

        let presentation = makePresentation(points: points, range: .intraday)

        #expect(presentation.plotPoints.map(\.x) == [0, 1, 2, 3])
        #expect(presentation.xDomain == 0...3)
        #expect(presentation.xAxisValues(isExpanded: false).first == 0)
        #expect(presentation.xAxisValues(isExpanded: false).last == 3)
    }

    @Test func kLineRangesUseDenseIndexDomainAcrossTradingBreaks() {
        let points = [
            point(day: 1, close: 100),
            point(day: 4, close: 101),
            point(day: 7, close: 102)
        ]

        let presentation = makePresentation(points: points, range: .dayK)

        #expect(presentation.plotPoints.map(\.x) == [0, 1, 2])
        #expect(presentation.xDomain == 0...2)
        #expect(presentation.xAxisValues(isExpanded: false).first == 0)
        #expect(presentation.xAxisValues(isExpanded: false).last == 2)
    }

    @Test func shortKLineHistoryUsesAllAvailableBarsAsDefaultWindow() {
        let points = [
            point(day: 24, close: 580),
            point(day: 25, close: 590),
            point(day: 26, close: 607)
        ]

        for range in [
            StockChartRange.dayK,
            .weekK,
            .monthK,
            .quarterK,
            .yearK
        ] {
            let presentation = makePresentation(points: points, range: range)
            #expect(presentation.defaultVisibleXDomain(isExpanded: false) == presentation.xDomain)
        }
    }

    @Test func closestPlotPointUsesSortedCoordinatesAndVisibleViewport() throws {
        let presentation = makePresentation(
            points: [
                point(day: 1, close: 100),
                point(day: 3, close: 103),
                point(day: 5, close: 105)
            ],
            range: .dayK
        )
        let points = presentation.plotPoints
        let middle = try #require(
            presentation.plotPoint(closestTo: points[1].x)
        )
        #expect(middle.point.close == 103)
        #expect(
            presentation.selectedPoint(at: points[1].point.date)?.close == 103
        )

        let visibleDomain = points[1].x...points[2].x
        let clamped = try #require(
            presentation.plotPoint(
                closestTo: points[0].x,
                in: visibleDomain
            )
        )
        #expect(clamped.point.close == 103)

        let visibleData = presentation.visibleData(in: visibleDomain)
        #expect(visibleData.plotPoints.map(\.point.close) == [103, 105])
    }

    @Test func intradayPreMarketAndRegularPointsShareTheFullChartDomain() {
        let preMarket = [
            point(
                day: 7,
                hour: 8,
                close: 98,
                timeZone: "America/New_York"
            ),
            point(
                day: 7,
                hour: 9,
                close: 99,
                timeZone: "America/New_York"
            )
        ]
        let regular = [
            point(
                day: 7,
                hour: 9,
                minute: 30,
                close: 100,
                timeZone: "America/New_York"
            ),
            point(
                day: 7,
                hour: 12,
                close: 101,
                timeZone: "America/New_York"
            ),
            point(
                day: 7,
                hour: 16,
                close: 102,
                timeZone: "America/New_York"
            )
        ]
        let presentation = makePresentation(
            stock: StockHolding(market: .unitedStates, symbol: "VOO"),
            points: regular,
            preMarketPoints: preMarket,
            range: .intraday,
            displayModes: [.line, .preMarket]
        )

        #expect(presentation.preMarketPlotPoints.map(\.x) == [0, 1])
        #expect(presentation.plotPoints.map(\.x) == [2, 3, 4])
        #expect(presentation.xDomain == 0...4)
        #expect(presentation.xAxisValues(isExpanded: false).first == 0)
        #expect(presentation.xAxisValues(isExpanded: false).last == 4)
        #expect(presentation.yDomain.lowerBound < 98)
        #expect(presentation.yDomain.upperBound > 102)

        let preMarketOnly = makePresentation(
            stock: StockHolding(market: .unitedStates, symbol: "VOO"),
            points: regular,
            preMarketPoints: preMarket,
            range: .intraday,
            displayModes: [.preMarket]
        )
        #expect(preMarketOnly.xDomain == 0...1)
        #expect(preMarketOnly.xAxisValues(isExpanded: false) == [0, 1])
        #expect(StockChartDisplayMode.preMarket.isCompatible(with: .line))
        #expect(!StockChartDisplayMode.preMarket.isCompatible(with: .volume))
    }

    @Test func minuteChartDoesNotDrawIndicatorWarmupOrExtendedHoursAsRegularData() throws {
        let regular = [
            point(
                day: 7,
                hour: 9,
                minute: 30,
                close: 100,
                timeZone: "America/New_York"
            ),
            point(
                day: 7,
                hour: 10,
                close: 101,
                timeZone: "America/New_York"
            )
        ]
        let preMarket = [
            point(
                day: 7,
                hour: 8,
                close: 98,
                timeZone: "America/New_York"
            )
        ]
        let warmup = [
            point(
                day: 6,
                hour: 16,
                close: 96,
                timeZone: "America/New_York"
            ),
            point(
                day: 7,
                hour: 8,
                close: 98,
                timeZone: "America/New_York"
            )
        ] + regular
        let snapshot = makeSnapshot(
            points: regular,
            preMarketPoints: preMarket,
            indicatorPoints: warmup
        )

        let regularOnly = StockChartPresentation(
            snapshot: snapshot,
            stock: StockHolding(market: .unitedStates, symbol: "VOO"),
            range: .intraday,
            displayModes: [.line]
        )
        #expect(regularOnly.plotPoints.map(\.point.date) == regular.map(\.date))
        #expect(regularOnly.plotPoints.map(\.x) == [0, 1])
        #expect(regularOnly.preMarketPlotPoints.isEmpty)

        let combined = StockChartPresentation(
            snapshot: snapshot,
            stock: StockHolding(market: .unitedStates, symbol: "VOO"),
            range: .intraday,
            displayModes: [.preMarket, .line]
        )
        #expect(combined.preMarketPlotPoints.map(\.x) == [0])
        #expect(combined.plotPoints.map(\.x) == [1, 2])
        #expect(combined.plotPoints.first?.point.date == regular.first?.date)
        #expect(combined.xDomain == 0...2)
    }

    @Test func visibleDataIsSharedByChartLayersAndYAxis() {
        let points = [
            point(day: 7, hour: 9, minute: 30, close: 100),
            point(day: 7, hour: 10, close: 101),
            point(day: 7, hour: 11, close: 102)
        ]
        let presentation = makePresentation(
            points: points,
            range: .intraday,
            displayModes: [.line]
        )
        let visible = presentation.visibleData(in: 1...2)

        #expect(visible.plotPoints.map(\.x) == [1, 2])
        #expect(visible.preMarketPlotPoints.isEmpty)
        #expect(visible.postMarketPlotPoints.isEmpty)
        #expect(visible.plotPointCount == 2)
        #expect(presentation.yDomain(for: visible) == presentation.yDomain(for: 1...2))
    }

    @Test func minuteChartYAxisUsesTheVisibleRegularSession() {
        let visible = [
            point(day: 7, hour: 9, minute: 30, close: 100),
            point(day: 7, hour: 15, close: 110)
        ]
        let history = [
            point(day: 1, hour: 9, minute: 30, close: 50),
            point(day: 2, hour: 15, close: 101),
            point(day: 3, hour: 15, close: 102),
            point(day: 4, hour: 15, close: 103),
            point(day: 5, hour: 15, close: 104),
            point(day: 7, hour: 9, minute: 30, close: 100),
            point(day: 7, hour: 15, close: 110)
        ]
        let presentation = StockChartPresentation(
            snapshot: makeSnapshot(points: visible, indicatorPoints: history),
            stock: StockHolding(market: .aShare, symbol: "600519"),
            range: .fiveDays,
            displayModes: [.line]
        )

        #expect(presentation.plotPoints.count == visible.count)
        let visibleYDomain = presentation.yDomain(
            for: presentation.defaultVisibleXDomain(isExpanded: false)
        )
        #expect(visibleYDomain.lowerBound > 90)
        #expect(visibleYDomain.upperBound < 120)
        #expect(presentation.yDomain.lowerBound > 90)
        #expect(presentation.yDomain.upperBound < 120)
    }

    @Test func visiblePointCountDrivesKLineBodyWidth() {
        #expect(StockChartPresentation.candleWidth(pointCount: 60, isExpanded: false) >
            StockChartPresentation.candleWidth(pointCount: 180, isExpanded: false))
        #expect(StockChartPresentation.candleWidth(pointCount: 60, isExpanded: false) > 5)
    }

    @Test func minuteRangesUseRecentFixedViewportWhileKLinesExposeHistoryViewport() {
        let start = StockChartFixtures.date(2025, 1, 1)
        let history = (0..<180).map { index in
            StockChartFixtures.point(
                at: start.addingTimeInterval(Double(index) * 86_400),
                close: Double(100 + index)
            )
        }

        let minutePresentation = StockChartPresentation(
            snapshot: makeSnapshot(points: history, indicatorPoints: history),
            stock: StockHolding(market: .aShare, symbol: "600519"),
            range: .fiveDays,
            displayModes: [.line]
        )
        let minuteDomain = minutePresentation.defaultVisibleXDomain(isExpanded: false)
        #expect(minuteDomain.lowerBound > minutePresentation.xDomain.lowerBound)
        #expect(minuteDomain.upperBound == minutePresentation.xDomain.upperBound)
        #expect(minutePresentation.xAxisValues(isExpanded: false) == [175, 176, 177, 178, 179])

        let kLinePresentation = StockChartPresentation(
            snapshot: makeSnapshot(points: history, indicatorPoints: history),
            stock: StockHolding(market: .aShare, symbol: "600519"),
            range: .dayK,
            displayModes: [.candlestick, .movingAverage]
        )
        let defaultDomain = kLinePresentation.defaultVisibleXDomain(isExpanded: false)
        #expect(kLinePresentation.xDomain.lowerBound < defaultDomain.lowerBound)
        #expect(defaultDomain.upperBound == kLinePresentation.xDomain.upperBound)
    }

    @Test func visibleViewportIsClampedToCompleteMinuteDomain() {
        let points = [
            point(day: 7, hour: 9, minute: 30),
            point(day: 7, hour: 15)
        ]
        let presentation = makePresentation(points: points, range: .intraday)

        #expect(presentation.clampedVisibleXDomain((-20)...100) == presentation.xDomain)
    }

    @Test func rsiPresentationRetainsBothPeriods() {
        let points = (0..<40).map { index in
            point(day: 7, hour: 9, minute: 30 + index * 3, close: Double(index + 1))
        }
        let presentation = makePresentation(
            points: points,
            range: .intraday,
            displayModes: [.rsi]
        )

        #expect(presentation.technicalPlotPoints.contains { $0.indicator.rsi14 != nil })
        #expect(presentation.technicalPlotPoints.contains { $0.indicator.rsi30 != nil })
    }

    @Test func intradayTransactionMarkerUsesPriceAndActualPlotX() throws {
        let points = [
            point(day: 7, hour: 9, minute: 30, close: 219),
            point(day: 7, hour: 10, close: 221),
            point(day: 7, hour: 10, minute: 30, close: 219),
            point(day: 7, hour: 11, close: 223)
        ]
        let preMarket = [
            point(day: 7, hour: 8, close: 218),
            point(day: 7, hour: 9, close: 219)
        ]
        var transaction = StockTransaction()
        transaction.type = .buy
        transaction.tradedAt = StockChartFixtures.date(2026, 8, 7, hour: 12)
        transaction.quantity = 1
        transaction.unitPrice = 219
        let stock = StockHolding(
            market: .aShare,
            symbol: "600519",
            transactions: [transaction]
        )
        let presentation = makePresentation(
            stock: stock,
            points: points,
            preMarketPoints: preMarket,
            range: .intraday,
            displayModes: [.line]
        )

        let marker = try #require(presentation.transactionMarkers.first)
        #expect(marker.plotX == 0)
        #expect(marker.plotPrice == 219)
        #expect(marker.date == points[0].date)
    }

    @Test func transactionMarkerConvertsDeviceDateToUSTradingDayAcrossAllRanges() throws {
        let regularPoint = StockChartFixtures.point(
            at: StockChartFixtures.date(
                2026,
                8,
                21,
                hour: 16,
                timeZone: "America/New_York"
            ),
            open: 117,
            high: 119,
            low: 116,
            close: 118
        )
        var transaction = StockTransaction()
        transaction.type = .buy
        // The user entered August 22 in Beijing. In the US market calendar
        // the plotting date is shifted to the regular session on August 21.
        let storedDate = StockChartFixtures.date(
            2026,
            8,
            22,
            hour: 12,
            timeZone: "Asia/Shanghai"
        )
        transaction.tradedAt = storedDate
        transaction.quantity = 1
        transaction.unitPrice = 121
        let stock = StockHolding(
            market: .unitedStates,
            symbol: "BABA",
            transactions: [transaction]
        )
        let snapshot = makeSnapshot(
            points: [regularPoint],
            indicatorPoints: [regularPoint]
        )
        let ranges: [StockChartRange] = [
            .intraday,
            .fiveDays,
            .dayK,
            .weekK,
            .monthK,
            .quarterK,
            .yearK
        ]

        for range in ranges {
            let presentation = StockChartPresentation(
                snapshot: snapshot,
                stock: stock,
                range: range,
                displayModes: [.line]
            )
            let marker = try #require(presentation.transactionMarkers.first)
            #expect(marker.date == regularPoint.date)
        }
        #expect(transaction.tradedAt == storedDate)
    }

    @Test func nonIntradayRSIUsesDailyReferenceSeries() throws {
        let dates = (0..<40).map {
            StockChartFixtures.date(2026, 7, 1).addingTimeInterval(Double($0) * 86_400)
        }
        let visiblePoints = dates.map { date in
            StockChartFixtures.point(at: date, close: 100)
        }
        let dailyPoints = dates.enumerated().map { index, date in
            StockChartFixtures.point(at: date, close: 100 + Double(index))
        }
        let presentation = StockChartPresentation(
            snapshot: StockChartSnapshot(
                symbol: "600519",
                name: "Example",
                currencyCode: "CNY",
                previousClose: nil,
                points: visiblePoints,
                indicatorPoints: visiblePoints,
                dailyIndicatorPoints: dailyPoints,
                quoteUpdatedAt: dates.last!,
                fetchedAt: dates.last!,
                source: "Fixture",
                supportsCandlesticks: true
            ),
            stock: StockHolding(market: .aShare, symbol: "600519"),
            range: .fiveDays,
            displayModes: [.rsi]
        )

        let latest = try #require(presentation.technicalPlotPoints.last?.indicator)
        #expect(latest.rsi14 == 100)
        #expect(latest.rsi30 == 100)
    }

    @Test func fiveDayAxisUsesEachObservedTradingDayOnce() {
        let points = [
            point(day: 3, hour: 10),
            point(day: 3, hour: 14),
            point(day: 4, hour: 10),
            point(day: 4, hour: 14),
            point(day: 5, hour: 10),
            point(day: 6, hour: 10),
            point(day: 7, hour: 10)
        ]
        let presentation = makePresentation(points: points, range: .fiveDays)

        #expect(presentation.xAxisValues(isExpanded: false) == [0, 2, 4, 5, 6])
    }

    @Test func selectedTransactionSummaryUsesQuantityWeightedAverage() {
        let date = StockChartFixtures.date(2026, 8, 7, hour: 12)
        let chartPoint = StockChartFixtures.point(at: date, close: 12)
        var firstBuy = StockTransaction()
        firstBuy.type = .buy
        firstBuy.tradedAt = date
        firstBuy.quantity = 2
        firstBuy.unitPrice = 10
        var secondBuy = StockTransaction()
        secondBuy.type = .buy
        secondBuy.tradedAt = date
        secondBuy.quantity = 1
        secondBuy.unitPrice = 16
        var sale = StockTransaction()
        sale.type = .sell
        sale.tradedAt = date
        sale.quantity = 2
        sale.unitPrice = 14
        let stock = StockHolding(
            market: .aShare,
            symbol: "600519",
            transactions: [firstBuy, secondBuy, sale]
        )
        let presentation = makePresentation(
            stock: stock,
            points: [chartPoint],
            range: .dayK
        )

        let selections = presentation.transactionSelections(at: chartPoint)

        let buy = selections.first { $0.type == .buy }
        let sell = selections.first { $0.type == .sell }
        #expect(buy?.averagePrice == 12)
        #expect(sell?.averagePrice == 14)
    }

    @Test func indicatorDomainsTakePriorityOverPriceDomain() {
        let points = (1...20).map { day in
            point(day: day, close: Double(100 + day), volume: Double(day * 1_000))
        }
        let rsi = makePresentation(
            points: points,
            range: .dayK,
            displayModes: [.line, .rsi]
        )
        let volume = makePresentation(
            points: points,
            range: .dayK,
            displayModes: [.line, .volume]
        )

        #expect(rsi.yDomain == 0...100)
        #expect(volume.yDomain.lowerBound == 0)
        #expect(volume.yDomain.upperBound == 21_600)
    }

    @Test func intradayPerformanceUsesPreviousTradingDayFromHistory() {
        let previousFriday = point(
            day: 31,
            month: 7,
            hour: 16,
            close: 100,
            timeZone: "America/New_York"
        )
        let mondayPoints = [
            point(
                day: 3,
                hour: 9,
                minute: 30,
                close: 105,
                timeZone: "America/New_York"
            ),
            point(
                day: 3,
                hour: 16,
                close: 110,
                timeZone: "America/New_York"
            )
        ]
        let snapshot = makeSnapshot(
            points: mondayPoints,
            indicatorPoints: [previousFriday] + mondayPoints,
            previousClose: 40
        )

        let performance = StockChartPresentation.rangePerformance(
            snapshot: snapshot,
            range: .intraday,
            market: .unitedStates
        )

        #expect(performance?.change == 10)
        #expect(performance?.percent == 0.1)
    }

    @Test func intradayPerformanceFallsBackToProviderPreviousClose() {
        let points = [
            point(day: 7, hour: 9, minute: 30, close: 105),
            point(day: 7, hour: 15, close: 110)
        ]
        let snapshot = makeSnapshot(
            points: points,
            indicatorPoints: points,
            previousClose: 100
        )

        let performance = StockChartPresentation.rangePerformance(
            snapshot: snapshot,
            range: .intraday,
            market: .aShare
        )

        #expect(performance?.change == 10)
        #expect(performance?.percent == 0.1)
    }

    @Test func previousCloseKeepsRegularSessionReferenceWhenPreMarketIsNewer() {
        let previousTradingDay = point(
            day: 3,
            hour: 16,
            close: 100,
            timeZone: "America/New_York"
        )
        let latestRegularPoint = point(
            day: 4,
            hour: 16,
            close: 110,
            timeZone: "America/New_York"
        )
        let currentPreMarketPoint = point(
            day: 5,
            hour: 8,
            close: 111,
            timeZone: "America/New_York"
        )
        let snapshot = makeSnapshot(
            points: [latestRegularPoint],
            preMarketPoints: [currentPreMarketPoint],
            indicatorPoints: [previousTradingDay, latestRegularPoint]
        )

        #expect(
            StockChartPresentation.intradayPreviousClose(
                snapshot: snapshot,
                market: .unitedStates
            ) == 100
        )
    }

    @Test func fiveDayPerformanceUsesTheFirstVisibleTradingDay() {
        let previousFriday = point(day: 31, month: 7, close: 90)
        let visible = [
            point(day: 3, close: 100),
            point(day: 4, close: 103),
            point(day: 5, close: 105),
            point(day: 6, close: 108),
            point(day: 7, close: 110)
        ]
        let snapshot = makeSnapshot(
            points: visible,
            indicatorPoints: [previousFriday] + visible,
            previousClose: 20
        )

        let performance = StockChartPresentation.rangePerformance(
            snapshot: snapshot,
            range: .fiveDays,
            market: .aShare
        )

        #expect(performance?.change == 10)
        #expect(performance?.percent == 0.1)
    }

    @Test func fiveDayPerformanceFallsBackToFirstVisiblePointWithoutHistory() {
        let visible = [
            point(day: 3, close: 100),
            point(day: 7, close: 110)
        ]
        let snapshot = makeSnapshot(
            points: visible,
            indicatorPoints: visible,
            previousClose: 20
        )

        let performance = StockChartPresentation.rangePerformance(
            snapshot: snapshot,
            range: .fiveDays,
            market: .aShare
        )

        #expect(performance?.change == 10)
        #expect(performance?.percent == 0.1)
    }

    @Test func kLinePerformanceUsesItsOwnVisibleWindow() {
        let visible = [
            point(day: 1, close: 80),
            point(day: 7, close: 100)
        ]
        let snapshot = makeSnapshot(
            points: visible,
            indicatorPoints: [point(day: 31, month: 7, close: 40)] + visible,
            previousClose: 10
        )
        let ranges: [StockChartRange] = [
            .dayK,
            .weekK,
            .monthK,
            .quarterK,
            .yearK
        ]

        for range in ranges {
            let performance = StockChartPresentation.rangePerformance(
                snapshot: snapshot,
                range: range,
                market: .aShare
            )
            #expect(performance?.change == 20)
            #expect(performance?.percent == 0.25)
        }
    }

    @Test func kLinePerformanceUsesVisibleWindowStart() {
        let points = [
            point(day: 1, close: 80),
            point(day: 4, close: 100),
            point(day: 7, close: 110)
        ]
        let snapshot = makeSnapshot(points: points)
        let visibleXDomain = 1.0...2.0

        let performance = StockChartPresentation.rangePerformance(
            snapshot: snapshot,
            range: .dayK,
            market: .aShare,
            visibleXDomain: visibleXDomain
        )

        #expect(performance?.change == 10)
        #expect(performance?.percent == 0.1)
    }

    @Test func availabilityUsesIndicatorHistoryRatherThanVisiblePointCount() {
        let visible = [point(day: 7)]
        let history = (1...20).map { point(day: $0) }
        let snapshot = makeSnapshot(points: visible, indicatorPoints: history)

        #expect(StockChartPresentation.isModeAvailable(.bollingerBands, in: snapshot))
        #expect(StockChartPresentation.isModeAvailable(.rsi, in: snapshot))
        #expect(StockChartPresentation.isModeAvailable(.movingAverage, in: snapshot))
    }

    @Test func minuteIndicatorsUseHistoricalWarmupAcrossTradingDays() throws {
        let firstDay = (0..<8).map { index in
            point(
                day: 7,
                hour: 9,
                minute: 30 + index * 3,
                close: 100 + Double(index)
            )
        }
        let secondDay = (0..<8).map { index in
            point(
                day: 8,
                hour: 9,
                minute: 30 + index * 3,
                close: 200 + Double(index)
            )
        }
        let snapshot = makeSnapshot(
            points: secondDay,
            indicatorPoints: firstDay + secondDay
        )
        let presentation = StockChartPresentation(
            snapshot: snapshot,
            stock: StockHolding(market: .aShare, symbol: "518880"),
            range: .intraday,
            displayModes: [.line, .movingAverage]
        )

        let firstSecondDayIndicator = try #require(
            presentation.technicalPlotPoints.first?.indicator
        )
        // The first visible bar can use the prior day's minute history for
        // MA/BOLL/RSI warm-up, while the prior bars remain undisplayed.
        #expect(firstSecondDayIndicator.movingAverage5 == 124.4)
    }

    @Test func yearlyIndicatorsUseDailyHistoryForBollingerAvailability() throws {
        let dailyPoints = (1...30).map { day in
            point(day: day, close: 100 + Double(day))
        }
        let yearlyPoint = point(day: 30, close: 130)
        let snapshot = makeSnapshot(
            points: [yearlyPoint],
            indicatorPoints: [yearlyPoint],
            dailyIndicatorPoints: dailyPoints
        )

        #expect(StockChartPresentation.isModeAvailable(
            .bollingerBands,
            in: snapshot,
            range: .yearK
        ))
        let presentation = StockChartPresentation(
            snapshot: snapshot,
            stock: StockHolding(market: .unitedStates, symbol: "VOO"),
            range: .yearK,
            displayModes: [.line, .bollingerBands]
        )
        let bollingerMiddle = try #require(
            presentation.technicalPlotPoints.last?.indicator.bollingerMiddle
        )
        #expect(bollingerMiddle > 0)
    }

    private func makePresentation(
        stock: StockHolding = StockHolding(market: .aShare, symbol: "600519"),
        points: [StockChartPoint],
        preMarketPoints: [StockChartPoint] = [],
        range: StockChartRange,
        displayModes: Set<StockChartDisplayMode> = [.line]
    ) -> StockChartPresentation {
        StockChartPresentation(
            snapshot: makeSnapshot(points: points, preMarketPoints: preMarketPoints),
            stock: stock,
            range: range,
            displayModes: displayModes
        )
    }

    private func makeSnapshot(
        points: [StockChartPoint],
        preMarketPoints: [StockChartPoint] = [],
        postMarketPoints: [StockChartPoint] = [],
        indicatorPoints: [StockChartPoint]? = nil,
        dailyIndicatorPoints: [StockChartPoint]? = nil,
        previousClose: Double? = 99
    ) -> StockChartSnapshot {
        StockChartSnapshot(
            symbol: "600519",
            name: "Example",
            currencyCode: "CNY",
            previousClose: previousClose,
            points: points,
            preMarketPoints: preMarketPoints,
            postMarketPoints: postMarketPoints,
            indicatorPoints: indicatorPoints,
            dailyIndicatorPoints: dailyIndicatorPoints,
            quoteUpdatedAt: points.last?.date ?? Date(timeIntervalSince1970: 0),
            fetchedAt: Date(timeIntervalSince1970: 0),
            source: "Fixture",
            supportsCandlesticks: true
        )
    }

    private func point(
        day: Int,
        month: Int = 8,
        hour: Int = 12,
        minute: Int = 0,
        close: Double = 100,
        volume: Double? = 1_000,
        timeZone: String = "Asia/Shanghai"
    ) -> StockChartPoint {
        StockChartFixtures.point(
            at: StockChartFixtures.date(
                2026,
                month,
                day,
                hour: hour,
                minute: minute,
                timeZone: timeZone
            ),
            open: close - 1,
            high: close + 1,
            low: close - 2,
            close: close,
            volume: volume
        )
    }
}
