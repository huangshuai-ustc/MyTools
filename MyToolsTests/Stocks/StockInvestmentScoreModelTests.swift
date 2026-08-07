import Foundation
import Testing
@testable import MyTools

struct StockInvestmentScoreModelTests {
    @Test func scoreRequiresThirtyValidPricePoints() {
        let points = pricePoints(count: 29, direction: 1)

        #expect(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: points)
        ) == nil)
    }

    @Test func versionTwoScoreIsBoundedAndDescribesItsEvidence() throws {
        let points = pricePoints(count: 120, direction: 1)

        let score = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: points)
        ))

        #expect(score.modelVersion == "2.0.0")
        #expect((0...100).contains(score.value))
        #expect((0...100).contains(score.unadjustedValue))
        #expect(score.sampleCount == 120)
        #expect(score.factors.count == 6)
    }

    @Test func persistentRiseScoresAbovePersistentDecline() throws {
        let rising = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: pricePoints(count: 120, direction: 1))
        ))
        let falling = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: pricePoints(count: 120, direction: -1))
        ))

        #expect(rising.value > falling.value)
    }

    @Test func candlestickFactorDistinguishesBullishAndBearishEngulfing() throws {
        var bullishPoints = pricePoints(count: 30, direction: 0)
        let previousDate = bullishPoints[28].date
        let latestDate = bullishPoints[29].date
        bullishPoints[28] = StockChartFixtures.point(
            at: previousDate,
            open: 102,
            high: 103,
            low: 99.5,
            close: 100,
            volume: 1_000
        )
        bullishPoints[29] = StockChartFixtures.point(
            at: latestDate,
            open: 99.5,
            high: 103,
            low: 99,
            close: 102.5,
            volume: 1_200
        )
        var bearishPoints = pricePoints(count: 30, direction: 0)
        bearishPoints[28] = StockChartFixtures.point(
            at: previousDate,
            open: 100,
            high: 102.5,
            low: 99.5,
            close: 102,
            volume: 1_000
        )
        bearishPoints[29] = StockChartFixtures.point(
            at: latestDate,
            open: 102.5,
            high: 103,
            low: 99,
            close: 99.5,
            volume: 1_200
        )

        let bullish = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: bullishPoints)
        ))
        let bearish = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: bearishPoints)
        ))
        let bullishEvidence = try #require(
            bullish.factors.first { $0.kind == .candlestick }
        )
        let bearishEvidence = try #require(
            bearish.factors.first { $0.kind == .candlestick }
        )

        #expect(bullishEvidence.evidence == 1)
        #expect(bearishEvidence.evidence == -1)
    }

    private func pricePoints(count: Int, direction: Double) -> [StockChartPoint] {
        let start = StockChartFixtures.date(2025, 1, 1)
        return (0..<count).map { index in
            let close = 100 + direction * Double(index) * 0.4
            let open = close - direction * 0.15
            return StockChartFixtures.point(
                at: start.addingTimeInterval(TimeInterval(index * 86_400)),
                open: open,
                high: max(open, close) + 0.5,
                low: min(open, close) - 0.5,
                close: close,
                volume: 1_000 + Double(index * 10)
            )
        }
    }
}
