import Foundation
import Testing
@testable import MyTools

struct StockChartSeriesProcessorTests {
    @Test func latestTradingDaySkipsWeekendPlaceholder() throws {
        let friday = StockChartFixtures.date(
            2026,
            8,
            7,
            hour: 16,
            timeZone: "America/New_York"
        )
        let saturdayPlaceholder = StockChartFixtures.date(
            2026,
            8,
            8,
            hour: 12,
            timeZone: "America/New_York"
        )
        let points = [
            StockChartFixtures.point(at: friday, close: 123, volume: 10_000),
            StockChartFixtures.point(
                at: saturdayPlaceholder,
                open: 123,
                high: 123,
                low: 123,
                close: 123,
                volume: 0
            )
        ]

        let visible = StockChartSeriesProcessor.pointsOnLatestTradingDay(
            points,
            market: .unitedStates,
            at: saturdayPlaceholder
        )

        #expect(visible == [points[0]])

        let snapshot = StockChartSnapshot(
            symbol: "VOO",
            name: "Test ETF",
            currencyCode: "USD",
            previousClose: 122,
            points: points,
            indicatorPoints: nil,
            quoteUpdatedAt: points.last!.date,
            fetchedAt: saturdayPlaceholder,
            source: "Test",
            supportsCandlesticks: true
        )
        let normalized = StockChartSeriesProcessor.normalizedSnapshot(
            snapshot,
            range: .oneMonth,
            market: .unitedStates,
            at: saturdayPlaceholder
        )
        #expect(normalized?.latestPoint == points.first)
        #expect(normalized?.quoteUpdatedAt == points.first?.date)
    }

    @Test func latestTradingDaySkipsRepeatedZeroVolumePlaceholders() {
        let friday = StockChartFixtures.date(
            2026,
            8,
            7,
            hour: 16,
            timeZone: "America/New_York"
        )
        let saturday = StockChartFixtures.date(
            2026,
            8,
            8,
            hour: 12,
            timeZone: "America/New_York"
        )
        let points = [
            StockChartFixtures.point(at: friday, close: 123, volume: 10_000),
            StockChartFixtures.point(
                at: saturday,
                open: 123,
                high: 123,
                low: 123,
                close: 123,
                volume: 0
            ),
            StockChartFixtures.point(
                at: saturday.addingTimeInterval(300),
                open: 123,
                high: 123,
                low: 123,
                close: 123,
                volume: 0
            )
        ]

        #expect(
            StockChartSeriesProcessor.pointsOnLatestTradingDay(
                points,
                market: .unitedStates,
                at: saturday
            ) == [points[0]]
        )
    }

    @Test func finalSessionEndsOnlyAfterAfternoonClose() {
        let lunch = StockChartFixtures.date(2026, 8, 3, hour: 11, minute: 31)
        let close = StockChartFixtures.date(2026, 8, 3, hour: 15, minute: 1)
        let morning = StockChartFixtures.date(2026, 8, 3, hour: 11, minute: 0)
        let afternoon = StockChartFixtures.date(2026, 8, 3, hour: 14, minute: 59)

        #expect(
            !StockMarketTradingCalendar.finalSessionEnded(
                for: .aShare,
                between: morning,
                and: lunch
            )
        )
        #expect(
            StockMarketTradingCalendar.finalSessionEnded(
                for: .aShare,
                between: afternoon,
                and: close
            )
        )
        #expect(
            StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
                for: .aShare,
                at: close
            ) == StockChartFixtures.date(2026, 8, 3, hour: 15)
        )
    }

    @Test func intradayKeepsOnlyLatestTradingDay() {
        let older = StockChartFixtures.date(2026, 7, 31, hour: 15)
        let latestStart = StockChartFixtures.date(2026, 8, 3, hour: 9, minute: 30)
        let points = [
            StockChartFixtures.point(at: older),
            StockChartFixtures.point(at: latestStart),
            StockChartFixtures.point(at: latestStart.addingTimeInterval(180))
        ]

        let visible = StockChartSeriesProcessor.visiblePoints(
            from: points,
            for: .intraday,
            market: .aShare
        )

        #expect(visible.map(\.date) == Array(points.suffix(2)).map(\.date))
    }

    @Test func aShareIntradaySeparatesCallAuctionFromRegularSession() {
        let auction = StockChartFixtures.date(2026, 8, 3, hour: 9, minute: 20)
        let open = StockChartFixtures.date(2026, 8, 3, hour: 9, minute: 30)
        let close = StockChartFixtures.date(2026, 8, 3, hour: 15)
        let points = [
            StockChartFixtures.point(at: auction, close: 99),
            StockChartFixtures.point(at: open, close: 100),
            StockChartFixtures.point(at: close, close: 101)
        ]

        #expect(
            StockChartSeriesProcessor.preMarketSessionPoints(points, market: .aShare)
                .map(\.date) == [auction]
        )
        #expect(
            StockChartSeriesProcessor.regularSessionPoints(points, market: .aShare)
                .map(\.date) == [open, close]
        )
    }

    @Test func currentSessionSummaryAggregatesMinuteOHLCAndVolume() {
        let points = [
            StockChartFixtures.point(
                at: StockChartFixtures.date(
                    2026,
                    8,
                    7,
                    hour: 9,
                    minute: 30,
                    timeZone: "America/New_York"
                ),
                open: 96,
                high: 97,
                low: 95,
                close: 96.5,
                volume: 100
            ),
            StockChartFixtures.point(
                at: StockChartFixtures.date(
                    2026,
                    8,
                    7,
                    hour: 10,
                    timeZone: "America/New_York"
                ),
                open: 96.5,
                high: 98,
                low: 89,
                close: 90,
                volume: 250
            ),
            StockChartFixtures.point(
                at: StockChartFixtures.date(
                    2026,
                    8,
                    7,
                    hour: 16,
                    timeZone: "America/New_York"
                ),
                open: 90,
                high: 91,
                low: 90,
                close: 90.8,
                volume: 50
            )
        ]

        let summary = StockChartSeriesProcessor.currentSessionSummary(
            from: points,
            market: .unitedStates,
            at: StockChartFixtures.date(2026, 8, 7, hour: 18, timeZone: "America/New_York")
        )

        #expect(summary?.open == 96)
        #expect(summary?.high == 98)
        #expect(summary?.low == 89)
        #expect(summary?.close == 90.8)
        #expect(summary?.volume == 400)
    }

    @Test func unitedStatesPreMarketIsAnActiveRefreshSession() {
        let preMarket = StockChartFixtures.date(
            2026,
            8,
            7,
            hour: 6,
            timeZone: "America/New_York"
        )
        #expect(!StockMarketTradingCalendar.isOpen(.unitedStates, at: preMarket))
        #expect(StockMarketTradingCalendar.isPreMarketOpen(.unitedStates, at: preMarket))
        #expect(StockMarketTradingCalendar.isSessionActive(.unitedStates, at: preMarket))
    }

    @Test func marketSessionsAreMutuallyExclusiveAcrossTheTradingDay() {
        let aSharePost = StockChartFixtures.date(2026, 8, 7, hour: 15, minute: 1)
        #expect(StockMarketTradingCalendar.session(for: .aShare, at: aSharePost) == .postMarket)

        let unitedStatesPost = StockChartFixtures.date(
            2026,
            8,
            7,
            hour: 17,
            timeZone: "America/New_York"
        )
        #expect(
            StockMarketTradingCalendar.session(for: .unitedStates, at: unitedStatesPost)
                == .postMarket
        )
        #expect(!StockMarketTradingCalendar.isOpen(.unitedStates, at: unitedStatesPost))
    }

    @Test func fiveDaysKeepsFiveObservedTradingDaysWithoutCalendarGaps() {
        let dates = [
            (2026, 7, 27), (2026, 7, 28), (2026, 7, 29), (2026, 7, 30),
            (2026, 7, 31), (2026, 8, 3), (2026, 8, 4)
        ].map { StockChartFixtures.date($0.0, $0.1, $0.2) }
        let points = dates.map { StockChartFixtures.point(at: $0) }

        let visible = StockChartSeriesProcessor.visiblePoints(
            from: points,
            for: .fiveDays,
            market: .aShare
        )

        #expect(visible.map(\.date) == Array(dates.suffix(5)))
    }

    @Test func indicatorSeriesIncludesSixtyPointsBeforeVisibleRange() {
        let start = StockChartFixtures.date(2026, 1, 1)
        let allPoints = (0..<100).map { index in
            StockChartFixtures.point(
                at: start.addingTimeInterval(TimeInterval(index * 86_400)),
                close: Double(index)
            )
        }
        let visible = Array(allPoints.suffix(20))

        let indicators = StockChartSeriesProcessor.indicatorPoints(
            from: allPoints,
            visiblePoints: visible,
            range: .oneMonth
        )

        #expect(indicators.count == 80)
        #expect(indicators.first?.date == allPoints[20].date)
        #expect(indicators.last?.date == allPoints.last?.date)
    }

    @Test func incomingMinuteReplacesExistingMinuteBucket() {
        let minute = StockChartFixtures.date(2026, 8, 3, hour: 10)
        let existing = StockChartFixtures.point(at: minute.addingTimeInterval(5), close: 10)
        let replacement = StockChartFixtures.point(at: minute.addingTimeInterval(55), close: 12)

        let merged = StockChartSeriesProcessor.mergedPoints(
            [existing],
            with: [replacement],
            kind: .intraday,
            market: .aShare
        )

        #expect(merged == [replacement])
    }

    @Test func threeMinuteResamplingPreservesOHLCAndVolume() {
        let bucket = Date(timeIntervalSince1970: 1_800_000_000)
        let points = [
            StockChartFixtures.point(
                at: bucket,
                open: 10,
                high: 11,
                low: 9,
                close: 10.5,
                volume: 100
            ),
            StockChartFixtures.point(
                at: bucket.addingTimeInterval(60),
                open: 10.5,
                high: 13,
                low: 10,
                close: 12,
                volume: 200
            ),
            StockChartFixtures.point(
                at: bucket.addingTimeInterval(120),
                open: 12,
                high: 12.5,
                low: 8,
                close: 9,
                volume: 300
            )
        ]

        let result = StockChartSeriesProcessor.resampledIntradayPoints(
            points,
            targetMinutes: 3
        )

        #expect(result.count == 1)
        #expect(result.first?.date == points.last?.date)
        #expect(result.first?.open == 10)
        #expect(result.first?.high == 13)
        #expect(result.first?.low == 8)
        #expect(result.first?.close == 9)
        #expect(result.first?.volume == 600)
    }

    @Test func weeklyAggregationUsesFirstOpenLastCloseAndSummedVolume() {
        let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
        let points = [
            StockChartFixtures.point(
                at: StockChartFixtures.date(
                    2026, 8, 3, timeZone: "America/New_York"
                ),
                open: 10,
                high: 12,
                low: 9,
                close: 11,
                volume: 100
            ),
            StockChartFixtures.point(
                at: StockChartFixtures.date(
                    2026, 8, 7, timeZone: "America/New_York"
                ),
                open: 11,
                high: 14,
                low: 10,
                close: 13,
                volume: 250
            )
        ]

        let weekly = StockChartSeriesProcessor.weeklyPoints(
            from: points,
            calendar: calendar
        )

        #expect(weekly.count == 1)
        #expect(weekly.first?.open == 10)
        #expect(weekly.first?.high == 14)
        #expect(weekly.first?.low == 9)
        #expect(weekly.first?.close == 13)
        #expect(weekly.first?.volume == 350)
    }
}
