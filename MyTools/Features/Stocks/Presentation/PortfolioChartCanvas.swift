#if MYTOOLS_FEATURE_STOCKS
import Charts
import SwiftUI

enum PortfolioChartStyle: String, CaseIterable, Identifiable {
    case line
    case candlestick

    var id: Self { self }
    var title: String { self == .line ? "折线" : "K 线" }
}

/// 持仓五日图的横轴独立于 K 线自然刻度。它只按真实交易日分组，生成
/// `交易日数量 + 1` 条边界，并把日期放在各交易日区间中央；回退该行为时
/// 只需要替换这一处，不会影响日 K 及以上周期。
enum PortfolioFiveDayXAxis {
    static func layout(
        dates: [Date],
        calendar: Calendar
    ) -> PortfolioChartXAxis.Layout {
        guard !dates.isEmpty else {
            return .init(
                gridValues: [],
                labelValues: [],
                labelTexts: [:],
                centersLabelsInIntervals: true
            )
        }
        let dayExtents = groupedDayExtents(dates: dates, calendar: calendar)
        let centers = dayExtents.map { (Double($0.first) + Double($0.last)) / 2 }
        let boundaries: [Double]
        if centers.count > 1 {
            boundaries = [Double(dayExtents[0].first)]
                + zip(centers, centers.dropFirst()).map { ($0 + $1) / 2 }
                + [Double(dayExtents[dayExtents.count - 1].last)]
        } else {
            boundaries = [Double(dayExtents[0].first) - 0.5, Double(dayExtents[0].last) + 0.5]
        }
        let texts = Dictionary(uniqueKeysWithValues: zip(boundaries, dayExtents).map { boundary, extent in
            let middleIndex = (extent.first + extent.last) / 2
            return (
                boundary,
                PortfolioChartXAxis.label(
                    for: dates[middleIndex],
                    range: .fiveDays,
                    calendar: calendar
                )
            )
        })
        return .init(
            gridValues: boundaries,
            labelValues: boundaries,
            labelTexts: texts,
            centersLabelsInIntervals: true
        )
    }

    private static func groupedDayExtents(
        dates: [Date],
        calendar: Calendar
    ) -> [(first: Int, last: Int)] {
        var order: [Date] = []
        var extents: [Date: (first: Int, last: Int)] = [:]
        for index in dates.indices {
            let day = calendar.startOfDay(for: dates[index])
            if var extent = extents[day] {
                extent.last = index
                extents[day] = extent
            } else {
                order.append(day)
                extents[day] = (index, index)
            }
        }
        return order.compactMap { extents[$0] }
    }
}

enum PortfolioChartXAxis {
    struct Layout {
        let gridValues: [Double]
        let labelValues: [Double]
        let labelTexts: [Double: String]
        let centersLabelsInIntervals: Bool
    }

    /// Five-day charts need six grid marks to divide the plot into five equal
    /// time intervals. Other ranges retain the existing five-mark layout.
    static func values(pointCount: Int, range: StockChartRange) -> [Double] {
        guard pointCount > 0 else { return [] }
        let maximumMarkCount = range == .fiveDays ? 6 : 5
        let markCount = min(maximumMarkCount, pointCount)
        guard markCount > 1 else { return [0] }
        return (0..<markCount).map {
            Double($0) * Double(pointCount - 1) / Double(markCount - 1)
        }
    }

    /// Five-day labels keep all six boundary values. Charts uses each following
    /// boundary to center the preceding label inside its interval; the final
    /// boundary is retained as an anchor but does not display text.
    static func labelValues(pointCount: Int, range: StockChartRange) -> [Double] {
        let gridValues = values(pointCount: pointCount, range: range)
        guard range == .fiveDays else { return gridValues }
        return gridValues
    }

    static func gridValues(
        dates: [Date],
        range: StockChartRange,
        calendar: Calendar
    ) -> [Double] {
        layout(dates: dates, range: range, calendar: calendar).gridValues
    }

    static func labelValues(
        dates: [Date],
        range: StockChartRange,
        calendar: Calendar
    ) -> [Double] {
        layout(dates: dates, range: range, calendar: calendar).labelValues
    }

    static func layout(
        dates: [Date],
        range: StockChartRange,
        calendar: Calendar,
        maximumTickCount: Int = 5
    ) -> Layout {
        guard !dates.isEmpty else {
            return Layout(gridValues: [], labelValues: [], labelTexts: [:], centersLabelsInIntervals: false)
        }
        if range == .fiveDays {
            return PortfolioFiveDayXAxis.layout(dates: dates, calendar: calendar)
        }

        let tickIndices: [(Int, String)]
        switch range {
        case .weekK, .monthK:
            tickIndices = monthlyTicks(
                dates: dates,
                calendar: calendar,
                maximumCount: maximumTickCount
            )
        case .quarterK, .yearK:
            let years = uniqueFirstIndices(dates: dates) {
                calendar.component(.year, from: $0)
            }
            tickIndices = sampled(years, maximumCount: maximumTickCount).map {
                ($0, String(calendar.component(.year, from: dates[$0])))
            }
        case .intraday, .dayK:
            tickIndices = values(pointCount: dates.count, range: range).map { value in
                let index = min(max(Int(value.rounded()), 0), dates.count - 1)
                return (index, label(for: dates[index], range: range, calendar: calendar))
            }
        case .fiveDays:
            tickIndices = []
        }
        let pairs = tickIndices.map { (Double($0.0), $0.1) }
        let tickValues = pairs.map(\.0)
        return Layout(
            gridValues: tickValues,
            labelValues: tickValues,
            labelTexts: Dictionary(uniqueKeysWithValues: pairs),
            centersLabelsInIntervals: false
        )
    }

    static func label(for date: Date, range: StockChartRange, calendar: Calendar) -> String {
        if range == .quarterK {
            let quarter = (calendar.component(.month, from: date) - 1) / 3 + 1
            return "Q\(quarter)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        switch range {
        case .intraday:
            formatter.dateFormat = "MM-dd HH:mm"
        case .fiveDays, .dayK:
            formatter.dateFormat = "MM-dd"
        case .weekK, .monthK:
            formatter.dateFormat = "M月"
        case .yearK:
            formatter.dateFormat = "yyyy"
        case .quarterK:
            return ""
        }
        return formatter.string(from: date)
    }

    private static func monthlyTicks(
        dates: [Date],
        calendar: Calendar,
        maximumCount: Int
    ) -> [(Int, String)] {
        let months = uniqueFirstIndices(dates: dates) { date in
            let components = calendar.dateComponents([.year, .month], from: date)
            return "\(components.year ?? 0)-\(components.month ?? 0)"
        }
        let spansMultipleYears = Set(months.map {
            calendar.component(.year, from: dates[$0])
        }).count > 1
        for step in [1, 2, 3, 6, 12] {
            let selected = months.filter { index in
                let components = calendar.dateComponents([.year, .month], from: dates[index])
                let ordinal = (components.year ?? 0) * 12 + (components.month ?? 1) - 1
                return ordinal.isMultiple(of: step)
            }
            if !selected.isEmpty, selected.count <= maximumCount {
                return selected.map { index in
                    let year = calendar.component(.year, from: dates[index])
                    let month = calendar.component(.month, from: dates[index])
                    let text: String
                    if step == 12 || month == 1 {
                        text = String(year)
                    } else if spansMultipleYears {
                        text = String(format: "%02d-%02d", year % 100, month)
                    } else {
                        text = "\(month)月"
                    }
                    return (index, text)
                }
            }
        }
        let years = uniqueFirstIndices(dates: dates) {
            calendar.component(.year, from: $0)
        }
        return sampled(years, maximumCount: maximumCount).map {
            ($0, String(calendar.component(.year, from: dates[$0])))
        }
    }

    private static func uniqueFirstIndices<Key: Hashable>(
        dates: [Date],
        key: (Date) -> Key
    ) -> [Int] {
        var seen = Set<Key>()
        return dates.indices.filter { seen.insert(key(dates[$0])).inserted }
    }

    private static func sampled<T>(_ values: [T], maximumCount: Int) -> [T] {
        guard values.count > maximumCount, maximumCount > 1 else { return values }
        let finalIndex = values.count - 1
        let indices = Set((0..<maximumCount).map { position in
            Int((Double(position) * Double(finalIndex) / Double(maximumCount - 1)).rounded())
        })
        return indices.sorted().map { values[$0] }
    }

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
///
/// `cost` 是这一段水平线自己的高度，`points` 末尾可能额外带一个「下一段成本」的点，
/// 只为了让 `.stepEnd` 画出那条竖直跳变，不参与标签取值。`id` 必须把 `cost` 算进去：
/// 相邻两段会共享同一个首点，只用首点日期生成 id 会撞车，`ForEach` 里后一段的标签
/// 会顶掉前一段，最左边那段于是显示成下一段的成本。
private struct PortfolioCostBasisSegment: Identifiable {
    let seriesID: String
    let cost: Double
    let points: [PortfolioCostBasisChartPoint]
    var id: String { "\(seriesID)-\(points.first?.id ?? "")-\(cost)" }
}

struct PortfolioCostLabelInput: Equatable {
    let id: String
    let seriesID: String
    let cost: Double
    let startX: Double
    let endX: Double
}

struct PortfolioCostLabel: Identifiable, Equatable {
    let id: String
    let cost: Double
    let text: String
    let x: Double
}

/// Labels are presentation values, so consecutive cost runs that format to the
/// same text form one visual run. The underlying cost line remains untouched.
enum PortfolioCostLabelLayout {
    static func merged(
        _ inputs: [PortfolioCostLabelInput],
        formatter: (Double) -> String
    ) -> [PortfolioCostLabel] {
        var groups: [[(input: PortfolioCostLabelInput, text: String)]] = []
        for input in inputs {
            let element = (input, formatter(input.cost))
            if let last = groups.last?.last,
               last.input.seriesID == input.seriesID,
               last.text == element.1 {
                groups[groups.count - 1].append(element)
            } else {
                groups.append([element])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return PortfolioCostLabel(
                id: first.input.id,
                cost: first.input.cost,
                text: first.text,
                x: (first.input.startX + last.input.endX) / 2
            )
        }
    }
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
    let costLookupBySeries: [String: (Date) -> Decimal?]

    init() {
        points = []
        renderedPoints = []
        renderedCandles = []
        dates = []
        values = []
        pointsBySeries = [:]
        renderedProfitPoints = []
        profitPointsBySeries = [:]
        profitPercents = []
        profitSegments = []
        costBasisSegments = []
        costLookupBySeries = [:]
    }

    init(series: [PortfolioValueSeries], range: StockChartRange, style: PortfolioChartStyle = .line) {
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
        // Keep the rendered mark count bounded for minute based ranges. The
        // full-resolution points remain available for nearest-point lookup,
        // while Swift Charts only receives a compact visual sample.
        let renderingBudget: Int = range == .fiveDays ? 360 : 1_200
        let budgetPerSeries = max(120, renderingBudget / max(series.count, 1))
        let displayPoints = series.flatMap { item in
            Self.downsample(indexedPoints[item.id] ?? [], maximumCount: budgetPerSeries)
        }
        let candlePoints = style == .candlestick
            ? series.flatMap { item in
                Self.aggregateCandles(indexedPoints[item.id] ?? [], maximumCount: 320)
            }
            : []
        self.pointsBySeries = indexedPoints
        self.points = allPoints
        self.renderedPoints = displayPoints
        self.renderedCandles = candlePoints
        self.dates = orderedDates
        let costBasisSegments: [PortfolioCostBasisSegment] = series.flatMap { item in
            Self.costBasisSegment(for: item, range: range, xByDate: xByDate)
        }
        self.costBasisSegments = costBasisSegments
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
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle].date <= date {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return sorted[max(0, low - 1)].cost
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
    /// range: for `.fiveDays` each transaction-driven change in holding cost
    /// becomes its own flat horizontal run at the actual event timestamp so it
    /// can carry its own value label; for `.dayK` the cost is drawn as a
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
        var datesToRender = sortedDates
        if range.isMinuteRange {
            // Cost changes are transaction events, not market-day events. Keep
            // the first visible point, every actual cost transition, and the
            // final visible point. This places an add-on at its true minute
            // instead of moving it to the start of that calendar day.
            var transitionDates: [Date] = [sortedDates[0]]
            var previousCost = lookup(sortedDates[0])
            for date in sortedDates.dropFirst() {
                let cost = lookup(date)
                if cost != previousCost {
                    transitionDates.append(date)
                    previousCost = cost
                }
            }
            if transitionDates.last != sortedDates.last {
                transitionDates.append(sortedDates.last!)
            }
            datesToRender = transitionDates
        }
        let chartPoints: [PortfolioCostBasisChartPoint] = datesToRender.compactMap { date in
            guard let x = xByDate[date], let cost = lookup(date) else { return nil }
            return PortfolioCostBasisChartPoint(date: date, cost: NSDecimalNumber(decimal: cost).doubleValue, x: x)
        }
        guard !chartPoints.isEmpty else { return [] }
        guard range.isMinuteRange else {
            return [
                PortfolioCostBasisSegment(
                    seriesID: item.id,
                    cost: chartPoints.last?.cost ?? 0,
                    points: chartPoints
                )
            ]
        }
        // 先切成「成本相同」的极大段，段与段之间不共享点，这样每段的高度、标签和 id
        // 一一对应。旧实现让后一段以前一段的末点开头（为了共享那个点画竖直跳变），
        // 于是首段和次段的首点相同、id 相同，最左边那段的标签会显示成下一段的成本。
        var levels: [[PortfolioCostBasisChartPoint]] = []
        for point in chartPoints {
            if point.cost == levels.last?.last?.cost {
                levels[levels.count - 1].append(point)
            } else {
                levels.append([point])
            }
        }
        return levels.indices.compactMap { index in
            let level = levels[index]
            guard let first = level.first else { return nil }
            // 水平段右端延到下一段的起点，并把下一段的首点接在后面，`.stepEnd`
            // 就能在那个 x 上画出竖直跳变；标签仍用本段自己的高度。
            let next = index + 1 < levels.count ? levels[index + 1].first : nil
            let points = level + (next.map { [$0] } ?? [])
            return PortfolioCostBasisSegment(
                seriesID: item.id,
                cost: first.cost,
                points: points
            )
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
    let dataRevision: Int

    @EnvironmentObject private var appearance: StockAppearanceSettings
    @State private var selectedDate: Date?
    @State private var lastSelectionUpdateTime: TimeInterval = 0
    @State private var data: PortfolioChartData
    @State private var preparationTask: Task<Void, Never>?

    init(
        series: [PortfolioValueSeries],
        range: StockChartRange,
        style: PortfolioChartStyle,
        dataRevision: Int = 0
    ) {
        self.series = series
        self.range = range
        self.style = style
        self.dataRevision = dataRevision
        // Keep View initialization cheap. SwiftUI may recreate this value
        // repeatedly while dragging; the expensive chart preparation is done
        // only when the input series actually arrives or changes.
        _data = State(initialValue: PortfolioChartData())
    }

    private var chartXDomain: ClosedRange<Double> {
        guard data.dates.count > 1 else { return -0.5...0.5 }
        return -0.5...(Double(data.dates.count - 1) + 0.5)
    }

    var body: some View {
        // These values only depend on the prepared chart data. Snapshot them
        // once per body evaluation: asking for `yDomain` from every cost-basis
        // mark used to rescan the complete value array for every rendered
        // point, and the two axes rebuilt the same calendar layout repeatedly.
        let resolvedYDomain = yDomain
        let resolvedXAxisLayout = xAxisLayout
        let resolvedProfitYDomain = profitYDomain
        let costLabels = fiveDayCostLabels
        VStack(alignment: .leading, spacing: 0) {
            selectionSummary
                .frame(height: 68, alignment: .topLeading)
            Chart {
                ForEach(data.costBasisSegments) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("行情序号", point.x),
                            y: .value("成本", clampedCost(point.cost, to: resolvedYDomain)),
                            series: .value("成本系列", segment.id)
                        )
                        .foregroundStyle(.blue.opacity(0.35))
                        .interpolationMethod(range == .dayK ? .linear : .stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                ForEach(costLabels) { label in
                    PointMark(
                        x: .value("行情序号", label.x),
                        y: .value("成本", clampedCost(label.cost, to: resolvedYDomain))
                    )
                    .foregroundStyle(.blue.opacity(0.35))
                    .symbolSize(1)
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text(label.text)
                            .appFont(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if range == .intraday, let segment = data.costBasisSegments.last,
                   let finalPoint = segment.points.last {
                    PointMark(
                        x: .value("行情序号", finalPoint.x),
                        y: .value("成本", clampedCost(segment.cost, to: resolvedYDomain))
                    )
                    .foregroundStyle(.blue.opacity(0.35))
                    .symbolSize(1)
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("成本 \(yLabel(segment.cost))")
                            .appFont(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
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
            }
            .chartXScale(domain: chartXDomain)
            .chartYScale(domain: resolvedYDomain)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: resolvedXAxisLayout.gridValues) { _ in
                    AxisGridLine()
                }
                AxisMarks(values: resolvedXAxisLayout.labelValues) { value in
                    if let x = value.as(Double.self),
                       let text = resolvedXAxisLayout.labelTexts[x] {
                        if resolvedXAxisLayout.centersLabelsInIntervals {
                            AxisValueLabel(centered: true, collisionResolution: .disabled) {
                                Text(text).appFont(.caption2)
                            }
                        } else {
                            AxisValueLabel(collisionResolution: .greedy) {
                                Text(text).appFont(.caption2)
                            }
                        }
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
                    ZStack {
                        if let selectedDate, let nearest = nearestPoint(to: selectedDate) {
                            selectionOverlay(
                                proxy: proxy,
                                geometry: geometry,
                                x: nearest.x,
                                y: decimalDouble(nearest.value),
                                color: seriesColor(for: nearest.seriesID)
                            )
                        }
                        Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard let frame = proxy.plotFrame else { return }
                            let rect = geometry[frame]
                            let x = value.location.x - rect.minX
                            if let plotX: Double = proxy.value(atX: x) {
                                updateSelection(plotX: plotX)
                            }
                        })
                    }
                }
            }
            .frame(height: 280)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if hasProfitData {
                profitChart(
                    xAxisLayout: resolvedXAxisLayout,
                    yDomain: resolvedProfitYDomain
                )
                    .frame(height: 110)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: range) { _, newRange in
            data = PortfolioChartData()
            selectedDate = nil
        }
        .onChange(of: dataRevision) { _, _ in
            guard !series.isEmpty else { return }
            data = PortfolioChartData(series: series, range: range, style: style)
            selectedDate = nil
        }
        .onChange(of: style) { _, newStyle in
            data = PortfolioChartData(series: series, range: range, style: newStyle)
        }
        .onAppear {
            if data.dates.isEmpty, !series.isEmpty {
                data = PortfolioChartData(series: series, range: range, style: style)
            }
        }
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

    private func clampedCost(_ cost: Double, to domain: ClosedRange<Double>) -> Double {
        min(max(cost, domain.lowerBound), domain.upperBound)
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

    private func profitChart(
        xAxisLayout: PortfolioChartXAxis.Layout,
        yDomain: ClosedRange<Double>
    ) -> some View {
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
        }
        .chartXScale(domain: chartXDomain)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: xAxisLayout.gridValues) { _ in
                AxisGridLine()
            }
            AxisMarks(values: xAxisLayout.labelValues) { value in
                if let x = value.as(Double.self),
                   let text = xAxisLayout.labelTexts[x] {
                    if xAxisLayout.centersLabelsInIntervals {
                        AxisValueLabel(centered: true, collisionResolution: .disabled) {
                            Text(text).appFont(.caption2)
                        }
                    } else {
                        AxisValueLabel(collisionResolution: .greedy) {
                            Text(text).appFont(.caption2)
                        }
                    }
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
                ZStack {
                    if let selectedDate, let nearest = nearestProfitPoint(to: selectedDate) {
                        selectionOverlay(
                            proxy: proxy,
                            geometry: geometry,
                            x: nearest.x,
                            y: nearest.percent,
                            color: seriesColor(for: nearest.seriesID)
                        )
                    }
                    Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard let frame = proxy.plotFrame else { return }
                        let rect = geometry[frame]
                        let x = value.location.x - rect.minX
                        if let plotX: Double = proxy.value(atX: x) {
                            updateSelection(plotX: plotX)
                        }
                    })
                }
            }
        }
    }

    @ViewBuilder
    private func selectionOverlay(
        proxy: ChartProxy,
        geometry: GeometryProxy,
        x: Double,
        y: Double,
        color: Color
    ) -> some View {
        if let plotFrame = proxy.plotFrame,
           let plotX = proxy.position(forX: x),
           let plotY = proxy.position(forY: y) {
            let frame = geometry[plotFrame]
            let screenX = frame.minX + plotX
            let screenY = frame.minY + plotY
            Path { path in
                path.move(to: CGPoint(x: screenX, y: frame.minY))
                path.addLine(to: CGPoint(x: screenX, y: frame.maxY))
            }
            .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .position(x: screenX, y: screenY)
        }
    }

    private func updateSelection(plotX: Double) {
        guard !data.dates.isEmpty else { return }
        let index = min(max(Int(plotX.rounded()), 0), data.dates.count - 1)
        let now = Date.timeIntervalSinceReferenceDate
        guard data.dates.indices.contains(index),
              selectedDate != data.dates[index],
              now - lastSelectionUpdateTime >= (1.0 / 30.0) else { return }
        lastSelectionUpdateTime = now
        selectedDate = data.dates[index]
    }

    private var xAxisLayout: PortfolioChartXAxis.Layout {
        PortfolioChartXAxis.layout(
            dates: data.dates,
            range: range,
            calendar: axisCalendar,
            maximumTickCount: 5
        )
    }

    private var axisCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let market = series.compactMap(\.market).first {
            calendar.timeZone = StockChartSeriesProcessor.marketTimeZone(market)
        }
        return calendar
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

    private var fiveDayCostLabels: [PortfolioCostLabel] {
        guard range == .fiveDays else { return [] }
        let inputs = data.costBasisSegments.compactMap { segment -> PortfolioCostLabelInput? in
            guard let first = segment.points.first, let last = segment.points.last else { return nil }
            return PortfolioCostLabelInput(
                id: segment.id,
                seriesID: segment.seriesID,
                cost: segment.cost,
                startX: first.x,
                endX: last.x
            )
        }
        return PortfolioCostLabelLayout.merged(inputs, formatter: yLabel)
    }
}

#endif
