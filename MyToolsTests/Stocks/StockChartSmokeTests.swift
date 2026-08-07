import Testing
@testable import MyTools

struct StockChartSmokeTests {
    @Test func chartRangesRemainStable() {
        #expect(StockChartRange.allCases.count == 8)
        #expect(StockChartRange.intraday.title == "分时")
        #expect(StockChartRange.sinceInception.title == "成立以来")
    }
}
