#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockTechnicalIndicatorPoint: Identifiable, Codable, Equatable, Sendable {
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
    let rsi30: Double?
    let stochasticK: Double?
    let stochasticD: Double?
    let stochasticJ: Double?
    let williamsR: Double?
    let commodityChannelIndex: Double?
    let positiveDirectionalIndex: Double?
    let negativeDirectionalIndex: Double?
    let averageDirectionalIndex: Double?
    let momentum: Double?
    let momentumAverage: Double?
    let trix: Double?
    let trixSignal: Double?
    let onBalanceVolume: Double?
    let moneyFlowIndex: Double?
    let accumulationDistribution: Double?
    let chaikinMoneyFlow: Double?
    let psychologicalLine: Double?
    let rateOfChange: Double?

    var id: Date { date }

    init(
        date: Date,
        movingAverage5: Double?,
        movingAverage20: Double?,
        movingAverage60: Double?,
        bollingerMiddle: Double?,
        bollingerUpper: Double?,
        bollingerLower: Double?,
        macdLine: Double,
        macdSignal: Double,
        macdHistogram: Double,
        rsi14: Double?,
        rsi30: Double?,
        stochasticK: Double? = nil,
        stochasticD: Double? = nil,
        stochasticJ: Double? = nil,
        williamsR: Double? = nil,
        commodityChannelIndex: Double? = nil,
        positiveDirectionalIndex: Double? = nil,
        negativeDirectionalIndex: Double? = nil,
        averageDirectionalIndex: Double? = nil,
        momentum: Double? = nil,
        momentumAverage: Double? = nil,
        trix: Double? = nil,
        trixSignal: Double? = nil,
        onBalanceVolume: Double? = nil,
        moneyFlowIndex: Double? = nil,
        accumulationDistribution: Double? = nil,
        chaikinMoneyFlow: Double? = nil,
        psychologicalLine: Double? = nil,
        rateOfChange: Double? = nil
    ) {
        self.date = date
        self.movingAverage5 = movingAverage5
        self.movingAverage20 = movingAverage20
        self.movingAverage60 = movingAverage60
        self.bollingerMiddle = bollingerMiddle
        self.bollingerUpper = bollingerUpper
        self.bollingerLower = bollingerLower
        self.macdLine = macdLine
        self.macdSignal = macdSignal
        self.macdHistogram = macdHistogram
        self.rsi14 = rsi14
        self.rsi30 = rsi30
        self.stochasticK = stochasticK
        self.stochasticD = stochasticD
        self.stochasticJ = stochasticJ
        self.williamsR = williamsR
        self.commodityChannelIndex = commodityChannelIndex
        self.positiveDirectionalIndex = positiveDirectionalIndex
        self.negativeDirectionalIndex = negativeDirectionalIndex
        self.averageDirectionalIndex = averageDirectionalIndex
        self.momentum = momentum
        self.momentumAverage = momentumAverage
        self.trix = trix
        self.trixSignal = trixSignal
        self.onBalanceVolume = onBalanceVolume
        self.moneyFlowIndex = moneyFlowIndex
        self.accumulationDistribution = accumulationDistribution
        self.chaikinMoneyFlow = chaikinMoneyFlow
        self.psychologicalLine = psychologicalLine
        self.rateOfChange = rateOfChange
    }

    private enum CodingKeys: String, CodingKey {
        case date, movingAverage5, movingAverage20, movingAverage60
        case bollingerMiddle, bollingerUpper, bollingerLower
        case macdLine, macdSignal, macdHistogram, rsi14, rsi30
        case stochasticK, stochasticD, stochasticJ, williamsR
        case commodityChannelIndex, positiveDirectionalIndex
        case negativeDirectionalIndex, averageDirectionalIndex
        case momentum, momentumAverage, trix, trixSignal
        case onBalanceVolume, moneyFlowIndex, accumulationDistribution
        case chaikinMoneyFlow, psychologicalLine, rateOfChange
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            date: try container.decode(Date.self, forKey: .date),
            movingAverage5: try container.decodeIfPresent(Double.self, forKey: .movingAverage5),
            movingAverage20: try container.decodeIfPresent(Double.self, forKey: .movingAverage20),
            movingAverage60: try container.decodeIfPresent(Double.self, forKey: .movingAverage60),
            bollingerMiddle: try container.decodeIfPresent(Double.self, forKey: .bollingerMiddle),
            bollingerUpper: try container.decodeIfPresent(Double.self, forKey: .bollingerUpper),
            bollingerLower: try container.decodeIfPresent(Double.self, forKey: .bollingerLower),
            macdLine: try container.decodeIfPresent(Double.self, forKey: .macdLine) ?? 0,
            macdSignal: try container.decodeIfPresent(Double.self, forKey: .macdSignal) ?? 0,
            macdHistogram: try container.decodeIfPresent(Double.self, forKey: .macdHistogram) ?? 0,
            rsi14: try container.decodeIfPresent(Double.self, forKey: .rsi14),
            rsi30: try container.decodeIfPresent(Double.self, forKey: .rsi30),
            stochasticK: try container.decodeIfPresent(Double.self, forKey: .stochasticK),
            stochasticD: try container.decodeIfPresent(Double.self, forKey: .stochasticD),
            stochasticJ: try container.decodeIfPresent(Double.self, forKey: .stochasticJ),
            williamsR: try container.decodeIfPresent(Double.self, forKey: .williamsR),
            commodityChannelIndex: try container.decodeIfPresent(Double.self, forKey: .commodityChannelIndex),
            positiveDirectionalIndex: try container.decodeIfPresent(Double.self, forKey: .positiveDirectionalIndex),
            negativeDirectionalIndex: try container.decodeIfPresent(Double.self, forKey: .negativeDirectionalIndex),
            averageDirectionalIndex: try container.decodeIfPresent(Double.self, forKey: .averageDirectionalIndex),
            momentum: try container.decodeIfPresent(Double.self, forKey: .momentum),
            momentumAverage: try container.decodeIfPresent(Double.self, forKey: .momentumAverage),
            trix: try container.decodeIfPresent(Double.self, forKey: .trix),
            trixSignal: try container.decodeIfPresent(Double.self, forKey: .trixSignal),
            onBalanceVolume: try container.decodeIfPresent(Double.self, forKey: .onBalanceVolume),
            moneyFlowIndex: try container.decodeIfPresent(Double.self, forKey: .moneyFlowIndex),
            accumulationDistribution: try container.decodeIfPresent(Double.self, forKey: .accumulationDistribution),
            chaikinMoneyFlow: try container.decodeIfPresent(Double.self, forKey: .chaikinMoneyFlow),
            psychologicalLine: try container.decodeIfPresent(Double.self, forKey: .psychologicalLine),
            rateOfChange: try container.decodeIfPresent(Double.self, forKey: .rateOfChange)
        )
    }

    func replacingRSI(with14 rsi14: Double?, and30 rsi30: Double?) -> Self {
        replacing(date: date, rsi14: rsi14, rsi30: rsi30)
    }

    func replacing(date: Date) -> Self {
        replacing(date: date, rsi14: rsi14, rsi30: rsi30)
    }

    private func replacing(date: Date, rsi14: Double?, rsi30: Double?) -> Self {
        Self(
            date: date,
            movingAverage5: movingAverage5,
            movingAverage20: movingAverage20,
            movingAverage60: movingAverage60,
            bollingerMiddle: bollingerMiddle,
            bollingerUpper: bollingerUpper,
            bollingerLower: bollingerLower,
            macdLine: macdLine,
            macdSignal: macdSignal,
            macdHistogram: macdHistogram,
            rsi14: rsi14,
            rsi30: rsi30,
            stochasticK: stochasticK,
            stochasticD: stochasticD,
            stochasticJ: stochasticJ,
            williamsR: williamsR,
            commodityChannelIndex: commodityChannelIndex,
            positiveDirectionalIndex: positiveDirectionalIndex,
            negativeDirectionalIndex: negativeDirectionalIndex,
            averageDirectionalIndex: averageDirectionalIndex,
            momentum: momentum,
            momentumAverage: momentumAverage,
            trix: trix,
            trixSignal: trixSignal,
            onBalanceVolume: onBalanceVolume,
            moneyFlowIndex: moneyFlowIndex,
            accumulationDistribution: accumulationDistribution,
            chaikinMoneyFlow: chaikinMoneyFlow,
            psychologicalLine: psychologicalLine,
            rateOfChange: rateOfChange
        )
    }
}

enum StockTechnicalIndicators {
    private static let directionalPeriod = 14

    static func calculate(_ points: [StockChartPoint]) -> [StockTechnicalIndicatorPoint] {
        guard !points.isEmpty else { return [] }

        var ema12 = points[0].close
        var ema26 = points[0].close
        var signal = 0.0
        var ema1 = points[0].close
        var ema2 = points[0].close
        var ema3 = points[0].close
        var previousEMA3 = points[0].close
        var trixValues: [Double?] = Array(repeating: nil, count: points.count)
        var momentumValues: [Double?] = Array(repeating: nil, count: points.count)
        var initialGainTotal = 0.0
        var initialLossTotal = 0.0
        var averageGain: Double?
        var averageLoss: Double?
        var initialGainTotal30 = 0.0
        var initialLossTotal30 = 0.0
        var averageGain30: Double?
        var averageLoss30: Double?
        var stochasticK = 50.0
        var stochasticD = 50.0
        var onBalanceVolume = 0.0
        var accumulationDistribution = 0.0
        var smoothedTrueRange = 0.0
        var smoothedPositiveDM = 0.0
        var smoothedNegativeDM = 0.0
        var dxSeedTotal = 0.0
        var dxSeedCount = 0
        var averageDirectionalIndex: Double?

        return points.indices.map { index in
            let point = points[index]
            let close = point.close
            let macdLine: Double
            if index == 0 {
                macdLine = 0
            } else {
                ema12 = exponentialMovingAverage(previous: ema12, value: close, period: 12)
                ema26 = exponentialMovingAverage(previous: ema26, value: close, period: 26)
                macdLine = ema12 - ema26
                signal = exponentialMovingAverage(previous: signal, value: macdLine, period: 9)

                let change = close - points[index - 1].close
                updateWilderRSI(index: index, period: 14, gain: max(change, 0), loss: max(-change, 0), initialGainTotal: &initialGainTotal, initialLossTotal: &initialLossTotal, averageGain: &averageGain, averageLoss: &averageLoss)
                updateWilderRSI(index: index, period: 30, gain: max(change, 0), loss: max(-change, 0), initialGainTotal: &initialGainTotal30, initialLossTotal: &initialLossTotal30, averageGain: &averageGain30, averageLoss: &averageLoss30)
            }

            let bollingerWindow = closeValues(in: points, endingAt: index, period: 20)
            let bollingerMiddle = average(bollingerWindow)
            let bollingerDeviation = bollingerMiddle.map { middle in
                sqrt(bollingerWindow.reduce(0) { $0 + pow($1 - middle, 2) } / Double(bollingerWindow.count))
            }
            let stochastic = stochasticValues(in: points, endingAt: index, period: 9)
            if let raw = stochastic.raw {
                stochasticK = (2 * stochasticK + raw) / 3
                stochasticD = (2 * stochasticD + stochasticK) / 3
            }
            let directional = directionalValues(in: points, at: index, smoothedTrueRange: &smoothedTrueRange, smoothedPositiveDM: &smoothedPositiveDM, smoothedNegativeDM: &smoothedNegativeDM, dxSeedTotal: &dxSeedTotal, dxSeedCount: &dxSeedCount, averageDirectionalIndex: &averageDirectionalIndex)

            if index > 0 {
                ema1 = exponentialMovingAverage(previous: ema1, value: close, period: 30)
                ema2 = exponentialMovingAverage(previous: ema2, value: ema1, period: 30)
                ema3 = exponentialMovingAverage(previous: ema3, value: ema2, period: 30)
            }
            if index >= 87, previousEMA3 != 0 {
                trixValues[index] = (ema3 / previousEMA3 - 1) * 100
            }
            previousEMA3 = ema3
            if index >= 10 { momentumValues[index] = close - points[index - 10].close }

            if index > 0, let volume = point.volume, volume.isFinite {
                if close > points[index - 1].close { onBalanceVolume += volume }
                else if close < points[index - 1].close { onBalanceVolume -= volume }
            }
            if let volume = point.volume, volume.isFinite {
                let range = point.high - point.low
                let multiplier = range == 0 ? 0 : ((close - point.low) - (point.high - close)) / range
                accumulationDistribution += multiplier * volume
            }

            return StockTechnicalIndicatorPoint(
                date: point.date,
                movingAverage5: movingAverage(in: points, endingAt: index, period: 5),
                movingAverage20: movingAverage(in: points, endingAt: index, period: 20),
                movingAverage60: movingAverage(in: points, endingAt: index, period: 60),
                bollingerMiddle: bollingerMiddle,
                bollingerUpper: paired(bollingerMiddle, bollingerDeviation).map {
                    $0.0 + 2 * $0.1
                },
                bollingerLower: paired(bollingerMiddle, bollingerDeviation).map {
                    $0.0 - 2 * $0.1
                },
                macdLine: macdLine,
                macdSignal: signal,
                macdHistogram: 2 * (macdLine - signal),
                rsi14: relativeStrengthIndex(averageGain: averageGain, averageLoss: averageLoss),
                rsi30: relativeStrengthIndex(averageGain: averageGain30, averageLoss: averageLoss30),
                stochasticK: stochastic.raw.map { _ in stochasticK },
                stochasticD: stochastic.raw.map { _ in stochasticD },
                stochasticJ: stochastic.raw.map { _ in 3 * stochasticK - 2 * stochasticD },
                williamsR: williamsR(in: points, endingAt: index, period: 14),
                commodityChannelIndex: cci(in: points, endingAt: index, period: 14),
                positiveDirectionalIndex: directional.positive,
                negativeDirectionalIndex: directional.negative,
                averageDirectionalIndex: directional.adx,
                momentum: momentumValues[index],
                momentumAverage: averageOptional(momentumValues, endingAt: index, period: 10),
                trix: trixValues[index],
                trixSignal: averageOptional(trixValues, endingAt: index, period: 9),
                onBalanceVolume: point.volume == nil ? nil : onBalanceVolume,
                moneyFlowIndex: moneyFlowIndex(in: points, endingAt: index, period: 14),
                accumulationDistribution: point.volume == nil ? nil : accumulationDistribution,
                chaikinMoneyFlow: chaikinMoneyFlow(in: points, endingAt: index, period: 21),
                psychologicalLine: psychologicalLine(in: points, endingAt: index, period: 12),
                rateOfChange: rateOfChange(in: points, endingAt: index, period: 10)
            )
        }
    }

    private static func updateWilderRSI(index: Int, period: Int, gain: Double, loss: Double, initialGainTotal: inout Double, initialLossTotal: inout Double, averageGain: inout Double?, averageLoss: inout Double?) {
        if index <= period {
            initialGainTotal += gain
            initialLossTotal += loss
            if index == period {
                averageGain = initialGainTotal / Double(period)
                averageLoss = initialLossTotal / Double(period)
            }
        } else if let previousGain = averageGain, let previousLoss = averageLoss {
            averageGain = (previousGain * Double(period - 1) + gain) / Double(period)
            averageLoss = (previousLoss * Double(period - 1) + loss) / Double(period)
        }
    }

    private static func directionalValues(in points: [StockChartPoint], at index: Int, smoothedTrueRange: inout Double, smoothedPositiveDM: inout Double, smoothedNegativeDM: inout Double, dxSeedTotal: inout Double, dxSeedCount: inout Int, averageDirectionalIndex: inout Double?) -> (positive: Double?, negative: Double?, adx: Double?) {
        guard index > 0 else { return (nil, nil, nil) }
        let point = points[index]
        let previous = points[index - 1]
        let trueRange = max(point.high - point.low, abs(point.high - previous.close), abs(point.low - previous.close))
        let upMove = point.high - previous.high
        let downMove = previous.low - point.low
        let positiveDM = upMove > downMove && upMove > 0 ? upMove : 0
        let negativeDM = downMove > upMove && downMove > 0 ? downMove : 0
        if index <= directionalPeriod {
            smoothedTrueRange += trueRange
            smoothedPositiveDM += positiveDM
            smoothedNegativeDM += negativeDM
        } else {
            let period = Double(directionalPeriod)
            smoothedTrueRange = smoothedTrueRange - smoothedTrueRange / period + trueRange
            smoothedPositiveDM = smoothedPositiveDM - smoothedPositiveDM / period + positiveDM
            smoothedNegativeDM = smoothedNegativeDM - smoothedNegativeDM / period + negativeDM
        }
        guard index >= directionalPeriod, smoothedTrueRange > 0 else { return (nil, nil, nil) }
        let positive = 100 * smoothedPositiveDM / smoothedTrueRange
        let negative = 100 * smoothedNegativeDM / smoothedTrueRange
        let sum = positive + negative
        let dx = sum == 0 ? 0 : 100 * abs(positive - negative) / sum
        if dxSeedCount < directionalPeriod {
            dxSeedTotal += dx
            dxSeedCount += 1
            if dxSeedCount == directionalPeriod { averageDirectionalIndex = dxSeedTotal / Double(directionalPeriod) }
        } else if let previousADX = averageDirectionalIndex {
            averageDirectionalIndex = (previousADX * Double(directionalPeriod - 1) + dx) / Double(directionalPeriod)
        }
        return (positive, negative, averageDirectionalIndex)
    }

    private static func stochasticValues(in points: [StockChartPoint], endingAt index: Int, period: Int) -> (raw: Double?, high: Double?, low: Double?) {
        guard let window = pointWindow(in: points, endingAt: index, period: period) else { return (nil, nil, nil) }
        guard let high = window.map(\.high).max(), let low = window.map(\.low).min() else { return (nil, nil, nil) }
        let spread = high - low
        return (spread == 0 ? 50 : (points[index].close - low) / spread * 100, high, low)
    }

    private static func williamsR(in points: [StockChartPoint], endingAt index: Int, period: Int) -> Double? {
        let values = stochasticValues(in: points, endingAt: index, period: period)
        guard let high = values.high, let low = values.low else { return nil }
        let spread = high - low
        return spread == 0 ? -50 : -100 * (high - points[index].close) / spread
    }

    private static func cci(in points: [StockChartPoint], endingAt index: Int, period: Int) -> Double? {
        guard let window = pointWindow(in: points, endingAt: index, period: period) else { return nil }
        let typicalPrices = window.map { typicalPrice($0) }
        guard let mean = average(typicalPrices) else { return nil }
        let meanDeviation = typicalPrices.reduce(0) { $0 + abs($1 - mean) } / Double(period)
        guard meanDeviation > 0 else { return 0 }
        return (typicalPrice(points[index]) - mean) / (0.015 * meanDeviation)
    }

    private static func moneyFlowIndex(in points: [StockChartPoint], endingAt index: Int, period: Int) -> Double? {
        guard index >= period else { return nil }
        var positive = 0.0
        var negative = 0.0
        for position in (index - period + 1)...index {
            guard let volume = points[position].volume, volume.isFinite else { return nil }
            let typical = typicalPrice(points[position])
            let previousTypical = typicalPrice(points[position - 1])
            let flow = typical * volume
            if typical > previousTypical { positive += flow }
            else if typical < previousTypical { negative += flow }
        }
        if positive == 0, negative == 0 { return 50 }
        if negative == 0 { return 100 }
        return 100 - 100 / (1 + positive / negative)
    }

    private static func chaikinMoneyFlow(in points: [StockChartPoint], endingAt index: Int, period: Int) -> Double? {
        guard let window = pointWindow(in: points, endingAt: index, period: period) else { return nil }
        var volumeTotal = 0.0
        var flowTotal = 0.0
        for point in window {
            guard let volume = point.volume, volume.isFinite else { return nil }
            let range = point.high - point.low
            let multiplier = range == 0 ? 0 : ((point.close - point.low) - (point.high - point.close)) / range
            volumeTotal += volume
            flowTotal += multiplier * volume
        }
        return volumeTotal == 0 ? 0 : flowTotal / volumeTotal
    }

    private static func psychologicalLine(in points: [StockChartPoint], endingAt index: Int, period: Int) -> Double? {
        guard index >= period else { return nil }
        let risingCount = ((index - period + 1)...index).reduce(0) { result, position in
            result + (points[position].close > points[position - 1].close ? 1 : 0)
        }
        return Double(risingCount) / Double(period) * 100
    }

    private static func rateOfChange(in points: [StockChartPoint], endingAt index: Int, period: Int) -> Double? {
        guard index >= period, points[index - period].close != 0 else { return nil }
        return (points[index].close / points[index - period].close - 1) * 100
    }

    private static func exponentialMovingAverage(previous: Double, value: Double, period: Int) -> Double {
        let multiplier = 2.0 / Double(period + 1)
        return (value - previous) * multiplier + previous
    }

    private static func movingAverage(in points: [StockChartPoint], endingAt index: Int, period: Int) -> Double? {
        average(closeValues(in: points, endingAt: index, period: period))
    }

    private static func closeValues(in points: [StockChartPoint], endingAt index: Int, period: Int) -> [Double] {
        guard index + 1 >= period else { return [] }
        return points[(index - period + 1)...index].map(\.close)
    }

    private static func pointWindow(in points: [StockChartPoint], endingAt index: Int, period: Int) -> ArraySlice<StockChartPoint>? {
        guard index + 1 >= period else { return nil }
        return points[(index - period + 1)...index]
    }

    private static func averageOptional(_ values: [Double?], endingAt index: Int, period: Int) -> Double? {
        guard index + 1 >= period else { return nil }
        let unwrapped = values[(index - period + 1)...index].compactMap { $0 }
        guard unwrapped.count == period else { return nil }
        return average(unwrapped)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func typicalPrice(_ point: StockChartPoint) -> Double {
        (point.high + point.low + point.close) / 3
    }

    private static func relativeStrengthIndex(averageGain: Double?, averageLoss: Double?) -> Double? {
        guard let averageGain, let averageLoss else { return nil }
        if averageGain == 0, averageLoss == 0 { return 50 }
        if averageLoss == 0 { return 100 }
        return 100 - 100 / (1 + averageGain / averageLoss)
    }

    private static func paired(_ left: Double?, _ right: Double?) -> (Double, Double)? {
        guard let left, let right else { return nil }
        return (left, right)
    }
}

#endif
