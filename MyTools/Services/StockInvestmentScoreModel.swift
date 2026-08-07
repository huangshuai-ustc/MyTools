import Foundation

struct StockFundamentalSnapshot: Equatable, Sendable {
    let asOfDate: Date
    let priceEarningsRatioTTM: Double?
    let priceBookRatioMRQ: Double?
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

    var levelTitle: String {
        switch value {
        case 80...: return "技术机会很强"
        case 65..<80: return "技术机会偏强"
        case 50..<65: return "技术机会中性偏强"
        case 35..<50: return "技术机会中性偏弱"
        default: return "技术风险较高"
        }
    }
}

struct StockInvestmentScoreFactor: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case trend
        case momentum
        case position
        case volume
        case candlestick
        case risk

        var title: String {
            switch self {
            case .trend: return "趋势"
            case .momentum: return "动能"
            case .position: return "价格位置"
            case .volume: return "量能确认"
            case .candlestick: return "K 线触发"
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

/// Stable, offline entry point for the score shown by the app.
///
/// V2 combines continuous evidence nonlinearly. Its constants are explicit so
/// a future version can be backtested and changed without touching the view or
/// market-data layers. Fundamentals are reserved as a separate future input.
enum StockInvestmentScoreModel {
    static let version = "2.0.0"

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
        let position = positionEvidence(
            points: points,
            indicators: indicators,
            averageTrueRange: averageTrueRange
        )
        let volume = volumeEvidence(points: points)
        let candlestick = candlestickEvidence(points: points)
        let risk = riskEvidence(points: points, dailyVolatility: dailyVolatility)

        let trendVolumeInteraction = directionalAgreement(trend.value, volume.value)
        let trendMomentumInteraction = directionalAgreement(trend.value, momentum.value)

        var latentScore = 0.95 * trend.value
            + 0.65 * momentum.value
            + 0.35 * position.value
            + 0.45 * volume.value
            + 0.10 * candlestick.value
            + 0.45 * trendVolumeInteraction
            + 0.30 * trendMomentumInteraction

        let riskLevel = clamp((1 - risk.value) / 2, 0, 1)
        latentScore -= 0.80 * riskLevel * (0.75 + 0.25 * max(-trend.value, 0))
        if trend.value < -0.65, momentum.value < -0.35 {
            latentScore -= 0.35
        }
        if riskLevel > 0.75 {
            latentScore -= 0.30
        }

        let unadjustedValue = Int((100 * logistic(1.15 * latentScore)).rounded())
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
            ohlcCoverage: ohlcCoverage
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
            factor(.position, position),
            factor(.volume, volume),
            factor(.candlestick, candlestick),
            factor(.risk, risk)
        ]
        let adjustments = adjustmentSummaries(
            trendVolumeInteraction: trendVolumeInteraction,
            trendMomentumInteraction: trendMomentumInteraction,
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
            adjustments: adjustments
        )
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
        let value = weightedAverage([
            (priceVersusMA20, 0.35),
            (ma20VersusMA60, 0.30),
            (normalizedSlope, 0.35)
        ])

        let summary: String
        if value > 0.45 {
            summary = "价格、均线结构与20日斜率共同指向上行"
        } else if value > 0.15 {
            summary = "中短期趋势略偏上，但一致性仍有限"
        } else if value < -0.45 {
            summary = "价格受均线压制，20日趋势明显向下"
        } else if value < -0.15 {
            summary = "趋势略偏弱，尚未形成可靠反转"
        } else {
            summary = "趋势接近横盘，方向证据不足"
        }
        return Evidence(value: value, summary: summary)
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
        let rsiEvidence = latest.rsi14.map { rsiValue($0) } ?? 0
        let value = clamp(
            0.55 * macdPosition + 0.20 * acceleration + 0.25 * rsiEvidence,
            -1,
            1
        )

        let summary: String
        if value > 0.45 {
            summary = "MACD与RSI共同显示正向动能"
        } else if value > 0.15 {
            summary = "动能正在改善，但强度尚不突出"
        } else if value < -0.45 {
            summary = "MACD与RSI显示负向动能仍强"
        } else if value < -0.15 {
            summary = "动能略偏弱，反转信号尚不充分"
        } else {
            summary = "多空动能接近平衡"
        }
        return Evidence(value: value, summary: summary)
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

    private static func volumeEvidence(points: [StockChartPoint]) -> Evidence {
        let recent = Array(points.suffix(21))
        guard recent.count >= 6 else {
            return Evidence(value: 0, summary: "成交量数据不足，按中性处理")
        }
        let volumes = recent.dropLast().compactMap(\.volume).filter { $0 > 0 }
        guard let averageVolume = average(volumes),
              let latest = recent.last,
              let latestVolume = latest.volume,
              latestVolume > 0,
              averageVolume > 0 else {
            return Evidence(value: 0, summary: "成交量覆盖不足，不参与方向判断")
        }

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
        // inconclusive, while an already elevated volume can safely confirm direction.
        let relativeVolume = max(tanh(log(max(volumeRatio, 0.05)) / 0.65), 0)
        let latestConfirmation: Double
        if dailyReturn > 0.001 {
            latestConfirmation = relativeVolume
        } else if dailyReturn < -0.001 {
            latestConfirmation = -relativeVolume
        } else {
            latestConfirmation = -abs(relativeVolume) * 0.35
        }
        let value = clamp(0.65 * balance + 0.35 * latestConfirmation, -1, 1)

        let summary: String
        if value > 0.4 {
            summary = "上涨日量能占优，资金对价格方向形成确认"
        } else if value > 0.12 {
            summary = "量价关系略偏正向，但确认强度有限"
        } else if value < -0.4 {
            summary = "下跌日量能占优，卖压确认较强"
        } else if value < -0.12 {
            summary = "量价关系略偏负向"
        } else {
            summary = "成交量没有提供明确方向确认"
        }
        return Evidence(value: value, summary: summary)
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
        riskLevel: Double,
        confidenceValue: Double
    ) -> [String] {
        var summaries: [String] = []
        if trendVolumeInteraction > 0.18 {
            summaries.append("趋势与量能形成正向共振")
        } else if trendVolumeInteraction < -0.18 {
            summaries.append("趋势与量能冲突或共同确认弱势")
        }
        if trendMomentumInteraction > 0.18 {
            summaries.append("趋势与动能方向一致")
        } else if trendMomentumInteraction < -0.18 {
            summaries.append("趋势与动能存在明显分歧")
        }
        if riskLevel > 0.45 {
            summaries.append("高波动或较深回撤对结果施加非线性惩罚")
        }
        if confidenceValue < 0.82 {
            summaries.append("数据可信度使结果向中性50分收缩")
        }
        return summaries
    }

    private static func rsiValue(_ rsi: Double) -> Double {
        if rsi <= 65 {
            return clamp(tanh((rsi - 50) / 18), -1, 1)
        }
        return clamp(1 - (rsi - 65) / 15 * 2, -1, 1)
    }

    private static func directionalAgreement(_ lhs: Double, _ rhs: Double) -> Double {
        let magnitude = min(abs(lhs), abs(rhs))
        guard magnitude >= 0.10 else { return 0 }
        if lhs * rhs > 0 {
            return lhs > 0 ? magnitude : -magnitude
        }
        return -0.45 * magnitude
    }

    private static func confidence(
        sampleCount: Int,
        volumeCoverage: Double,
        ohlcCoverage: Double
    ) -> Double {
        let sampleCoverage = 0.55 + 0.45 * clamp(
            Double(sampleCount - 30) / 120,
            0,
            1
        )
        let volumeQuality = 0.82 + 0.18 * clamp(volumeCoverage, 0, 1)
        let ohlcQuality = 0.90 + 0.10 * clamp(ohlcCoverage, 0, 1)
        return clamp(sampleCoverage * volumeQuality * ohlcQuality, 0.40, 1)
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
