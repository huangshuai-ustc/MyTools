#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockFundamentalSnapshot: Equatable, Sendable {
    let asOfDate: Date
    let source: String
    let priceEarningsRatioTTM: Double?
    let priceBookRatioMRQ: Double?
    let priceEarningsGrowthRatio: Double?
    let priceCashFlowRatioTTM: Double?
    let priceSalesRatioTTM: Double?
    let enterpriseValueToEBITDA: Double?
    let earningsPerShareTTM: Double?
    let dividendYield: Double?
    let returnOnEquity: Double?
    let netProfitMargin: Double?
    let revenueGrowth: Double?
    let earningsGrowth: Double?
    let marketCapitalization: Double?
    let turnoverAmount: Double?
    let turnoverRate: Double?

    init(
        asOfDate: Date,
        source: String = "",
        priceEarningsRatioTTM: Double? = nil,
        priceBookRatioMRQ: Double? = nil,
        priceEarningsGrowthRatio: Double? = nil,
        priceCashFlowRatioTTM: Double? = nil,
        priceSalesRatioTTM: Double? = nil,
        enterpriseValueToEBITDA: Double? = nil,
        earningsPerShareTTM: Double? = nil,
        dividendYield: Double? = nil,
        returnOnEquity: Double? = nil,
        netProfitMargin: Double? = nil,
        revenueGrowth: Double? = nil,
        earningsGrowth: Double? = nil,
        marketCapitalization: Double? = nil,
        turnoverAmount: Double? = nil,
        turnoverRate: Double? = nil
    ) {
        self.asOfDate = asOfDate
        self.source = source
        self.priceEarningsRatioTTM = priceEarningsRatioTTM
        self.priceBookRatioMRQ = priceBookRatioMRQ
        self.priceEarningsGrowthRatio = priceEarningsGrowthRatio
        self.priceCashFlowRatioTTM = priceCashFlowRatioTTM
        self.priceSalesRatioTTM = priceSalesRatioTTM
        self.enterpriseValueToEBITDA = enterpriseValueToEBITDA
        self.earningsPerShareTTM = earningsPerShareTTM
        self.dividendYield = dividendYield
        self.returnOnEquity = returnOnEquity
        self.netProfitMargin = netProfitMargin
        self.revenueGrowth = revenueGrowth
        self.earningsGrowth = earningsGrowth
        self.marketCapitalization = marketCapitalization
        self.turnoverAmount = turnoverAmount
        self.turnoverRate = turnoverRate
    }

    var availableMetricCount: Int {
        // Only count values that participate in the score. Market value and
        // turnover remain presentation-only because their meaning depends too
        // heavily on market, industry and share structure.
        [
            priceEarningsRatioTTM,
            priceBookRatioMRQ,
            priceEarningsGrowthRatio,
            priceCashFlowRatioTTM,
            priceSalesRatioTTM,
            enterpriseValueToEBITDA,
            earningsPerShareTTM,
            dividendYield,
            returnOnEquity,
            netProfitMargin,
            revenueGrowth,
            earningsGrowth
        ].compactMap { $0 }
            .filter { $0.isFinite }
            .count
    }

    var displayMetricCount: Int {
        [
            priceEarningsRatioTTM,
            priceBookRatioMRQ,
            priceEarningsGrowthRatio,
            priceCashFlowRatioTTM,
            priceSalesRatioTTM,
            enterpriseValueToEBITDA,
            earningsPerShareTTM,
            dividendYield,
            returnOnEquity,
            netProfitMargin,
            revenueGrowth,
            earningsGrowth,
            marketCapitalization,
            turnoverAmount,
            turnoverRate
        ].compactMap { $0 }
            .filter { $0.isFinite }
            .count
    }
}

struct StockInvestmentScoreInput: Sendable {
    let pricePoints: [StockChartPoint]
    let fundamentals: StockFundamentalSnapshot?

    init(
        pricePoints: [StockChartPoint],
        fundamentals: StockFundamentalSnapshot? = nil
    ) {
        self.pricePoints = pricePoints
        self.fundamentals = fundamentals
    }
}

struct StockInvestmentScore: Equatable, Sendable {
    enum Confidence: String, Sendable {
        case high = "高"
        case medium = "中"
        case limited = "有限"
    }

    let value: Int
    let unadjustedValue: Int
    let date: Date
    let modelVersion: String
    let sampleCount: Int
    let confidence: Confidence
    let confidenceValue: Double
    let factors: [StockInvestmentScoreFactor]
    let adjustments: [String]
    let fundamentals: StockFundamentalSnapshot?
    let fundamentalMetricCount: Int
    let fundamentalAsOfDate: Date?
    let fundamentalSource: String?

    var levelTitle: String {
        switch value {
        case 80...: return "投资机会很强"
        case 65..<80: return "投资机会偏强"
        case 50..<65: return "投资机会中性偏强"
        case 35..<50: return "投资机会中性偏弱"
        default: return "投资风险较高"
        }
    }
}

struct StockInvestmentScoreFactor: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case trend
        case momentum
        case oscillator
        case position
        case volume
        case candlestick
        case valuation
        case quality
        case growth
        case risk

        var title: String {
            switch self {
            case .trend: return "趋势"
            case .momentum: return "动能"
            case .oscillator: return "市场强弱"
            case .position: return "价格位置"
            case .volume: return "量价资金"
            case .candlestick: return "K 线触发"
            case .valuation: return "估值水平"
            case .quality: return "盈利质量"
            case .growth: return "成长性"
            case .risk: return "风险约束"
            }
        }
    }

    let kind: Kind
    let evidence: Double
    let summary: String

    var id: Kind { kind }
    var displayValue: Int {
        Int((50 + clamp(evidence, -1, 1) * 50).rounded())
    }
    var directionTitle: String {
        switch evidence {
        case 0.45...: return "明显有利"
        case 0.15..<0.45: return "略有利"
        case -0.15..<0.15: return "中性"
        case -0.45 ..< -0.15: return "略不利"
        default: return "明显不利"
        }
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

/// Stable entry point for the investment-opportunity score shown by the app.
///
/// V4 combines grouped technical signals, valuation, quality, growth and risk.
/// Correlated indicators are first condensed inside their own signal family so
/// adding another oscillator cannot inflate the score through duplicate votes.
/// Constants remain explicit so a future version can be backtested without
/// touching the view or market-data layers.
enum StockInvestmentScoreModel {
    static let version = "4.0.0"

    private struct Evidence {
        let value: Double
        let summary: String
    }

    private struct Regression {
        let slopeRatio: Double
        let rSquared: Double
    }

    static func calculate(_ input: StockInvestmentScoreInput) -> StockInvestmentScore? {
        let points = input.pricePoints
            .filter { $0.close.isFinite && $0.close > 0 }
            .sorted { $0.date < $1.date }
        guard points.count >= 30, let latest = points.last else { return nil }

        let indicators = StockTechnicalIndicators.calculate(points)
        let averageTrueRange = averageTrueRange(points, period: 14)
            ?? max(latest.close * 0.02, 0.000_001)
        let dailyVolatility = standardDeviation(dailyReturns(points).suffix(60))
            ?? 0.015

        let trend = trendEvidence(
            points: points,
            indicators: indicators,
            averageTrueRange: averageTrueRange,
            dailyVolatility: dailyVolatility
        )
        let momentum = momentumEvidence(
            indicators: indicators,
            averageTrueRange: averageTrueRange
        )
        let oscillator = oscillatorEvidence(
            indicators: indicators,
            momentumDirection: momentum.value
        )
        let position = positionEvidence(
            points: points,
            indicators: indicators,
            averageTrueRange: averageTrueRange
        )
        let volume = volumeEvidence(points: points, indicators: indicators)
        let candlestick = candlestickEvidence(points: points)
        let valuation = valuationEvidence(fundamentals: input.fundamentals)
        let quality = qualityEvidence(fundamentals: input.fundamentals)
        let growth = growthEvidence(fundamentals: input.fundamentals)
        let risk = riskEvidence(points: points, dailyVolatility: dailyVolatility)

        let trendVolumeInteraction = directionalAgreement(trend.value, volume.value)
        let trendMomentumInteraction = directionalAgreement(trend.value, momentum.value)
        let trendVolumeConflict = directionalConflict(trend.value, volume.value)
        let trendMomentumConflict = directionalConflict(trend.value, momentum.value)
        let technicalConsensus = consensusStrength([
            trend.value,
            momentum.value,
            oscillator.value,
            volume.value
        ])
        // Conflicting families should reduce conviction toward neutral instead
        // of turning disagreement into an independent bearish penalty.
        let consensusMultiplier = 0.72 + 0.28 * technicalConsensus

        let technicalLatentScore = 0.78 * trend.value
            + 0.55 * momentum.value
            + 0.42 * oscillator.value
            + 0.30 * position.value
            + 0.45 * volume.value
            + 0.10 * candlestick.value
            + 0.35 * trendVolumeInteraction
            + 0.25 * trendMomentumInteraction

        let technicalEvidence = tanh(technicalLatentScore * consensusMultiplier / 2.0)
        let combinedEvidence = clamp(
            0.40 * technicalEvidence
                + 0.22 * valuation.value
                + 0.13 * quality.value
                + 0.10 * growth.value
                + 0.15 * risk.value,
            -1,
            1
        )
        let riskLevel = clamp((1 - risk.value) / 2, 0, 1)
        var adjustedEvidence = combinedEvidence
        if trend.value < -0.65, momentum.value < -0.35 {
            adjustedEvidence -= 0.12
        }
        if riskLevel > 0.75 {
            adjustedEvidence -= 0.12
        }

        let unadjustedValue = Int((50 + 50 * tanh(1.35 * adjustedEvidence)).rounded())
        let volumeCoverage = Double(points.compactMap(\.volume).filter { $0 > 0 }.count)
            / Double(points.count)
        let validOHLCCount = points.filter {
            $0.open.isFinite && $0.high.isFinite && $0.low.isFinite
                && $0.open > 0 && $0.high >= $0.low
        }.count
        let ohlcCoverage = Double(validOHLCCount) / Double(points.count)
        let confidenceValue = confidence(
            sampleCount: points.count,
            volumeCoverage: volumeCoverage,
            ohlcCoverage: ohlcCoverage,
            fundamentalMetricCount: input.fundamentals?.availableMetricCount ?? 0
        )
        let value = Int((50 + confidenceValue * (Double(unadjustedValue) - 50)).rounded())
        let confidenceTitle: StockInvestmentScore.Confidence
        switch confidenceValue {
        case 0.82...: confidenceTitle = .high
        case 0.62..<0.82: confidenceTitle = .medium
        default: confidenceTitle = .limited
        }

        let factors = [
            factor(.trend, trend),
            factor(.momentum, momentum),
            factor(.oscillator, oscillator),
            factor(.position, position),
            factor(.volume, volume),
            factor(.candlestick, candlestick),
            factor(.valuation, valuation),
            factor(.quality, quality),
            factor(.growth, growth),
            factor(.risk, risk)
        ]
        let adjustments = adjustmentSummaries(
            trendVolumeInteraction: trendVolumeInteraction,
            trendMomentumInteraction: trendMomentumInteraction,
            trendVolumeConflict: trendVolumeConflict,
            trendMomentumConflict: trendMomentumConflict,
            technicalConsensus: technicalConsensus,
            riskLevel: riskLevel,
            confidenceValue: confidenceValue
        )

        return StockInvestmentScore(
            value: clamp(value, 0, 100),
            unadjustedValue: clamp(unadjustedValue, 0, 100),
            date: latest.date,
            modelVersion: version,
            sampleCount: points.count,
            confidence: confidenceTitle,
            confidenceValue: confidenceValue,
            factors: factors,
            adjustments: adjustments,
            fundamentals: input.fundamentals,
            fundamentalMetricCount: input.fundamentals?.availableMetricCount ?? 0,
            fundamentalAsOfDate: input.fundamentals?.asOfDate,
            fundamentalSource: input.fundamentals?.source.isEmpty == false
                ? input.fundamentals?.source
                : nil
        )
    }

    private static func valuationEvidence(
        fundamentals: StockFundamentalSnapshot?
    ) -> Evidence {
        guard let fundamentals else {
            return Evidence(value: 0, summary: "估值数据未取得，不参与方向判断")
        }
        var values: [(Double, Double)] = []
        if let pe = fundamentals.priceEarningsRatioTTM, pe.isFinite {
            values.append((valuationPEEvidence(pe), 0.24))
        }
        if let pb = fundamentals.priceBookRatioMRQ, pb.isFinite {
            values.append((valuationPBEvidence(pb), 0.18))
        }
        if let peg = fundamentals.priceEarningsGrowthRatio, peg.isFinite {
            values.append((valuationPEGEvidence(peg), 0.15))
        }
        if let pcf = fundamentals.priceCashFlowRatioTTM, pcf.isFinite {
            values.append((valuationPCFEvidence(pcf), 0.13))
        }
        if let ps = fundamentals.priceSalesRatioTTM, ps.isFinite {
            values.append((valuationPSEvidence(ps), 0.10))
        }
        if let evToEBITDA = fundamentals.enterpriseValueToEBITDA,
           evToEBITDA.isFinite {
            values.append((valuationEVToEBITDAEvidence(evToEBITDA), 0.12))
        }
        if let dividendYield = fundamentals.dividendYield, dividendYield.isFinite {
            values.append((dividendYieldEvidence(dividendYield), 0.08))
        }
        guard !values.isEmpty else {
            return Evidence(value: 0, summary: "估值数据缺失，不参与方向判断")
        }
        let value = clamp(
            values.reduce(0) { $0 + $1.0 * $1.1 }
                / values.reduce(0) { $0 + $1.1 },
            -1,
            1
        )
        let summary: String
        if value > 0.35 {
            summary = "利润、现金流、销售或企业价值口径显示估值相对友好"
        } else if value < -0.35 {
            summary = "多项估值口径偏高，当前价格已透支部分预期"
        } else {
            summary = "各估值口径综合后接近中性，缺乏明显安全边际"
        }
        return Evidence(value: value, summary: summary)
    }

    private static func valuationPEEvidence(_ value: Double) -> Double {
        guard value > 0 else { return -0.35 }
        switch value {
        case ...10: return 0.75
        case 10..<20: return 0.75 - (value - 10) / 10 * 0.35
        case 20..<35: return 0.40 - (value - 20) / 15 * 0.85
        case 35..<60: return -0.45 - (value - 35) / 25 * 0.40
        default: return -0.90
        }
    }

    private static func valuationPBEvidence(_ value: Double) -> Double {
        guard value > 0 else { return -0.25 }
        switch value {
        case ...1: return 0.65
        case 1..<2.5: return 0.65 - (value - 1) / 1.5 * 0.45
        case 2.5..<5: return 0.20 - (value - 2.5) / 2.5 * 0.75
        case 5..<8: return -0.55 - (value - 5) / 3 * 0.30
        default: return -0.90
        }
    }

    private static func valuationPEGEvidence(_ value: Double) -> Double {
        guard value > 0 else { return -0.35 }
        switch value {
        case ..<0.5: return 0.45
        case 0.5..<1.5: return 0.75 - abs(value - 1) * 0.45
        case 1.5..<3: return 0.50 - (value - 1.5) / 1.5 * 0.80
        case 3..<5: return -0.30 - (value - 3) / 2 * 0.40
        default: return -0.80
        }
    }

    private static func valuationPCFEvidence(_ value: Double) -> Double {
        guard value > 0 else { return -0.35 }
        switch value {
        case ...8: return 0.70
        case 8..<15: return 0.70 - (value - 8) / 7 * 0.35
        case 15..<25: return 0.35 - (value - 15) / 10 * 0.75
        case 25..<40: return -0.40 - (value - 25) / 15 * 0.35
        default: return -0.85
        }
    }

    private static func valuationPSEvidence(_ value: Double) -> Double {
        guard value > 0 else { return -0.25 }
        switch value {
        case ...1: return 0.65
        case 1..<3: return 0.65 - (value - 1) / 2 * 0.35
        case 3..<7: return 0.30 - (value - 3) / 4 * 0.75
        case 7..<12: return -0.45 - (value - 7) / 5 * 0.30
        default: return -0.85
        }
    }

    private static func valuationEVToEBITDAEvidence(_ value: Double) -> Double {
        guard value > 0 else { return -0.30 }
        switch value {
        case ...6: return 0.70
        case 6..<12: return 0.70 - (value - 6) / 6 * 0.40
        case 12..<20: return 0.30 - (value - 12) / 8 * 0.75
        case 20..<30: return -0.45 - (value - 20) / 10 * 0.30
        default: return -0.85
        }
    }

    private static func dividendYieldEvidence(_ value: Double) -> Double {
        guard value > 0 else { return -0.10 }
        switch value {
        case ..<0.02: return 0.05
        case 0.02..<0.06:
            return min(0.55, 0.05 + (value - 0.02) / 0.04 * 0.50)
        case 0.06..<0.10: return 0.55 - (value - 0.06) / 0.04 * 0.35
        default: return 0.15
        }
    }

    private static func qualityEvidence(
        fundamentals: StockFundamentalSnapshot?
    ) -> Evidence {
        guard let fundamentals else {
            return Evidence(value: 0, summary: "盈利质量数据未取得，不参与方向判断")
        }
        var values: [(Double, Double)] = []
        if let roe = fundamentals.returnOnEquity, roe.isFinite {
            values.append((qualityROEEvidence(roe), 0.55))
        }
        if let margin = fundamentals.netProfitMargin, margin.isFinite {
            values.append((qualityMarginEvidence(margin), 0.35))
        }
        if let eps = fundamentals.earningsPerShareTTM, eps.isFinite {
            // Absolute EPS is not comparable across currencies or share counts;
            // only its sign is used as a weak profitability confirmation.
            values.append((qualityEPSEvidence(eps), 0.10))
        }
        guard !values.isEmpty else {
            return Evidence(value: 0, summary: "盈利质量数据缺失，不参与方向判断")
        }
        let value = clamp(
            values.reduce(0) { $0 + $1.0 * $1.1 }
                / values.reduce(0) { $0 + $1.1 },
            -1,
            1
        )
        let summary: String
        if value > 0.35 {
            summary = "ROE 或利润率显示盈利质量较好"
        } else if value < -0.35 {
            summary = "盈利能力偏弱，基本面支撑不足"
        } else {
            summary = "盈利质量处于中性区间"
        }
        return Evidence(value: value, summary: summary)
    }

    private static func qualityROEEvidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        switch value {
        case ...0: return -0.75
        case 0..<0.08: return -0.25 + value / 0.08 * 0.25
        case 0.08..<0.15: return (value - 0.08) / 0.07 * 0.45
        case 0.15..<0.25: return 0.45 + (value - 0.15) / 0.10 * 0.40
        default: return 0.75
        }
    }

    private static func qualityMarginEvidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        switch value {
        case ...0: return -0.55
        case 0..<0.05: return -0.20 + value / 0.05 * 0.20
        case 0.05..<0.15: return (value - 0.05) / 0.10 * 0.50
        case 0.15..<0.30: return 0.50 + (value - 0.15) / 0.15 * 0.30
        default: return 0.80
        }
    }

    private static func qualityEPSEvidence(_ value: Double) -> Double {
        switch value {
        case ..<0: return -0.55
        case 0: return -0.20
        default: return 0.25
        }
    }

    private static func growthEvidence(
        fundamentals: StockFundamentalSnapshot?
    ) -> Evidence {
        guard let fundamentals else {
            return Evidence(value: 0, summary: "成长数据未取得，不参与方向判断")
        }
        var values: [(Double, Double)] = []
        if let revenueGrowth = fundamentals.revenueGrowth, revenueGrowth.isFinite {
            values.append((growthRateEvidence(revenueGrowth), 0.45))
        }
        if let earningsGrowth = fundamentals.earningsGrowth, earningsGrowth.isFinite {
            values.append((growthRateEvidence(earningsGrowth), 0.55))
        }
        guard !values.isEmpty else {
            return Evidence(value: 0, summary: "成长数据缺失，不参与方向判断")
        }
        let value = clamp(
            values.reduce(0) { $0 + $1.0 * $1.1 }
                / values.reduce(0) { $0 + $1.1 },
            -1,
            1
        )
        let summary: String
        if value > 0.35 {
            summary = "收入或盈利增长对当前估值形成支撑"
        } else if value < -0.35 {
            summary = "收入或盈利增长转弱，未来预期存在压力"
        } else {
            summary = "成长性处于中性区间"
        }
        return Evidence(value: value, summary: summary)
    }

    private static func growthRateEvidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return clamp(tanh(value / 0.25), -1, 1)
    }

    private static func trendEvidence(
        points: [StockChartPoint],
        indicators: [StockTechnicalIndicatorPoint],
        averageTrueRange: Double,
        dailyVolatility: Double
    ) -> Evidence {
        guard let latest = points.last, let latestIndicator = indicators.last else {
            return Evidence(value: 0, summary: "趋势数据不足，按中性处理")
        }
        let scale = max(averageTrueRange, latest.close * 0.005)
        let priceVersusMA20 = latestIndicator.movingAverage20.map {
            tanh((latest.close - $0) / (2 * scale))
        }
        let ma20VersusMA60: Double? = {
            guard let ma20 = latestIndicator.movingAverage20,
                  let ma60 = latestIndicator.movingAverage60 else { return nil }
            return tanh((ma20 - ma60) / (3 * scale))
        }()
        let regression = linearRegression(Array(points.suffix(20)).map(\.close))
        let normalizedSlope = tanh(
            regression.slopeRatio / max(dailyVolatility * 0.30, 0.002)
        ) * (0.40 + 0.60 * regression.rSquared)
        let dmi = dmiEvidence(latestIndicator)
        let trix = trixEvidence(latestIndicator)
        let value = weightedAverage([
            (priceVersusMA20, 0.24),
            (ma20VersusMA60, 0.20),
            (normalizedSlope, 0.24),
            (dmi, 0.18),
            (trix, 0.14)
        ])

        let summary: String
        if value > 0.45 {
            summary = "均线、DMI 与 TRIX 综合指向上行趋势"
        } else if value > 0.15 {
            summary = "趋势指标整体略偏上，但一致性仍有限"
        } else if value < -0.45 {
            summary = "均线、DMI 与 TRIX 综合显示下行趋势"
        } else if value < -0.15 {
            summary = "趋势指标整体略偏弱，尚未形成可靠反转"
        } else {
            summary = "多项趋势指标综合后接近横盘"
        }
        return Evidence(value: value, summary: summary)
    }

    private static func dmiEvidence(
        _ indicator: StockTechnicalIndicatorPoint
    ) -> Double? {
        guard let positive = indicator.positiveDirectionalIndex,
              let negative = indicator.negativeDirectionalIndex,
              let adx = indicator.averageDirectionalIndex,
              positive.isFinite,
              negative.isFinite,
              adx.isFinite else { return nil }
        let total = positive + negative
        guard total > 0 else { return 0 }
        let direction = clamp((positive - negative) / total, -1, 1)
        let strength = clamp((adx - 15) / 25, 0, 1)
        return direction * strength
    }

    private static func trixEvidence(
        _ indicator: StockTechnicalIndicatorPoint
    ) -> Double? {
        guard let trix = indicator.trix, trix.isFinite else { return nil }
        let direction = tanh(trix / 0.45)
        guard let signal = indicator.trixSignal, signal.isFinite else {
            return direction
        }
        let crossover = tanh((trix - signal) / 0.18)
        return clamp(0.65 * direction + 0.35 * crossover, -1, 1)
    }

    private static func momentumEvidence(
        indicators: [StockTechnicalIndicatorPoint],
        averageTrueRange: Double
    ) -> Evidence {
        guard let latest = indicators.last else {
            return Evidence(value: 0, summary: "动能数据不足，按中性处理")
        }
        let scale = max(averageTrueRange, 0.000_001)
        let macdPosition = tanh((latest.macdLine - latest.macdSignal) / (0.22 * scale))
        let earlierIndex = max(0, indicators.count - 4)
        let histogramChange = latest.macdHistogram - indicators[earlierIndex].macdHistogram
        let acceleration = tanh(histogramChange / (0.30 * scale))
        let momentumDirection = latest.momentum.map {
            tanh($0 / (4 * scale))
        }
        let momentumCrossover: Double? = {
            guard let momentum = latest.momentum,
                  let average = latest.momentumAverage else { return nil }
            return tanh((momentum - average) / (1.5 * scale))
        }()
        let mtm = weightedAverageOptional([
            (momentumDirection, 0.65),
            (momentumCrossover, 0.35)
        ])
        let roc = latest.rateOfChange.map { tanh($0 / 8) }
        let value = weightedAverage([
            (macdPosition, 0.32),
            (acceleration, 0.13),
            (mtm, 0.30),
            (roc, 0.25)
        ])

        let summary: String
        if value > 0.45 {
            summary = "MACD、MTM 与 ROC 共同显示正向速度动能"
        } else if value > 0.15 {
            summary = "价格变动速度正在改善，但强度尚不突出"
        } else if value < -0.45 {
            summary = "MACD、MTM 与 ROC 共同显示负向动能"
        } else if value < -0.15 {
            summary = "价格变动速度略偏弱，反转信号尚不充分"
        } else {
            summary = "速度类动能指标综合后接近平衡"
        }
        return Evidence(value: value, summary: summary)
    }

    private static func oscillatorEvidence(
        indicators: [StockTechnicalIndicatorPoint],
        momentumDirection: Double
    ) -> Evidence {
        guard let latest = indicators.last else {
            return Evidence(value: 0, summary: "市场强弱数据不足，按中性处理")
        }
        let rsi = latest.rsi14.map { centeredOscillator($0, scale: 20) }
        let kdj: Double? = {
            guard let k = latest.stochasticK, let d = latest.stochasticD else {
                return nil
            }
            let position = centeredOscillator(k, scale: 22)
            let crossover = tanh((k - d) / 12)
            return clamp(0.55 * position + 0.45 * crossover, -1, 1)
        }()
        let williams = latest.williamsR.map {
            clamp(tanh(($0 + 50) / 24), -1, 1)
        }
        let cci = latest.commodityChannelIndex.map {
            clamp(tanh($0 / 140), -1, 1)
        }
        let mfi = latest.moneyFlowIndex.map { centeredOscillator($0, scale: 22) }
        let psy = latest.psychologicalLine.map { centeredOscillator($0, scale: 24) }
        var value = weightedAverage([
            (rsi, 0.22),
            (kdj, 0.20),
            (williams, 0.14),
            (cci, 0.17),
            (mfi, 0.16),
            (psy, 0.11)
        ])

        let highCount = [
            latest.rsi14.map { $0 >= 75 },
            latest.stochasticK.map { $0 >= 80 },
            latest.williamsR.map { $0 >= -20 },
            latest.commodityChannelIndex.map { $0 >= 150 },
            latest.moneyFlowIndex.map { $0 >= 80 },
            latest.psychologicalLine.map { $0 >= 75 }
        ].compactMap { $0 }.filter { $0 }.count
        let lowCount = [
            latest.rsi14.map { $0 <= 25 },
            latest.stochasticK.map { $0 <= 20 },
            latest.williamsR.map { $0 <= -80 },
            latest.commodityChannelIndex.map { $0 <= -150 },
            latest.moneyFlowIndex.map { $0 <= 20 },
            latest.psychologicalLine.map { $0 <= 25 }
        ].compactMap { $0 }.filter { $0 }.count

        let summary: String
        if highCount >= 4 {
            value = min(value, momentumDirection < -0.15 ? 0 : 0.35)
            summary = "多项强弱指标进入过热区，继续上行但追高风险增加"
        } else if lowCount >= 4 {
            if momentumDirection > 0.15 {
                value = max(value + 0.25, 0.15)
                summary = "多项指标超卖且速度动能回升，出现修复信号"
            } else {
                value = max(value, -0.35)
                summary = "多项指标进入超卖区，但尚缺少动能反转确认"
            }
        } else if value > 0.35 {
            summary = "RSI、KDJ、W%R、CCI、MFI 与 PSY 综合偏强"
        } else if value < -0.35 {
            summary = "多项市场强弱指标综合偏弱"
        } else {
            summary = "强弱与超买超卖指标综合后接近中性"
        }
        return Evidence(value: clamp(value, -1, 1), summary: summary)
    }

    private static func positionEvidence(
        points: [StockChartPoint],
        indicators: [StockTechnicalIndicatorPoint],
        averageTrueRange: Double
    ) -> Evidence {
        guard let latest = points.last,
              let latestIndicator = indicators.last,
              let middle = latestIndicator.bollingerMiddle,
              let upper = latestIndicator.bollingerUpper,
              let lower = latestIndicator.bollingerLower,
              upper > lower else {
            return Evidence(value: 0, summary: "价格位置数据不足，按中性处理")
        }
        let percentB = (latest.close - lower) / (upper - lower)
        let location: Double
        if percentB <= 0.50 {
            location = tanh((percentB - 0.50) / 0.25)
        } else if percentB <= 0.85 {
            location = (percentB - 0.50) / 0.35
        } else {
            location = clamp(1 - (percentB - 0.85) / 0.15, -1, 1)
        }
        let earlierIndex = max(0, indicators.count - 6)
        let earlierMiddle = indicators[earlierIndex].bollingerMiddle ?? middle
        let middleSlope = tanh(
            (middle - earlierMiddle) / max(2 * averageTrueRange, latest.close * 0.01)
        )
        let value = clamp(0.72 * location + 0.28 * middleSlope, -1, 1)

        let summary: String
        if percentB > 1 {
            summary = "价格越过布林上轨，强势同时存在追高风险"
        } else if value > 0.35 {
            summary = "价格处于布林中上部，通道结构有利"
        } else if percentB < 0 {
            summary = "价格跌破布林下轨，位置风险较高"
        } else if value < -0.25 {
            summary = "价格位于布林中轨下方，位置偏弱"
        } else {
            summary = "价格位于布林通道中性区域"
        }
        return Evidence(value: value, summary: summary)
    }

    private static func volumeEvidence(
        points: [StockChartPoint],
        indicators: [StockTechnicalIndicatorPoint]
    ) -> Evidence {
        let recent = Array(points.suffix(21))
        let traditional = traditionalVolumeEvidence(recent)
        let recentIndicators = Array(indicators.suffix(21))
        let obv = seriesDirection(recentIndicators.compactMap(\.onBalanceVolume))
        let accumulationDistribution = seriesDirection(
            recentIndicators.compactMap(\.accumulationDistribution)
        )
        let chaikin = indicators.last?.chaikinMoneyFlow.map {
            clamp(tanh($0 / 0.18), -1, 1)
        }
        let flow = weightedAverageOptional([
            (obv, 0.35),
            (accumulationDistribution, 0.30),
            (chaikin, 0.35)
        ])
        let value = weightedAverage([
            (traditional, 0.45),
            (flow, 0.55)
        ])

        let summary: String
        if value > 0.4 {
            summary = "成交量、OBV、A/D 与 Chaikin 共同显示资金流入"
        } else if value > 0.12 {
            summary = "量价与资金流略偏正向，但确认强度有限"
        } else if value < -0.4 {
            summary = "成交量与资金流指标共同显示卖压较强"
        } else if value < -0.12 {
            summary = "量价与资金流关系略偏负向"
        } else if traditional == nil, flow == nil {
            summary = "成交量与资金流数据不足，不参与方向判断"
        } else {
            summary = "量价与资金流指标没有形成明确方向"
        }
        return Evidence(value: value, summary: summary)
    }

    private static func traditionalVolumeEvidence(
        _ recent: [StockChartPoint]
    ) -> Double? {
        guard recent.count >= 6 else { return nil }
        let volumes = recent.dropLast().compactMap(\.volume).filter { $0 > 0 }
        guard let averageVolume = average(volumes),
              let latest = recent.last,
              let latestVolume = latest.volume,
              latestVolume > 0,
              averageVolume > 0 else { return nil }

        let directionalVolumes = recent.indices.dropFirst().dropLast().compactMap {
            index -> (Bool, Double)? in
            guard let volume = recent[index].volume, volume > 0 else { return nil }
            return (recent[index].close >= recent[index - 1].close, volume)
        }
        let upAverage = average(directionalVolumes.filter(\.0).map(\.1))
        let downAverage = average(directionalVolumes.filter { !$0.0 }.map(\.1))
        let balance: Double
        if let upAverage, let downAverage, upAverage > 0, downAverage > 0 {
            balance = tanh(log(upAverage / downAverage) / 0.55)
        } else {
            balance = 0
        }

        let previousClose = recent[recent.count - 2].close
        let dailyReturn = previousClose > 0 ? (latest.close - previousClose) / previousClose : 0
        let volumeRatio = latestVolume / averageVolume
        // The latest daily bar may still be in progress. Low volume is therefore
        // inconclusive, while elevated volume can safely confirm direction.
        let relativeVolume = max(tanh(log(max(volumeRatio, 0.05)) / 0.65), 0)
        let latestConfirmation: Double
        if dailyReturn > 0.001 {
            latestConfirmation = relativeVolume
        } else if dailyReturn < -0.001 {
            latestConfirmation = -relativeVolume
        } else {
            latestConfirmation = -abs(relativeVolume) * 0.35
        }
        return clamp(0.65 * balance + 0.35 * latestConfirmation, -1, 1)
    }

    private static func seriesDirection(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite)
        guard values.count >= 6, let first = values.first, let last = values.last else {
            return nil
        }
        let travelled = zip(values.dropFirst(), values).reduce(0) {
            $0 + abs($1.0 - $1.1)
        }
        guard travelled > 0 else { return 0 }
        return clamp(tanh(1.6 * (last - first) / travelled), -1, 1)
    }

    private static func candlestickEvidence(points: [StockChartPoint]) -> Evidence {
        guard let latest = points.last,
              latest.open.isFinite,
              latest.high.isFinite,
              latest.low.isFinite,
              latest.high > latest.low else {
            return Evidence(value: 0, summary: "K线样本不足，按中性处理")
        }

        let previous = points.dropLast().last
        let third = points.dropLast(2).last
        let latestBody = abs(latest.close - latest.open)
        let latestRange = latest.high - latest.low
        let previousBody = previous.map { abs($0.close - $0.open) } ?? 0
        let isBullishEngulfing = previous.map {
            latest.close > latest.open
                && $0.close < $0.open
                && latest.open <= $0.close
                && latest.close >= $0.open
                && latestBody > previousBody
        } ?? false
        let isBearishEngulfing = previous.map {
            latest.close < latest.open
                && $0.close > $0.open
                && latest.open >= $0.close
                && latest.close <= $0.open
                && latestBody > previousBody
        } ?? false
        let recentCloses = points.suffix(20).map(\.close)
        let recentLow = recentCloses.min() ?? latest.close
        let recentHigh = recentCloses.max() ?? latest.close
        let recentPosition = recentHigh > recentLow
            ? (latest.close - recentLow) / (recentHigh - recentLow)
            : 0.5
        let lowerShadow = min(latest.open, latest.close) - latest.low
        let upperShadow = latest.high - max(latest.open, latest.close)
        let isHammer = lowerShadow >= max(latestBody * 2, latestRange * 0.4)
            && upperShadow <= latestRange * 0.2
            && recentPosition <= 0.45
        let isShootingStar = upperShadow >= max(latestBody * 2, latestRange * 0.4)
            && lowerShadow <= latestRange * 0.2
            && recentPosition >= 0.55

        if candlestickMorningStar(third: third, middle: previous, latest: latest) {
            return Evidence(value: 1, summary: "近三日形成启明星式反转形态")
        }
        if isBullishEngulfing {
            return Evidence(value: 1, summary: "最新 K 线形成看涨吞没形态")
        }
        if isHammer {
            return Evidence(value: 0.8, summary: "相对低位出现锤子线，下方承接增强")
        }
        if candlestickEveningStar(third: third, middle: previous, latest: latest) {
            return Evidence(value: -1, summary: "近三日形成黄昏星式转弱形态")
        }
        if isBearishEngulfing {
            return Evidence(value: -1, summary: "最新 K 线形成看跌吞没形态")
        }
        if isShootingStar {
            return Evidence(value: -0.8, summary: "相对高位出现长上影，抛压风险增加")
        }

        let direction = (latest.close - latest.open) / latestRange
        let closePosition = (latest.close - latest.low) / latestRange
        let value = clamp(0.6 * direction + 0.4 * (closePosition - 0.5), -1, 1)
        let summary = latest.close >= latest.open
            ? "最新 K 线偏强，但未形成明确反转形态"
            : "最新 K 线偏弱，尚无明确止跌形态"
        return Evidence(value: value, summary: summary)
    }

    private static func candlestickMorningStar(
        third: StockChartPoint?,
        middle: StockChartPoint?,
        latest: StockChartPoint
    ) -> Bool {
        guard let first = third, let middle else { return false }
        let firstBody = abs(first.close - first.open)
        let middleBody = abs(middle.close - middle.open)
        return first.close < first.open
            && middleBody <= firstBody * 0.5
            && latest.close > latest.open
            && latest.close >= (first.open + first.close) / 2
    }

    private static func candlestickEveningStar(
        third: StockChartPoint?,
        middle: StockChartPoint?,
        latest: StockChartPoint
    ) -> Bool {
        guard let first = third, let middle else { return false }
        let firstBody = abs(first.close - first.open)
        let middleBody = abs(middle.close - middle.open)
        return first.close > first.open
            && middleBody <= firstBody * 0.5
            && latest.close < latest.open
            && latest.close <= (first.open + first.close) / 2
    }

    private static func riskEvidence(
        points: [StockChartPoint],
        dailyVolatility: Double
    ) -> Evidence {
        let recentPoints = Array(points.suffix(60))
        let annualizedVolatility = dailyVolatility * sqrt(252)
        let volatilityRisk = smoothStep(
            (annualizedVolatility - 0.18) / 0.45
        )

        var peak = recentPoints.first?.close ?? 0
        var maximumDrawdown = 0.0
        for point in recentPoints {
            peak = max(peak, point.close)
            if peak > 0 {
                maximumDrawdown = min(maximumDrawdown, point.close / peak - 1)
            }
        }
        let drawdownRisk = smoothStep((-maximumDrawdown - 0.05) / 0.30)
        let largestMove = dailyReturns(recentPoints).suffix(20).map(abs).max() ?? 0
        let jumpRisk = smoothStep((largestMove - 0.04) / 0.12)
        let riskLevel = clamp(
            0.50 * volatilityRisk + 0.35 * drawdownRisk + 0.15 * jumpRisk,
            0,
            1
        )
        let evidence = 1 - 2 * riskLevel

        let summary: String
        if riskLevel > 0.7 {
            summary = "近60日波动或回撤较高，风险惩罚明显"
        } else if riskLevel > 0.4 {
            summary = "波动与回撤处于偏高水平"
        } else if riskLevel > 0.2 {
            summary = "波动与回撤处于常见区间"
        } else {
            summary = "近期波动和回撤相对温和"
        }
        return Evidence(value: evidence, summary: summary)
    }

    private static func factor(
        _ kind: StockInvestmentScoreFactor.Kind,
        _ evidence: Evidence
    ) -> StockInvestmentScoreFactor {
        StockInvestmentScoreFactor(
            kind: kind,
            evidence: clamp(evidence.value, -1, 1),
            summary: evidence.summary
        )
    }

    private static func adjustmentSummaries(
        trendVolumeInteraction: Double,
        trendMomentumInteraction: Double,
        trendVolumeConflict: Double,
        trendMomentumConflict: Double,
        technicalConsensus: Double,
        riskLevel: Double,
        confidenceValue: Double
    ) -> [String] {
        var summaries: [String] = []
        if trendVolumeInteraction > 0.18 {
            summaries.append("趋势与量能形成正向共振")
        } else if trendVolumeInteraction < -0.18 {
            summaries.append("趋势与量能共同确认弱势")
        } else if trendVolumeConflict > 0.18 {
            summaries.append("趋势与量价资金方向冲突")
        }
        if trendMomentumInteraction > 0.18 {
            summaries.append("趋势与动能方向一致")
        } else if trendMomentumInteraction < -0.18 {
            summaries.append("趋势与动能共同确认弱势")
        } else if trendMomentumConflict > 0.18 {
            summaries.append("趋势与动能存在明显分歧")
        }
        if technicalConsensus < 0.45 {
            summaries.append("技术指标组分歧较大，技术贡献已向中性收缩")
        } else if technicalConsensus > 0.82 {
            summaries.append("趋势、动能、强弱与资金流具有较高一致性")
        }
        if riskLevel > 0.45 {
            summaries.append("高波动或较深回撤压低了投资机会")
        }
        if confidenceValue < 0.82 {
            summaries.append("数据可信度使结果向中性50分收缩")
        }
        return summaries
    }

    private static func centeredOscillator(
        _ value: Double,
        scale: Double
    ) -> Double {
        clamp(tanh((value - 50) / scale), -1, 1)
    }

    private static func consensusStrength(_ values: [Double]) -> Double {
        let active = values.filter { abs($0) >= 0.08 }
        guard active.count >= 2 else { return 0.5 }
        let averageMagnitude = active.map(abs).reduce(0, +) / Double(active.count)
        guard averageMagnitude > 0 else { return 0.5 }
        let net = abs(active.reduce(0, +) / Double(active.count))
        return clamp(net / averageMagnitude, 0, 1)
    }

    private static func directionalAgreement(_ lhs: Double, _ rhs: Double) -> Double {
        let magnitude = min(abs(lhs), abs(rhs))
        guard magnitude >= 0.10 else { return 0 }
        if lhs * rhs > 0 {
            return lhs > 0 ? magnitude : -magnitude
        }
        return 0
    }

    private static func directionalConflict(_ lhs: Double, _ rhs: Double) -> Double {
        let magnitude = min(abs(lhs), abs(rhs))
        guard magnitude >= 0.10, lhs * rhs < 0 else { return 0 }
        return magnitude
    }

    private static func confidence(
        sampleCount: Int,
        volumeCoverage: Double,
        ohlcCoverage: Double,
        fundamentalMetricCount: Int
    ) -> Double {
        let sampleCoverage = 0.55 + 0.45 * clamp(
            Double(sampleCount - 30) / 120,
            0,
            1
        )
        let volumeQuality = 0.82 + 0.18 * clamp(volumeCoverage, 0, 1)
        let ohlcQuality = 0.90 + 0.10 * clamp(ohlcCoverage, 0, 1)
        let fundamentalQuality = 0.65 + 0.35 * clamp(
            Double(fundamentalMetricCount) / 12,
            0,
            1
        )
        return clamp(
            sampleCoverage * volumeQuality * ohlcQuality * fundamentalQuality,
            0.40,
            1
        )
    }

    private static func averageTrueRange(
        _ points: [StockChartPoint],
        period: Int
    ) -> Double? {
        guard !points.isEmpty else { return nil }
        let ranges = points.indices.map { index -> Double in
            let point = points[index]
            guard index > 0 else { return max(point.high - point.low, 0) }
            let previousClose = points[index - 1].close
            return max(
                point.high - point.low,
                abs(point.high - previousClose),
                abs(point.low - previousClose)
            )
        }
        return average(ranges.suffix(period).filter { $0.isFinite && $0 > 0 })
    }

    private static func dailyReturns(_ points: [StockChartPoint]) -> [Double] {
        guard points.count >= 2 else { return [] }
        return points.indices.dropFirst().compactMap { index in
            let previous = points[index - 1].close
            let current = points[index].close
            guard previous > 0, current > 0 else { return nil }
            let value = log(current / previous)
            return value.isFinite ? value : nil
        }
    }

    private static func linearRegression(_ values: [Double]) -> Regression {
        guard values.count >= 2 else { return Regression(slopeRatio: 0, rSquared: 0) }
        let count = Double(values.count)
        let meanX = Double(values.count - 1) / 2
        let meanY = values.reduce(0, +) / count
        guard meanY != 0 else { return Regression(slopeRatio: 0, rSquared: 0) }
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for (index, value) in values.enumerated() {
            let xDifference = Double(index) - meanX
            let yDifference = value - meanY
            covariance += xDifference * yDifference
            varianceX += xDifference * xDifference
            varianceY += yDifference * yDifference
        }
        guard varianceX > 0 else { return Regression(slopeRatio: 0, rSquared: 0) }
        let slope = covariance / varianceX
        let rSquared = varianceY > 0
            ? clamp(pow(covariance, 2) / (varianceX * varianceY), 0, 1)
            : 0
        return Regression(slopeRatio: slope / meanY, rSquared: rSquared)
    }

    private static func standardDeviation<S: Sequence>(
        _ values: S
    ) -> Double? where S.Element == Double {
        let values = Array(values)
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) }
            / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func weightedAverage(
        _ values: [(value: Double?, weight: Double)]
    ) -> Double {
        let available = values.compactMap { item -> (Double, Double)? in
            guard let value = item.value else { return nil }
            return (value, item.weight)
        }
        let weight = available.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return 0 }
        return clamp(available.reduce(0) { $0 + $1.0 * $1.1 } / weight, -1, 1)
    }

    private static func weightedAverageOptional(
        _ values: [(value: Double?, weight: Double)]
    ) -> Double? {
        let available = values.compactMap { item -> (Double, Double)? in
            guard let value = item.value, value.isFinite else { return nil }
            return (value, item.weight)
        }
        guard !available.isEmpty else { return nil }
        let weight = available.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return nil }
        return clamp(available.reduce(0) { $0 + $1.0 * $1.1 } / weight, -1, 1)
    }

    private static func average<S: Sequence>(
        _ values: S
    ) -> Double? where S.Element == Double {
        let values = Array(values)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func logistic(_ value: Double) -> Double {
        1 / (1 + exp(-value))
    }

    private static func smoothStep(_ value: Double) -> Double {
        let value = clamp(value, 0, 1)
        return value * value * (3 - 2 * value)
    }

    private static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}

#endif
