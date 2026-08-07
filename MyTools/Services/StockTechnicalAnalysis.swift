import Foundation

struct StockTechnicalIndicatorPoint: Identifiable {
    let date: Date
    let movingAverage5: Double?
    let movingAverage20: Double?
    let movingAverage60: Double?
    let bollingerMiddle: Double?
    let bollingerUpper: Double?
    let bollingerLower: Double?
    let macdLine: Double
    let macdSignal: Double
    let macdHistogram: Double
    let rsi14: Double?

    var id: Date { date }
}

enum StockTechnicalIndicators {
    static func calculate(_ points: [StockChartPoint]) -> [StockTechnicalIndicatorPoint] {
        guard !points.isEmpty else { return [] }

        var ema12 = points[0].close
        var ema26 = points[0].close
        var signal = 0.0
        var initialGainTotal = 0.0
        var initialLossTotal = 0.0
        var averageGain: Double?
        var averageLoss: Double?

        return points.indices.map { index in
            let close = points[index].close
            let macdLine: Double
            if index == 0 {
                macdLine = 0
            } else {
                ema12 = exponentialMovingAverage(previous: ema12, value: close, period: 12)
                ema26 = exponentialMovingAverage(previous: ema26, value: close, period: 26)
                macdLine = ema12 - ema26
                signal = exponentialMovingAverage(previous: signal, value: macdLine, period: 9)

                let change = close - points[index - 1].close
                let gain = max(change, 0)
                let loss = max(-change, 0)
                if index <= 14 {
                    initialGainTotal += gain
                    initialLossTotal += loss
                    if index == 14 {
                        averageGain = initialGainTotal / 14
                        averageLoss = initialLossTotal / 14
                    }
                } else if let previousAverageGain = averageGain,
                          let previousAverageLoss = averageLoss {
                    averageGain = (previousAverageGain * 13 + gain) / 14
                    averageLoss = (previousAverageLoss * 13 + loss) / 14
                }
            }

            let bollingerWindow = values(in: points, endingAt: index, period: 20)
            let bollingerMiddle = average(bollingerWindow)
            let bollingerDeviation: Double? = bollingerMiddle.map { middle in
                let variance = bollingerWindow.reduce(0) {
                    $0 + pow($1 - middle, 2)
                } / Double(bollingerWindow.count)
                return sqrt(variance)
            }
            let bollingerUpper: Double?
            let bollingerLower: Double?
            if let bollingerMiddle, let bollingerDeviation {
                bollingerUpper = bollingerMiddle + 2 * bollingerDeviation
                bollingerLower = bollingerMiddle - 2 * bollingerDeviation
            } else {
                bollingerUpper = nil
                bollingerLower = nil
            }

            return StockTechnicalIndicatorPoint(
                date: points[index].date,
                movingAverage5: movingAverage(in: points, endingAt: index, period: 5),
                movingAverage20: movingAverage(in: points, endingAt: index, period: 20),
                movingAverage60: movingAverage(in: points, endingAt: index, period: 60),
                bollingerMiddle: bollingerMiddle,
                bollingerUpper: bollingerUpper,
                bollingerLower: bollingerLower,
                macdLine: macdLine,
                macdSignal: signal,
                macdHistogram: 2 * (macdLine - signal),
                rsi14: relativeStrengthIndex(
                    averageGain: averageGain,
                    averageLoss: averageLoss
                )
            )
        }
    }

    private static func exponentialMovingAverage(
        previous: Double,
        value: Double,
        period: Int
    ) -> Double {
        let multiplier = 2.0 / Double(period + 1)
        return (value - previous) * multiplier + previous
    }

    private static func movingAverage(
        in points: [StockChartPoint],
        endingAt index: Int,
        period: Int
    ) -> Double? {
        average(values(in: points, endingAt: index, period: period))
    }

    private static func values(
        in points: [StockChartPoint],
        endingAt index: Int,
        period: Int
    ) -> [Double] {
        guard index + 1 >= period else { return [] }
        let start = index - period + 1
        return points[start...index].map(\.close)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func relativeStrengthIndex(
        averageGain: Double?,
        averageLoss: Double?
    ) -> Double? {
        guard let averageGain, let averageLoss else { return nil }
        if averageGain == 0, averageLoss == 0 { return 50 }
        if averageLoss == 0 { return 100 }
        let relativeStrength = averageGain / averageLoss
        return 100 - 100 / (1 + relativeStrength)
    }
}

struct StockTechnicalScore: Equatable, Sendable {
    enum Confidence: String, Sendable {
        case high = "高"
        case medium = "中"
        case limited = "有限"
    }

    let value: Int
    let date: Date
    let modelVersion: String
    let sampleCount: Int
    let confidence: Confidence
    let components: [StockTechnicalScoreComponent]

    var levelTitle: String {
        switch value {
        case 80...: return "技术信号很强"
        case 65..<80: return "技术信号偏强"
        case 50..<65: return "技术信号中性"
        case 35..<50: return "技术信号偏弱"
        default: return "技术风险较高"
        }
    }
}

struct StockTechnicalScoreComponent: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case movingAverage
        case trend
        case macd
        case rsi
        case candlestick
        case bollinger
        case volume

        var title: String {
            switch self {
            case .movingAverage: return "均线"
            case .trend: return "价格趋势"
            case .macd: return "MACD"
            case .rsi: return "RSI"
            case .candlestick: return "K 线"
            case .bollinger: return "布林线"
            case .volume: return "成交量"
            }
        }

        var maximumScore: Int {
            switch self {
            case .movingAverage, .volume: return 20
            case .trend, .macd: return 15
            case .rsi, .candlestick, .bollinger: return 10
            }
        }
    }

    let kind: Kind
    let score: Double
    let summary: String

    var id: Kind { kind }
    var roundedScore: Int { Int(score.rounded()) }
    var maximumScore: Int { kind.maximumScore }
}

enum StockTechnicalScoring {
    static func calculate(
        _ rawPoints: [StockChartPoint],
        modelVersion: String = "technical-1.0.0"
    ) -> StockTechnicalScore? {
        let points = rawPoints
            .filter { $0.close > 0 }
            .sorted { $0.date < $1.date }
        guard points.count >= 30, let latest = points.last else { return nil }

        let indicators = StockTechnicalIndicators.calculate(points)
        let components = [
            movingAverageComponent(points: points, indicators: indicators),
            trendComponent(points: points),
            macdComponent(indicators: indicators),
            rsiComponent(points: points, indicators: indicators),
            candlestickComponent(points: points),
            bollingerComponent(points: points, indicators: indicators),
            volumeComponent(points: points)
        ]
        let value = Int(clamp(components.reduce(0) { $0 + $1.score }, 0, 100).rounded())
        let volumeCoverage = Double(points.compactMap(\.volume).count) / Double(points.count)
        let confidence: StockTechnicalScore.Confidence
        if points.count >= 120, volumeCoverage >= 0.8 {
            confidence = .high
        } else if points.count >= 60 {
            confidence = .medium
        } else {
            confidence = .limited
        }

        return StockTechnicalScore(
            value: value,
            date: latest.date,
            modelVersion: modelVersion,
            sampleCount: points.count,
            confidence: confidence,
            components: components
        )
    }

    private static func movingAverageComponent(
        points: [StockChartPoint],
        indicators: [StockTechnicalIndicatorPoint]
    ) -> StockTechnicalScoreComponent {
        let latestClose = points.last?.close ?? 0
        let ma5 = averageClose(points, endingAt: points.count - 1, period: 5)
        let ma10 = averageClose(points, endingAt: points.count - 1, period: 10)
        let ma20 = indicators.last?.movingAverage20
        let ma60 = indicators.last?.movingAverage60
        let earlierIndex = max(0, points.count - 6)
        let earlierMA20 = averageClose(points, endingAt: earlierIndex, period: 20)
        let earlierMA60 = averageClose(points, endingAt: earlierIndex, period: 60)

        let score = flagScore(compare(latestClose, greaterThan: ma5), weight: 2)
            + flagScore(compare(ma5, greaterThan: ma10), weight: 4)
            + flagScore(compare(ma10, greaterThan: ma20), weight: 4)
            + flagScore(compare(ma20, greaterThan: ma60), weight: 4)
            + flagScore(compare(ma20, greaterThan: earlierMA20), weight: 3)
            + flagScore(compare(ma60, greaterThan: earlierMA60), weight: 3)

        let summary: String
        if let ma5, let ma10, let ma20, let ma60,
           latestClose > ma5, ma5 > ma10, ma10 > ma20, ma20 > ma60 {
            summary = "收盘价与 MA5、MA10、MA20、MA60 呈多头排列"
        } else if let ma5, let ma10, let ma20, let ma60,
                  latestClose < ma5, ma5 < ma10, ma10 < ma20, ma20 < ma60 {
            summary = "均线呈空头排列，价格仍受长期均线压制"
        } else if let ma20, latestClose >= ma20 {
            summary = "价格位于 MA20 上方，但均线尚未形成完整多头排列"
        } else {
            summary = "均线处于整理或偏弱状态"
        }
        return component(.movingAverage, score: score, summary: summary)
    }

    private static func trendComponent(points: [StockChartPoint]) -> StockTechnicalScoreComponent {
        let window = Array(points.suffix(20))
        let regression = linearRegression(window.map(\.close))
        let strength = 0.35 + 0.65 * regression.rSquared
        let direction = clamp(0.5 + regression.slopeRatio / 0.006, 0, 1)
        let slopeScore = 5 + (direction - 0.5) * 10 * strength
        let latestClose = window.last?.close ?? 0
        let prior = window.dropLast().map(\.close)
        let priorLow = prior.min() ?? latestClose
        let priorHigh = prior.max() ?? latestClose
        let positionScore: Double
        if latestClose > priorHigh {
            positionScore = 5
        } else if priorHigh > priorLow {
            positionScore = clamp((latestClose - priorLow) / (priorHigh - priorLow), 0, 1) * 5
        } else {
            positionScore = 2.5
        }

        let summary: String
        if latestClose > priorHigh {
            summary = "价格突破此前 20 日高点，短期趋势向上"
        } else if regression.slopeRatio > 0.001 {
            summary = "20 日价格回归趋势上行，走势一致性为 \(percent(regression.rSquared))"
        } else if regression.slopeRatio < -0.001 {
            summary = "20 日价格回归趋势下行，尚未出现有效突破"
        } else {
            summary = "20 日价格趋势接近横盘"
        }
        return component(.trend, score: slopeScore + positionScore, summary: summary)
    }

    private static func macdComponent(
        indicators: [StockTechnicalIndicatorPoint]
    ) -> StockTechnicalScoreComponent {
        guard let latest = indicators.last else {
            return component(.macd, score: 7.5, summary: "MACD 数据不足，按中性处理")
        }
        let previous = indicators.dropLast().last
        var score = latest.macdLine > latest.macdSignal ? 6.0 : 0
        score += latest.macdLine > 0 ? 5 : 0
        if let previous, latest.macdHistogram > previous.macdHistogram {
            score += latest.macdHistogram >= 0 ? 4 : 2.5
        } else if latest.macdHistogram >= 0 {
            score += 2
        }

        let summary: String
        if let previous,
           latest.macdLine > latest.macdSignal,
           previous.macdLine <= previous.macdSignal {
            summary = "MACD 刚形成金叉，短期动能转强"
        } else if latest.macdLine > latest.macdSignal,
                  latest.macdHistogram > (previous?.macdHistogram ?? latest.macdHistogram) {
            summary = "MACD 位于信号线上方，正向动能增强"
        } else if latest.macdLine > latest.macdSignal {
            summary = "MACD 仍在信号线上方，但正向动能有所放缓"
        } else if let previous, latest.macdHistogram > previous.macdHistogram {
            summary = "MACD 仍偏弱，但负向动能正在收敛"
        } else {
            summary = "MACD 位于信号线下方，动能偏弱"
        }
        return component(.macd, score: score, summary: summary)
    }

    private static func rsiComponent(
        points: [StockChartPoint],
        indicators: [StockTechnicalIndicatorPoint]
    ) -> StockTechnicalScoreComponent {
        guard let latestRSI = indicators.last?.rsi14 else {
            return component(.rsi, score: 5, summary: "RSI 数据不足，按中性处理")
        }
        let previousRSI = indicators.dropLast().last?.rsi14 ?? latestRSI
        var score: Double
        switch latestRSI {
        case ..<20: score = 1
        case 20..<30: score = 3
        case 30..<45: score = 7
        case 45...65: score = 10
        case 65...70: score = 8
        case 70...80: score = 4
        default: score = 1
        }
        if latestRSI < 40, latestRSI > previousRSI {
            score = min(10, score + 2)
        }

        let comparisonOffset = min(10, points.count - 1)
        let comparisonIndex = points.count - 1 - comparisonOffset
        let comparisonRSI = indicators[comparisonIndex].rsi14
        let showsBullishDivergence = comparisonRSI.map {
            points.last!.close < points[comparisonIndex].close
                && latestRSI > $0 + 3
                && latestRSI < 45
        } ?? false

        let summary: String
        if showsBullishDivergence {
            summary = "价格走弱但 RSI 抬升，出现底背离迹象"
        } else if latestRSI > 70 {
            summary = "RSI 为 \(number(latestRSI))，处于偏热区间"
        } else if latestRSI < 30 {
            summary = latestRSI > previousRSI
                ? "RSI 从超卖区回升，但反转仍需确认"
                : "RSI 仍在超卖区下行，弱势尚未扭转"
        } else {
            summary = "RSI 为 \(number(latestRSI))，处于相对健康区间"
        }
        return component(.rsi, score: score, summary: summary)
    }

    private static func candlestickComponent(
        points: [StockChartPoint]
    ) -> StockTechnicalScoreComponent {
        guard let latest = points.last else {
            return component(.candlestick, score: 5, summary: "K 线数据不足，按中性处理")
        }
        let previous = points.dropLast().last
        let third = points.dropLast(2).last
        let latestBody = abs(latest.close - latest.open)
        let latestRange = max(latest.high - latest.low, 0.000_001)
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
        let isMorningStar = morningStar(third: third, middle: previous, latest: latest)
        let isEveningStar = eveningStar(third: third, middle: previous, latest: latest)

        let score: Double
        let summary: String
        if isMorningStar {
            score = 10
            summary = "近三日形成启明星式反转形态"
        } else if isBullishEngulfing {
            score = 10
            summary = "最新 K 线形成看涨吞没形态"
        } else if isHammer {
            score = 9
            summary = "相对低位出现锤子线，下方承接增强"
        } else if isEveningStar {
            score = 0
            summary = "近三日形成黄昏星式转弱形态"
        } else if isBearishEngulfing {
            score = 0
            summary = "最新 K 线形成看跌吞没形态"
        } else if isShootingStar {
            score = 1
            summary = "相对高位出现长上影，抛压风险增加"
        } else {
            let direction = (latest.close - latest.open) / latestRange
            let closePosition = (latest.close - latest.low) / latestRange
            score = clamp(5 + direction * 3 + (closePosition - 0.5) * 2, 0, 10)
            summary = latest.close >= latest.open
                ? "最新 K 线偏强，但未形成明确反转形态"
                : "最新 K 线偏弱，尚无明确止跌形态"
        }
        return component(.candlestick, score: score, summary: summary)
    }

    private static func bollingerComponent(
        points: [StockChartPoint],
        indicators: [StockTechnicalIndicatorPoint]
    ) -> StockTechnicalScoreComponent {
        guard let latestIndicator = indicators.last,
              let latestClose = points.last?.close,
              let middle = latestIndicator.bollingerMiddle,
              let upper = latestIndicator.bollingerUpper,
              let lower = latestIndicator.bollingerLower,
              upper > lower else {
            return component(.bollinger, score: 5, summary: "布林线数据不足，按中性处理")
        }
        let earlierIndex = max(0, indicators.count - 6)
        let earlierMiddle = indicators[earlierIndex].bollingerMiddle ?? middle
        let middleIsRising = middle > earlierMiddle
        let percentB = (latestClose - lower) / (upper - lower)
        var score: Double
        switch percentB {
        case 0.5...0.85:
            score = middleIsRising ? 10 : 8
        case 0.35..<0.5:
            score = middleIsRising ? 7 : 5
        case 0...0.35:
            score = middleIsRising ? 5 : 3
        case 0.85...1:
            score = middleIsRising ? 7 : 5
        case 1...:
            score = middleIsRising ? 5 : 3
        default:
            score = middleIsRising ? 3 : 1
        }

        let summary: String
        if percentB > 1 {
            summary = "价格已越过布林上轨，趋势较强但短期追高风险增加"
        } else if percentB >= 0.5, percentB <= 0.85, middleIsRising {
            summary = "价格位于中轨上方且中轨上行，通道结构偏强"
        } else if percentB < 0 {
            summary = "价格跌破布林下轨，弱势与波动风险较高"
        } else if latestClose < middle {
            summary = "价格位于布林中轨下方，尚未恢复通道强势区"
        } else {
            summary = "价格位于布林中轨上方，但中轨方向尚不明确"
        }
        return component(.bollinger, score: score, summary: summary)
    }

    private static func volumeComponent(points: [StockChartPoint]) -> StockTechnicalScoreComponent {
        guard points.count >= 2,
              let latest = points.last,
              let latestVolume = latest.volume,
              latestVolume > 0 else {
            return component(.volume, score: 10, summary: "成交量数据不足，按中性处理")
        }
        let priorPoints = points.dropLast().suffix(20)
        let priorVolumes = priorPoints.compactMap(\.volume).filter { $0 > 0 }
        guard let averageVolume = average(priorVolumes), averageVolume > 0 else {
            return component(.volume, score: 10, summary: "成交量样本不足，按中性处理")
        }
        let ratio = latestVolume / averageVolume
        let previousClose = points[points.count - 2].close
        let returnRate = previousClose == 0 ? 0 : (latest.close - previousClose) / previousClose
        let previousHigh = priorPoints.map(\.close).max() ?? latest.close
        var score: Double
        let summary: String

        if abs(returnRate) < 0.003, ratio >= 1.8 {
            score = 2
            summary = "量比 \(number(ratio))，高量但价格停滞，需警惕分歧"
        } else if returnRate > 0 {
            if latest.close > previousHigh, ratio >= 1.5 {
                score = 20
                summary = "放量突破近 20 日高点，量价确认较强"
            } else if ratio >= 1.5 {
                score = 17
                summary = "上涨同时明显放量，资金确认较强"
            } else if ratio >= 1 {
                score = 14
                summary = "上涨且成交量不低于 20 日均量"
            } else {
                score = 7
                summary = "价格上涨但成交量收缩，确认度有限"
            }
        } else if ratio >= 1.5 {
            score = 2
            summary = "下跌同时明显放量，卖压较强"
        } else if ratio <= 0.8 {
            score = 11
            summary = "回调时成交量收缩，抛压相对有限"
        } else {
            score = 6
            summary = "下跌且成交量未明显收缩"
        }

        let recent = Array(points.suffix(20))
        let upVolumes = recent.indices.dropFirst().compactMap { index in
            recent[index].close >= recent[index - 1].close ? recent[index].volume : nil
        }.filter { $0 > 0 }
        let downVolumes = recent.indices.dropFirst().compactMap { index in
            recent[index].close < recent[index - 1].close ? recent[index].volume : nil
        }.filter { $0 > 0 }
        if let upAverage = average(upVolumes), let downAverage = average(downVolumes) {
            if upAverage > downAverage * 1.15 {
                score += 2
            } else if downAverage > upAverage * 1.15 {
                score -= 2
            }
        }
        return component(.volume, score: score, summary: summary)
    }

    private static func morningStar(
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

    private static func eveningStar(
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

    private static func averageClose(
        _ points: [StockChartPoint],
        endingAt index: Int,
        period: Int
    ) -> Double? {
        guard index >= 0, index + 1 >= period else { return nil }
        return average(points[(index - period + 1)...index].map(\.close))
    }

    private static func compare(_ lhs: Double?, greaterThan rhs: Double?) -> Bool? {
        guard let lhs, let rhs else { return nil }
        return lhs > rhs
    }

    private static func compare(_ lhs: Double, greaterThan rhs: Double?) -> Bool? {
        guard let rhs else { return nil }
        return lhs > rhs
    }

    private static func flagScore(_ value: Bool?, weight: Double) -> Double {
        guard let value else { return weight / 2 }
        return value ? weight : 0
    }

    private static func component(
        _ kind: StockTechnicalScoreComponent.Kind,
        score: Double,
        summary: String
    ) -> StockTechnicalScoreComponent {
        StockTechnicalScoreComponent(
            kind: kind,
            score: clamp(score, 0, Double(kind.maximumScore)),
            summary: summary
        )
    }

    private static func linearRegression(_ values: [Double]) -> (slopeRatio: Double, rSquared: Double) {
        guard values.count >= 2 else { return (0, 0) }
        let count = Double(values.count)
        let meanX = Double(values.count - 1) / 2
        let meanY = values.reduce(0, +) / count
        guard meanY != 0 else { return (0, 0) }
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
        guard varianceX > 0 else { return (0, 0) }
        let slope = covariance / varianceX
        let rSquared = varianceY > 0
            ? clamp(pow(covariance, 2) / (varianceX * varianceY), 0, 1)
            : 0
        return (slope / meanY, rSquared)
    }

    private static func average<S: Sequence>(_ values: S) -> Double? where S.Element == Double {
        let values = Array(values)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
