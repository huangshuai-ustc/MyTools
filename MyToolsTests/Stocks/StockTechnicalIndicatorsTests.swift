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
        #expect(indicators[29].rsi30 == nil)
        #expect(indicators[30].rsi30 == 100)
        #expect(try #require(indicators.last).macdLine > 0)
    }

    @Test func advancedIndicatorsProduceExpectedTrendAndVolumeSignals() throws {
        let indicators = StockTechnicalIndicators.calculate(
            pricePoints(count: 120) { Double($0 + 1) }
        )
        let latest = try #require(indicators.last)

        #expect(try #require(latest.stochasticK) > 90)
        #expect(try #require(latest.stochasticD) > 90)
        #expect(latest.stochasticJ != nil)
        #expect(try #require(latest.williamsR) > -10)
        #expect(try #require(latest.commodityChannelIndex) > 100)
        #expect(try #require(latest.positiveDirectionalIndex) > 0)
        #expect(try #require(latest.negativeDirectionalIndex) == 0)
        #expect(try #require(latest.averageDirectionalIndex) > 90)
        #expect(latest.momentum == 10)
        #expect(latest.momentumAverage == 10)
        #expect(try #require(latest.trix) > 0)
        #expect(latest.trixSignal != nil)
        #expect(try #require(latest.onBalanceVolume) > 0)
        #expect(latest.accumulationDistribution != nil)
        #expect(latest.moneyFlowIndex == 100)
        #expect(latest.chaikinMoneyFlow != nil)
        #expect(latest.psychologicalLine == 100)
        let actualROC = try #require(latest.rateOfChange)
        let expectedROC = (120.0 / 110.0 - 1) * 100
        #expect(abs(actualROC - expectedROC) < 0.000_001)
    }

    @Test func volumeIndicatorsStayUnavailableWithoutVolume() throws {
        let start = StockChartFixtures.date(2026, 1, 1)
        let points = (0..<40).map { index in
            let price = Double(index + 1)
            return StockChartFixtures.point(
                at: start.addingTimeInterval(TimeInterval(index * 86_400)),
                open: price,
                high: price + 1,
                low: price - 1,
                close: price,
                volume: nil
            )
        }
        let latest = try #require(StockTechnicalIndicators.calculate(points).last)

        #expect(latest.onBalanceVolume == nil)
        #expect(latest.accumulationDistribution == nil)
        #expect(latest.moneyFlowIndex == nil)
        #expect(latest.chaikinMoneyFlow == nil)
        #expect(latest.rateOfChange != nil)
    }

    @Test func legacyCachedIndicatorDecodesWithNewFieldsUnset() throws {
        let data = Data(#"""
        {
            "date": 0,
            "macdLine": 1.5,
            "macdSignal": 1.0,
            "macdHistogram": 1.0,
            "rsi14": 55
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(
            StockTechnicalIndicatorPoint.self,
            from: data
        )

        #expect(decoded.macdLine == 1.5)
        #expect(decoded.rsi14 == 55)
        #expect(decoded.stochasticK == nil)
        #expect(decoded.rateOfChange == nil)
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
