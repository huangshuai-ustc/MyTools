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
            range: .oneMonth
        )

        let selections = presentation.transactionSelections(at: chartPoint)

        #expect(selections.first { $0.type == .buy }?.averagePrice == 12)
        #expect(selections.first { $0.type == .sell }?.averagePrice == 14)
    }

    @Test func indicatorDomainsTakePriorityOverPriceDomain() {
        let points = (1...20).map { day in
            point(day: day, close: Double(100 + day), volume: Double(day * 1_000))
        }
        let rsi = makePresentation(
            points: points,
            range: .oneMonth,
            displayModes: [.line, .rsi]
        )
        let volume = makePresentation(
            points: points,
            range: .oneMonth,
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

    @Test func fiveDayPerformanceIncludesTheFirstTradingDayMove() {
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

        #expect(performance?.change == 20)
        #expect(performance?.percent == 20.0 / 90.0)
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

    @Test func longerRangePerformanceUsesItsOwnVisibleWindow() {
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
            .oneMonth,
            .threeMonths,
            .oneYear,
            .fiveYears,
            .tenYears,
            .sinceInception
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

    @Test func availabilityUsesIndicatorHistoryRatherThanVisiblePointCount() {
        let visible = [point(day: 7)]
        let history = (1...20).map { point(day: $0) }
        let snapshot = makeSnapshot(points: visible, indicatorPoints: history)

        #expect(StockChartPresentation.isModeAvailable(.bollingerBands, in: snapshot))
        #expect(StockChartPresentation.isModeAvailable(.rsi, in: snapshot))
        #expect(StockChartPresentation.isModeAvailable(.movingAverage, in: snapshot))
    }

    private func makePresentation(
        stock: StockHolding = StockHolding(market: .aShare, symbol: "600519"),
        points: [StockChartPoint],
        range: StockChartRange,
        displayModes: Set<StockChartDisplayMode> = [.line]
    ) -> StockChartPresentation {
        StockChartPresentation(
            snapshot: makeSnapshot(points: points),
            stock: stock,
            range: range,
            displayModes: displayModes
        )
    }

    private func makeSnapshot(
        points: [StockChartPoint],
        indicatorPoints: [StockChartPoint]? = nil,
        previousClose: Double? = 99
    ) -> StockChartSnapshot {
        StockChartSnapshot(
            symbol: "600519",
            name: "Example",
            currencyCode: "CNY",
            previousClose: previousClose,
            points: points,
            indicatorPoints: indicatorPoints,
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
