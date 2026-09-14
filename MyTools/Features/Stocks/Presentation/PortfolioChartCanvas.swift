#if MYTOOLS_FEATURE_STOCKS
import Charts
import SwiftUI

enum PortfolioChartStyle: String, CaseIterable, Identifiable {
    case line
    case candlestick

    var id: Self { self }
    var title: String { self == .line ? "折线" : "K 线" }
}

private struct PortfolioChartPoint: Identifiable {
    let seriesID: String
    let seriesLabel: String
    let date: Date
    let value: Decimal
    let open: Decimal
    let high: Decimal
    let low: Decimal
    let x: Double
    var id: String { "\(seriesID)-\(date.timeIntervalSinceReferenceDate)" }
}

private struct PortfolioProfitPoint: Identifiable {
    let seriesID: String
    let date: Date
    let percent: Double
    let x: Double
    var id: String { "\(seriesID)-\(date.timeIntervalSinceReferenceDate)" }
}

/// A maximal run of consecutive profit points that share the same sign, plus
/// the single boundary point on either side (value 0 crossing), so adjacent
/// segments visually connect instead of leaving a gap at the zero crossing.
private struct PortfolioProfitSegment: Identifiable {
    let seriesID: String
    let isPositive: Bool?
    let points: [PortfolioProfitPoint]
    var id: String { "\(seriesID)-\(points.first?.id ?? "")" }
}

private struct PortfolioCostBasisChartPoint: Identifiable {
    let date: Date
    let cost: Double
    let x: Double
    var id: String { "\(date.timeIntervalSinceReferenceDate)" }
}

/// One horizontal run of constant holding cost between two transaction-driven
/// changes (or, for day-K, a single point in a stepped/linear polyline), so
/// the cost reference redraws per period instead of a single flat "today"
/// value once the visible range spans more than one holding-cost snapshot.
private struct PortfolioCostBasisSegment: Identifiable {
    let seriesID: String
    let cost: Double
    let points: [PortfolioCostBasisChartPoint]
    var id: String { "\(seriesID)-\(points.first?.id ?? "")" }
    var labelX: Double { points.last?.x ?? 0 }
}

private struct PortfolioChartData {
    let points: [PortfolioChartPoint]
    let renderedPoints: [PortfolioChartPoint]
    let renderedCandles: [PortfolioChartPoint]
    let dates: [Date]
    let values: [Double]
    let pointsBySeries: [String: [PortfolioChartPoint]]
    let renderedProfitPoints: [PortfolioProfitPoint]
    let profitPointsBySeries: [String: [PortfolioProfitPoint]]
    let profitPercents: [Double]
    let profitSegments: [PortfolioProfitSegment]
    let costBasisSegments: [PortfolioCostBasisSegment]
    let totalCostBasis: Double?
    let costLookupBySeries: [String: (Date) -> Decimal?]

    init(series: [PortfolioValueSeries], range: StockChartRange) {
        let preparedSeries = Dictionary(uniqueKeysWithValues: series.map { item in
            (item.id, PortfolioChartData.aggregatedPoints(item.points, market: item.market, range: range))
        })
        let orderedDates = Array(Set(preparedSeries.values.flatMap { $0.map(\.date) })).sorted()
        let xByDate = Dictionary(uniqueKeysWithValues: orderedDates.enumerated().map { ($0.element, Double($0.offset)) })
        let indexedPoints = Dictionary(uniqueKeysWithValues: series.map { item in
            let points = (preparedSeries[item.id] ?? []).compactMap { point -> PortfolioChartPoint? in
                guard let x = xByDate[point.date] else { return nil }
                return PortfolioChartPoint(
                    seriesID: item.id,
                    seriesLabel: item.label,
                    date: point.date,
                    value: point.value,
                    open: point.candleOpen,
                    high: point.candleHigh,
                    low: point.candleLow,
                    x: x
                )
            }
            return (item.id, points)
        })
        let allPoints = series.flatMap { item in
            indexedPoints[item.id] ?? []
        }
        let budgetPerSeries = max(120, 1_200 / max(series.count, 1))
        let displayPoints = series.flatMap { item in
            Self.downsample(indexedPoints[item.id] ?? [], maximumCount: budgetPerSeries)
        }
        let candlePoints = series.flatMap { item in
            Self.aggregateCandles(indexedPoints[item.id] ?? [], maximumCount: 320)
        }
        self.pointsBySeries = indexedPoints
        self.points = allPoints
        self.renderedPoints = displayPoints
        self.renderedCandles = candlePoints
        self.dates = orderedDates
        let costBasisSegments: [PortfolioCostBasisSegment] = range == .intraday ? [] : series.flatMap { item in
            Self.costBasisSegment(for: item, range: range, xByDate: xByDate)
        }
        self.costBasisSegments = costBasisSegments
        let totalCostBasis: Double? = {
            let costs = series.compactMap(\.costBasis)
            guard !costs.isEmpty else { return nil }
            return NSDecimalNumber(decimal: costs.reduce(Decimal.zero, +)).doubleValue
        }()
        self.totalCostBasis = totalCostBasis
        self.values = allPoints.flatMap {
            [$0.low, $0.high].map { NSDecimalNumber(decimal: $0).doubleValue }
        }
        let costLookupBySeries = Dictionary(uniqueKeysWithValues: series.map {
            ($0.id, Self.costLookup(for: $0.costBasisPoints))
        })
        self.costLookupBySeries = costLookupBySeries

        let indexedProfitPoints = Dictionary(uniqueKeysWithValues: series.map { item -> (String, [PortfolioProfitPoint]) in
            let costLookup = costLookupBySeries[item.id] ?? { _ in nil }
            let points = (indexedPoints[item.id] ?? []).compactMap { point -> PortfolioProfitPoint? in
                guard let costBasis = costLookup(point.date), costBasis != 0 else { return nil }
                return PortfolioProfitPoint(
                    seriesID: item.id,
                    date: point.date,
                    percent: NSDecimalNumber(decimal: (point.value - costBasis) / costBasis * 100).doubleValue,
                    x: point.x
                )
            }
            return (item.id, points)
        })
        let displayProfitPoints = series.flatMap { item in
            Self.downsampleProfit(indexedProfitPoints[item.id] ?? [], maximumCount: budgetPerSeries)
        }
        self.profitPointsBySeries = indexedProfitPoints
        self.renderedProfitPoints = displayProfitPoints
        self.profitPercents = indexedProfitPoints.values.flatMap { $0.map(\.percent) }
        self.profitSegments = series.flatMap { item in
            Self.signSegments(for: item.id, points: displayProfitPoints.filter { $0.seriesID == item.id })
        }
    }

    /// Builds a nearest-prior-date lookup over a series' point-in-time cost
    /// history, falling back to the earliest known cost for dates before the
    /// first recorded purchase (e.g. an intraday session that starts mid-day).
    private static func costLookup(for costBasisPoints: [PortfolioCostBasisPoint]) -> (Date) -> Decimal? {
        let sorted = costBasisPoints.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return { _ in nil } }
        return { date in
            var result: Decimal?
            for point in sorted {
                if point.date <= date { result = point.cost } else { break }
            }
            return result ?? sorted.first?.cost
        }
    }

    /// Splits a series' profit points into maximal runs that share the same
    /// sign, inserting the interpolated zero-crossing as a shared boundary
    /// point on both sides so adjacent segments visually connect.
    private static func signSegments(
        for seriesID: String,
        points: [PortfolioProfitPoint]
    ) -> [PortfolioProfitSegment] {
        guard !points.isEmpty else { return [] }
        var segments: [PortfolioProfitSegment] = []
        var current: [PortfolioProfitPoint] = [points[0]]
        var currentSign = sign(of: points[0].percent)
        for previous in zip(points, points.dropFirst()).map({ $0 }) {
            let (lhs, rhs) = previous
            let rhsSign = sign(of: rhs.percent)
            if rhsSign != currentSign, let crossing = zeroCrossing(from: lhs, to: rhs) {
                current.append(crossing)
                segments.append(PortfolioProfitSegment(seriesID: seriesID, isPositive: currentSign, points: current))
                current = [crossing, rhs]
                currentSign = rhsSign
            } else {
                current.append(rhs)
            }
        }
        segments.append(PortfolioProfitSegment(seriesID: seriesID, isPositive: currentSign, points: current))
        return segments
    }

    private static func sign(of percent: Double) -> Bool? {
        percent == 0 ? nil : percent > 0
    }

    private static func zeroCrossing(from lhs: PortfolioProfitPoint, to rhs: PortfolioProfitPoint) -> PortfolioProfitPoint? {
        guard lhs.percent != rhs.percent else { return nil }
        let ratio = -lhs.percent / (rhs.percent - lhs.percent)
        guard ratio > 0, ratio < 1 else { return nil }
        return PortfolioProfitPoint(
            seriesID: lhs.seriesID,
            date: lhs.date.addingTimeInterval(rhs.date.timeIntervalSince(lhs.date) * ratio),
            percent: 0,
            x: lhs.x + (rhs.x - lhs.x) * ratio
        )
    }

    /// Builds the cost-basis reference line for one series over the visible
    /// range: for `.fiveDays` (and similar short ranges) each transaction-driven
    /// change in holding cost becomes its own flat horizontal run so it can
    /// carry its own value label; for `.dayK` the cost is drawn as a
    /// continuous polyline since the holding cost can change daily; for
    /// week-K and coarser, one point per aggregated bucket mirrors
    /// `aggregatedPoints`' own bucketing so the two lines share x positions.
    private static func costBasisSegment(
        for item: PortfolioValueSeries,
        range: StockChartRange,
        xByDate: [Date: Double]
    ) -> [PortfolioCostBasisSegment] {
        guard !item.costBasisPoints.isEmpty else { return [] }
        let sortedDates = xByDate.keys.sorted()
        guard !sortedDates.isEmpty else { return [] }
        let lookup = costLookup(for: item.costBasisPoints)
        let chartPoints: [PortfolioCostBasisChartPoint] = sortedDates.compactMap { date in
            guard let x = xByDate[date], let cost = lookup(date) else { return nil }
            return PortfolioCostBasisChartPoint(date: date, cost: NSDecimalNumber(decimal: cost).doubleValue, x: x)
        }
        guard !chartPoints.isEmpty else { return [] }
        guard range == .fiveDays else {
            return [PortfolioCostBasisSegment(seriesID: item.id, cost: chartPoints.last?.cost ?? 0, points: chartPoints)]
        }
        // Split into runs of equal cost so each run can carry its own label,
        // keeping the join point shared between adjacent runs (stepEnd draws
        // the vertical transition using that shared point).
        var runs: [[PortfolioCostBasisChartPoint]] = []
        var current: [PortfolioCostBasisChartPoint] = [chartPoints[0]]
        for point in chartPoints.dropFirst() {
            if point.cost == current.last?.cost {
                current.append(point)
            } else {
                runs.append(current)
                current = [current.last!, point]
            }
        }
        runs.append(current)
        return runs.map { run in
            PortfolioCostBasisSegment(seriesID: item.id, cost: run.last?.cost ?? 0, points: run)
        }
    }


    private static func aggregatedPoints(
        _ points: [PortfolioValuePoint],
        market: StockMarket?,
        range: StockChartRange
    ) -> [PortfolioValuePoint] {
        guard !points.isEmpty, range != .intraday, range != .fiveDays, range != .dayK else {
            return points.sorted { $0.date < $1.date }
        }
        var calendar = Calendar(identifier: .gregorian)
        if let market { calendar.timeZone = StockChartSeriesProcessor.marketTimeZone(market) }
        var grouped: [Date: [PortfolioValuePoint]] = [:]
        for point in points.sorted(by: { $0.date < $1.date }) {
            let components = calendar.dateComponents([.year, .month], from: point.date)
            let bucket: Date
            switch range {
            case .weekK: bucket = calendar.dateInterval(of: .weekOfYear, for: point.date)?.start ?? point.date
            case .monthK: bucket = calendar.dateInterval(of: .month, for: point.date)?.start ?? point.date
            case .quarterK:
                let month = components.month ?? 1
                bucket = calendar.date(from: DateComponents(year: components.year, month: ((month - 1) / 3) * 3 + 1, day: 1)) ?? point.date
            case .yearK: bucket = calendar.date(from: DateComponents(year: components.year, month: 1, day: 1)) ?? point.date
            default: bucket = point.date
            }
            grouped[bucket, default: []].append(point)
        }
        return grouped.keys.sorted().compactMap { bucket in
            guard let bucketPoints = grouped[bucket]?.sorted(by: { $0.date < $1.date }),
                  let first = bucketPoints.first,
                  let last = bucketPoints.last else { return nil }
            return PortfolioValuePoint(
                date: last.date,
                value: last.value,
                open: first.candleOpen,
                high: bucketPoints.map(\.candleHigh).max(),
                low: bucketPoints.map(\.candleLow).min()
            )
        }
    }

    /// Preserve each bucket's extrema so a small rendering set keeps visible
    /// intraday spikes while selection still uses every original point.
    private static func downsample(
        _ points: [PortfolioChartPoint],
        maximumCount: Int
    ) -> [PortfolioChartPoint] {
        guard points.count > maximumCount, maximumCount >= 4 else { return points }
        let interiorPoints = points.dropFirst().dropLast()
        let bucketCount = max(1, (maximumCount - 2) / 2)
        let bucketSize = Double(interiorPoints.count) / Double(bucketCount)
        var result: [PortfolioChartPoint] = [points[0]]
        result.reserveCapacity(maximumCount + 2)
        for bucket in 0..<bucketCount {
            let lower = Int(Double(bucket) * bucketSize)
            let upper = min(interiorPoints.count, Int(Double(bucket + 1) * bucketSize))
            guard lower < upper else { continue }
            let lowerIndex = interiorPoints.index(interiorPoints.startIndex, offsetBy: lower)
            let upperIndex = interiorPoints.index(interiorPoints.startIndex, offsetBy: upper)
            let slice = interiorPoints[lowerIndex..<upperIndex]
            guard let minimum = slice.min(by: { $0.value < $1.value }),
                  let maximum = slice.max(by: { $0.value < $1.value }) else { continue }
            if minimum.date <= maximum.date {
                result.append(minimum)
                if maximum.date != minimum.date { result.append(maximum) }
            } else {
                result.append(maximum)
                result.append(minimum)
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    /// Mirrors `downsample` for the profit-percent series so the sub-chart
    /// preserves the same visible extrema as the value chart above it.
    private static func downsampleProfit(
        _ points: [PortfolioProfitPoint],
        maximumCount: Int
    ) -> [PortfolioProfitPoint] {
        guard points.count > maximumCount, maximumCount >= 4 else { return points }
        let interiorPoints = points.dropFirst().dropLast()
        let bucketCount = max(1, (maximumCount - 2) / 2)
        let bucketSize = Double(interiorPoints.count) / Double(bucketCount)
        var result: [PortfolioProfitPoint] = [points[0]]
        result.reserveCapacity(maximumCount + 2)
        for bucket in 0..<bucketCount {
            let lower = Int(Double(bucket) * bucketSize)
            let upper = min(interiorPoints.count, Int(Double(bucket + 1) * bucketSize))
            guard lower < upper else { continue }
            let lowerIndex = interiorPoints.index(interiorPoints.startIndex, offsetBy: lower)
            let upperIndex = interiorPoints.index(interiorPoints.startIndex, offsetBy: upper)
            let slice = interiorPoints[lowerIndex..<upperIndex]
            guard let minimum = slice.min(by: { $0.percent < $1.percent }),
                  let maximum = slice.max(by: { $0.percent < $1.percent }) else { continue }
            if minimum.date <= maximum.date {
                result.append(minimum)
                if maximum.date != minimum.date { result.append(maximum) }
            } else {
                result.append(maximum)
                result.append(minimum)
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    private static func aggregateCandles(
        _ points: [PortfolioChartPoint],
        maximumCount: Int
    ) -> [PortfolioChartPoint] {
        guard points.count > maximumCount else { return points }
        let bucketSize = Double(points.count) / Double(maximumCount)
        return (0..<maximumCount).compactMap { bucket in
            let lower = Int(Double(bucket) * bucketSize)
            let upper = min(points.count, Int(Double(bucket + 1) * bucketSize))
            guard lower < upper else { return nil }
            let slice = points[lower..<upper]
            guard let first = slice.first, let last = slice.last,
                  let high = slice.map(\.high).max(),
                  let low = slice.map(\.low).min() else { return nil }
            return PortfolioChartPoint(
                seriesID: last.seriesID,
                seriesLabel: last.seriesLabel,
                date: last.date,
                value: last.value,
                open: first.open,
                high: high,
                low: low,
                x: (first.x + last.x) / 2
            )
        }
    }
}

struct PortfolioChartCanvas: View {
    let series: [PortfolioValueSeries]
    let range: StockChartRange
    let style: PortfolioChartStyle

    @EnvironmentObject private var appearance: StockAppearanceSettings
    @State private var selectedDate: Date?
    private let data: PortfolioChartData

    init(series: [PortfolioValueSeries], range: StockChartRange, style: PortfolioChartStyle) {
        self.series = series
        self.range = range
        self.style = style
        self.data = PortfolioChartData(series: series, range: range)
    }

    private var chartXDomain: ClosedRange<Double> {
        guard data.dates.count > 1 else { return -0.5...0.5 }
        return -0.5...(Double(data.dates.count - 1) + 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            selectionSummary
                .frame(height: 68, alignment: .topLeading)
            Chart {
                if range == .intraday, let costBasis = data.totalCostBasis {
                    let displayedCost = StockChartPresentation.clampedReferencePrice(costBasis, to: yDomain)
                    RuleMark(y: .value("成本", displayedCost))
                        .foregroundStyle(.blue.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("成本 \(yLabel(costBasis))")
                                .appFont(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                } else {
                    ForEach(data.costBasisSegments) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("行情序号", point.x),
                                y: .value("成本", clampedCost(point.cost)),
                                series: .value("成本系列", segment.id)
                            )
                            .foregroundStyle(.blue.opacity(0.35))
                            .interpolationMethod(range == .dayK ? .linear : .stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        if range == .fiveDays, let last = segment.points.last {
                            PointMark(x: .value("行情序号", last.x), y: .value("成本", clampedCost(last.cost)))
                                .foregroundStyle(.blue.opacity(0.35))
                                .symbolSize(1)
                                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                    Text(yLabel(segment.cost))
                                        .appFont(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                }

                if style == .line {
                    ForEach(data.renderedPoints) { point in
                        LineMark(
                            x: .value("行情序号", point.x),
                            y: .value("持仓价值", decimalDouble(point.value)),
                            series: .value("系列", point.seriesID)
                        )
                        .foregroundStyle(seriesColor(for: point.seriesID))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    ForEach(data.renderedCandles) { point in
                        RuleMark(
                            x: .value("行情序号", point.x),
                            yStart: .value("最低", decimalDouble(point.low)),
                            yEnd: .value("最高", decimalDouble(point.high))
                        )
                        .foregroundStyle(candleColor(point))
                        .lineStyle(StrokeStyle(lineWidth: 0.8))
                        RectangleMark(
                            x: .value("行情序号", point.x),
                            yStart: .value("开盘", decimalDouble(point.open)),
                            yEnd: .value("收盘", decimalDouble(point.value)),
                            width: .fixed(StockChartPresentation.candleWidth(
                                pointCount: data.renderedCandles.count,
                                isExpanded: false
                            ))
                        )
                        .foregroundStyle(candleColor(point))
                    }
                }
                if let selectedDate, let nearest = nearestPoint(to: selectedDate) {
                    RuleMark(x: .value("所选日期", nearest.x))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    PointMark(x: .value("所选日期", nearest.x), y: .value("持仓价值", decimalDouble(nearest.value)))
                        .foregroundStyle(seriesColor(for: nearest.seriesID))
                        .symbolSize(55)
                }
            }
            .chartXScale(domain: chartXDomain)
            .chartYScale(domain: yDomain)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: axisValues) { value in
                    AxisGridLine()
                    if let x = value.as(Double.self) {
                        AxisValueLabel { Text(axisLabel(at: x)).appFont(.caption2) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard let frame = proxy.plotFrame else { return }
                            let rect = geometry[frame]
                            let x = value.location.x - rect.minX
                            if let plotX: Double = proxy.value(atX: x) {
                                let index = min(max(Int(plotX.rounded()), 0), data.dates.count - 1)
                                if data.dates.indices.contains(index), selectedDate != data.dates[index] {
                                    selectedDate = data.dates[index]
                                }
                            }
                        })
                }
            }
            .frame(height: 280)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if hasProfitData {
                profitChart
                    .frame(height: 110)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .onChange(of: series.map(\.id)) { _, _ in selectedDate = nil }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let selectedDate {
                Text(selectedDate.formatted(date: .abbreviated, time: .shortened)).appFont(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(series) { item in
                            if let point = nearestPoint(in: item, to: selectedDate) {
                                Label {
                                    Text(selectionText(point, currencyCode: item.currencyCode))
                                        .appFont(.caption.monospacedDigit())
                                } icon: {
                                    Circle().fill(seriesColor(item)).frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("拖动图表选择任意时间点").appFont(.caption).foregroundStyle(.secondary)
                Text(series.map(\.label).joined(separator: "、")).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var yDomain: ClosedRange<Double> {
        guard let low = data.values.min(), let high = data.values.max() else { return 0...1 }
        let span = max(high - low, max(abs(high) * 0.04, 1))
        let pad = span * 0.03
        return (low - pad)...(high + pad)
    }

    private func clampedCost(_ cost: Double) -> Double {
        min(max(cost, yDomain.lowerBound), yDomain.upperBound)
    }

    private var hasProfitData: Bool { !data.renderedProfitPoints.isEmpty }

    private var profitYDomain: ClosedRange<Double> {
        guard let low = data.profitPercents.min(), let high = data.profitPercents.max() else { return -1...1 }
        if low == high {
            let pad = max(abs(low) * 0.1, 1)
            return (low - pad)...(high + pad)
        }
        let span = high - low
        let pad = span * 0.12
        return (low - pad)...(high + pad)
    }

    private var profitChart: some View {
        Chart {
            ForEach(data.profitSegments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("行情序号", point.x),
                        y: .value("盈利比例", point.percent),
                        series: .value("系列", segment.id)
                    )
                    .foregroundStyle(profitSegmentColor(segment))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            }
            if let selectedDate, let nearest = nearestProfitPoint(to: selectedDate) {
                RuleMark(x: .value("所选日期", nearest.x))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value("所选日期", nearest.x), y: .value("盈利比例", nearest.percent))
                    .foregroundStyle(seriesColor(for: nearest.seriesID))
                    .symbolSize(55)
            }
        }
        .chartXScale(domain: chartXDomain)
        .chartYScale(domain: profitYDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisValues) { value in
                AxisGridLine()
                if let x = value.as(Double.self) {
                    AxisValueLabel { Text(axisLabel(at: x)).appFont(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(String(format: "%.1f%%", percent)).appFont(.caption2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard let frame = proxy.plotFrame else { return }
                        let rect = geometry[frame]
                        let x = value.location.x - rect.minX
                        if let plotX: Double = proxy.value(atX: x) {
                            let index = min(max(Int(plotX.rounded()), 0), data.dates.count - 1)
                            if data.dates.indices.contains(index), selectedDate != data.dates[index] {
                                selectedDate = data.dates[index]
                            }
                        }
                    })
            }
        }
    }

    private var axisValues: [Double] {
        guard !data.dates.isEmpty else { return [] }
        let desiredCount = min(5, data.dates.count)
        guard desiredCount > 1 else { return [0] }
        return (0..<desiredCount).map {
            Double($0) * Double(data.dates.count - 1) / Double(desiredCount - 1)
        }
    }
    private func axisLabel(at x: Double) -> String {
        guard !data.dates.isEmpty else { return "" }
        let index = min(max(Int(x.rounded()), 0), data.dates.count - 1)
        let date = data.dates[index]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = range.isMinuteRange ? "MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func nearestPoint(to date: Date) -> PortfolioChartPoint? {
        data.pointsBySeries.values.compactMap { nearestPoint(in: $0, to: date) }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
    private func nearestPoint(in item: PortfolioValueSeries, to date: Date) -> PortfolioChartPoint? {
        nearestPoint(in: data.pointsBySeries[item.id] ?? [], to: date)
    }
    private func nearestPoint(in points: [PortfolioChartPoint], to date: Date) -> PortfolioChartPoint? {
        guard let index = nearestIndex(count: points.count, dateAt: { points[$0].date }, to: date) else { return nil }
        return points[index]
    }
    private func nearestProfitPoint(to date: Date) -> PortfolioProfitPoint? {
        data.profitPointsBySeries.values.compactMap { nearestProfitPoint(in: $0, to: date) }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
    private func nearestProfitPoint(in points: [PortfolioProfitPoint], to date: Date) -> PortfolioProfitPoint? {
        guard let index = nearestIndex(count: points.count, dateAt: { points[$0].date }, to: date) else { return nil }
        return points[index]
    }
    private func nearestIndex(count: Int, dateAt: (Int) -> Date, to target: Date) -> Int? {
        guard count > 0 else { return nil }
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if dateAt(mid) < target { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == count { return count - 1 }
        return target.timeIntervalSince(dateAt(low - 1)) <= dateAt(low).timeIntervalSince(target) ? low - 1 : low
    }
    private func decimalDouble(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
    private func seriesColor(_ item: PortfolioValueSeries) -> Color { seriesColor(for: item.id) }
    private func seriesColor(for id: String) -> Color {
        if id == "cny_total" || id == "cny_total_minute" { return .blue }
        if let item = series.first(where: { $0.id == id }), let market = item.market {
            return StockMarketBadge.color(for: market)
        }
        return .blue
    }
    private func profitSegmentColor(_ segment: PortfolioProfitSegment) -> Color {
        guard let market = series.first(where: { $0.id == segment.seriesID })?.market else {
            guard let isPositive = segment.isPositive else { return .gray }
            return isPositive ? .red : .green
        }
        guard let isPositive = segment.isPositive else { return .gray }
        return StockTrendColor.color(
            for: isPositive ? Decimal(1) : Decimal(-1),
            market: market,
            settings: appearance,
            neutral: .secondary
        )
    }
    private func candleColor(_ point: PortfolioChartPoint) -> Color {
        guard let market = series.first(where: { $0.id == point.seriesID })?.market else {
            return point.value >= point.open ? .red : .green
        }
        return StockTrendColor.color(
            for: point.value - point.open,
            market: market,
            settings: appearance,
            neutral: .secondary
        )
    }
    private func formatted(_ value: Decimal, currencyCode: String) -> String { AppCurrencyFormatter.money(value, currency: CurrencyCode(rawValue: currencyCode) ?? .cny) }
    private func selectionText(_ point: PortfolioChartPoint, currencyCode: String) -> String {
        let costSuffix = selectionCostSuffix(point, currencyCode: currencyCode)
        guard style == .candlestick else {
            return formatted(point.value, currencyCode: currencyCode) + costSuffix
        }
        return "开 \(formatted(point.open, currencyCode: currencyCode))  高 \(formatted(point.high, currencyCode: currencyCode))  低 \(formatted(point.low, currencyCode: currencyCode))  收 \(formatted(point.value, currencyCode: currencyCode))" + costSuffix
    }
    private func selectionCostSuffix(_ point: PortfolioChartPoint, currencyCode: String) -> String {
        guard let lookup = data.costLookupBySeries[point.seriesID],
              let cost = lookup(point.date), cost != 0 else { return "" }
        let profitRate = (point.value - cost) / cost * 100
        let sign = profitRate >= 0 ? "+" : ""
        let rateText = String(format: "%@%.2f%%", sign, NSDecimalNumber(decimal: profitRate).doubleValue)
        return "（成本 \(formatted(cost, currencyCode: currencyCode))，\(rateText)）"
    }
    private func yLabel(_ value: Double) -> String { abs(value) >= 10_000 ? String(format: "%.1f万", value / 10_000) : String(format: "%.0f", value) }
}

#endif
