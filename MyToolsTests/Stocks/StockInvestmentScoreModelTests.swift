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

    @Test func scoreIsBoundedAndDescribesItsEvidence() throws {
        let points = pricePoints(count: 120, direction: 1)

        let score = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: points)
        ))

        #expect(score.modelVersion == "4.0.0")
        #expect((0...100).contains(score.value))
        #expect((0...100).contains(score.unadjustedValue))
        #expect(score.sampleCount == 120)
        #expect(score.factors.count == 10)
        #expect(score.factors.map(\.kind).contains(.oscillator))
        #expect(Set(score.factors.map(\.kind)).count == score.factors.count)
    }

    @Test func fundamentalsChangeInvestmentOpportunityAndConfidence() throws {
        let points = pricePoints(count: 150, direction: 1)
        let favorable = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(
                pricePoints: points,
                fundamentals: StockFundamentalSnapshot(
                    asOfDate: points.last!.date,
                    source: "Test",
                    priceEarningsRatioTTM: 12,
                    priceBookRatioMRQ: 1.2,
                    dividendYield: 0.04,
                    returnOnEquity: 0.20,
                    netProfitMargin: 0.15,
                    revenueGrowth: 0.15,
                    earningsGrowth: 0.20
                )
            )
        ))
        let unfavorable = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(
                pricePoints: points,
                fundamentals: StockFundamentalSnapshot(
                    asOfDate: points.last!.date,
                    source: "Test",
                    priceEarningsRatioTTM: 80,
                    priceBookRatioMRQ: 8,
                    dividendYield: 0.01,
                    returnOnEquity: 0.03,
                    netProfitMargin: 0.02,
                    revenueGrowth: -0.20,
                    earningsGrowth: -0.25
                )
            )
        ))
        let withoutFundamentals = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: points)
        ))

        #expect(favorable.value > unfavorable.value)
        #expect(favorable.fundamentalMetricCount == 7)
        #expect(favorable.fundamentals?.priceEarningsRatioTTM == 12)
        #expect(favorable.confidenceValue > withoutFundamentals.confidenceValue)
        #expect(favorable.factors.contains { $0.kind == .valuation })
        #expect(favorable.factors.contains { $0.kind == .quality })
        #expect(favorable.factors.contains { $0.kind == .growth })
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

    @Test func missingVolumeKeepsCapitalFlowNeutralWithoutBlockingScore() throws {
        let start = StockChartFixtures.date(2025, 1, 1)
        let points = (0..<120).map { index in
            let close = 100 + Double(index) * 0.2
            return StockChartFixtures.point(
                at: start.addingTimeInterval(TimeInterval(index * 86_400)),
                open: close - 0.1,
                high: close + 0.5,
                low: close - 0.5,
                close: close,
                volume: nil
            )
        }

        let score = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(pricePoints: points)
        ))
        let capitalFlow = try #require(score.factors.first { $0.kind == .volume })

        #expect(capitalFlow.evidence == 0)
        #expect(capitalFlow.summary.contains("不足"))
    }

    @Test func addedValuationMetricsContributeWithoutLegacyRatios() throws {
        let points = pricePoints(count: 150, direction: 0.1)
        let favorable = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(
                pricePoints: points,
                fundamentals: StockFundamentalSnapshot(
                    asOfDate: points.last!.date,
                    priceEarningsGrowthRatio: 1,
                    priceCashFlowRatioTTM: 8,
                    priceSalesRatioTTM: 1.5,
                    enterpriseValueToEBITDA: 8,
                    earningsPerShareTTM: 2
                )
            )
        ))
        let unfavorable = try #require(StockInvestmentScoreModel.calculate(
            StockInvestmentScoreInput(
                pricePoints: points,
                fundamentals: StockFundamentalSnapshot(
                    asOfDate: points.last!.date,
                    priceEarningsGrowthRatio: 4,
                    priceCashFlowRatioTTM: 45,
                    priceSalesRatioTTM: 15,
                    enterpriseValueToEBITDA: 35,
                    earningsPerShareTTM: -2
                )
            )
        ))

        #expect(favorable.value > unfavorable.value)
        #expect(favorable.fundamentalMetricCount == 5)
        #expect(unfavorable.fundamentalMetricCount == 5)
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
