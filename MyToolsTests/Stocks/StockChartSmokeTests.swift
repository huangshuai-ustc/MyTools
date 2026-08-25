import Testing
@testable import MyTools

struct StockChartSmokeTests {
    @Test func chartRangesRemainStable() {
        #expect(StockChartRange.allCases.count == 7)
        #expect(StockChartRange.allCases.map(\.title) == [
            "分时", "5 日", "日K", "周K", "月K", "季K", "年K"
        ])
        #expect(StockChartRange.intraday.title == "分时")
        #expect(StockChartRange.intraday.isMinuteRange)
        #expect(StockChartRange.fiveDays.isMinuteRange)
        #expect(StockChartRange.dayK.isKLineRange)
        #expect(StockChartRange.weekK.isKLineRange)
        #expect(StockChartRange.monthK.isKLineRange)
        #expect(StockChartRange.quarterK.isKLineRange)
        #expect(StockChartRange.yearK.isKLineRange)
    }
}
