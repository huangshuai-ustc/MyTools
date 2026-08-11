#if MYTOOLS_FEATURE_STOCKS
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

#endif
