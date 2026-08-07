import Foundation
import Testing
@testable import MyTools

struct StockTechnicalIndicatorsTests {
    @Test func movingAverageBollingerAndRSIStartAtExpectedSamples() throws {
        let points = pricePoints(count: 60) { Double($0 + 1) }

        let indicators = StockTechnicalIndicators.calculate(points)

        #expect(indicators.count == 60)
        #expect(indicators[3].movingAverage5 == nil)
        #expect(indicators[4].movingAverage5 == 3)
        #expect(indicators[18].bollingerMiddle == nil)
        #expect(indicators[19].bollingerMiddle == 10.5)
        #expect(indicators[58].movingAverage60 == nil)
        #expect(indicators[59].movingAverage60 == 30.5)
        #expect(indicators[13].rsi14 == nil)
        #expect(indicators[14].rsi14 == 100)
        #expect(try #require(indicators.last).macdLine > 0)
    }

    private func pricePoints(
        count: Int,
        close: (Int) -> Double
    ) -> [StockChartPoint] {
        let start = StockChartFixtures.date(2026, 1, 1)
        return (0..<count).map { index in
            let price = close(index)
            return StockChartFixtures.point(
                at: start.addingTimeInterval(TimeInterval(index * 86_400)),
                open: price - 0.2,
                high: price + 0.5,
                low: price - 0.5,
                close: price,
                volume: 1_000 + Double(index)
            )
        }
    }
}
