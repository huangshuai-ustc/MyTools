#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockChartDisplayMode: String, CaseIterable, Identifiable {
    case preMarket
    case line
    case postMarket
    case candlestick
    case movingAverage
    case bollingerBands
    case volume
    case macd
    case rsi

    var id: Self { self }

    var title: String {
        switch self {
        case .preMarket: return "盘前"
        case .line: return "走势"
        case .postMarket: return "盘后"
        case .candlestick: return "K 线"
        case .movingAverage: return "均线"
        case .bollingerBands: return "布林"
        case .volume: return "成交量"
        case .macd: return "MACD"
        case .rsi: return "RSI"
        }
    }

    var isPriceChart: Bool {
        switch self {
        case .line, .candlestick, .movingAverage, .bollingerBands:
            return true
        case .preMarket, .postMarket, .volume, .macd, .rsi:
            return false
        }
    }

    func isCompatible(with other: StockChartDisplayMode) -> Bool {
        isCompatible(with: other, session: nil)
    }

    func isCompatible(
        with other: StockChartDisplayMode,
        session: StockMarketSession?
    ) -> Bool {
        guard self != other else { return true }
        let pairIsCompatible: Bool
        if self == .preMarket || other == .preMarket {
            pairIsCompatible = (self == .preMarket && other == .line)
                || (other == .preMarket && self == .line)
        } else if self == .postMarket || other == .postMarket {
            pairIsCompatible = (self == .postMarket && other == .line)
                || (other == .postMarket && self == .line)
        } else {
            guard isPriceChart, other.isPriceChart else { return false }
            let basePriceModes: Set<StockChartDisplayMode> = [.line, .candlestick]
            pairIsCompatible = !(basePriceModes.contains(self) && basePriceModes.contains(other))
        }
        guard pairIsCompatible else { return false }
        guard let session else { return true }
        if session == .preMarket && ((self == .preMarket && other == .line)
            || (self == .line && other == .preMarket)) {
            return false
        }
        if session == .regular && (self == .postMarket || other == .postMarket) {
            return false
        }
        if session == .preMarket && (self == .postMarket || other == .postMarket) {
            return false
        }
        return true
    }

    static func isCompatibleSet(
        _ modes: Set<StockChartDisplayMode>,
        session: StockMarketSession?
    ) -> Bool {
        let hasPreMarket = modes.contains(.preMarket)
        let hasPostMarket = modes.contains(.postMarket)
        let hasLine = modes.contains(.line)
        for left in modes {
            for right in modes where left != right {
                let extendedHoursCanBeConnected =
                    ((left == .preMarket && right == .postMarket)
                        || (left == .postMarket && right == .preMarket))
                    && hasLine
                    && (session == .postMarket || session == .closed)
                if extendedHoursCanBeConnected { continue }
                guard left.isCompatible(with: right, session: session) else {
                    return false
                }
            }
        }
        if hasPreMarket && hasPostMarket && !hasLine { return false }
        if hasPreMarket && hasPostMarket && session != .postMarket && session != .closed {
            return false
        }
        return true
    }

    static func defaultModes(for session: StockMarketSession) -> Set<Self> {
        [.line]
    }

    static func defaultModes(
        for range: StockChartRange,
        session: StockMarketSession
    ) -> Set<Self> {
        [.line]
    }
}

struct StockTransactionMarker: Identifiable {
    let id: UUID
    let date: Date
    let plotX: Double
    let plotPrice: Double
    let type: StockTransactionType
    let quantity: Decimal
    let unitPrice: Decimal
}

struct StockTransactionSelection: Identifiable {
    let type: StockTransactionType
    let averagePrice: Decimal

    var id: StockTransactionType { type }
}

struct StockChartPlotPoint: Identifiable {
    let point: StockChartPoint
    let x: Double

    var id: Date { point.id }
}

struct StockTechnicalPlotPoint: Identifiable {
    let indicator: StockTechnicalIndicatorPoint
    let x: Double

    var id: Date { indicator.id }
}

/// The subset of chart data that belongs to the active viewport.
///
/// Keeping this value object in the presentation layer means the Canvas does
/// not need to know how each chart layer is clipped. It also lets Y-axis
/// calculation and mark rendering use the exact same input after a pan/zoom.
struct StockChartVisibleData {
    let plotPoints: [StockChartPlotPoint]
    let preMarketPlotPoints: [StockChartPlotPoint]
    let postMarketPlotPoints: [StockChartPlotPoint]
    let technicalPlotPoints: [StockTechnicalPlotPoint]
    let transactionMarkers: [StockTransactionMarker]

    var plotPointCount: Int {
        max(1, plotPoints.count)
    }

    var containsPricePoints: Bool {
        !plotPoints.isEmpty
            || !preMarketPlotPoints.isEmpty
            || !postMarketPlotPoints.isEmpty
    }
}

struct StockChartPresentation {
    let snapshot: StockChartSnapshot
    let stock: StockHolding
    let range: StockChartRange
    let displayModes: Set<StockChartDisplayMode>
    let plotPoints: [StockChartPlotPoint]
    let preMarketPlotPoints: [StockChartPlotPoint]
    let postMarketPlotPoints: [StockChartPlotPoint]
    let allPricePlotPoints: [StockChartPlotPoint]
    let technicalPlotPoints: [StockTechnicalPlotPoint]
    let transactionMarkers: [StockTransactionMarker]
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>

    /// The most recent point in the currently displayed price series.
    /// Used by the summary when no point is selected yet.
    var latestDisplayedPoint: StockChartPoint? {
        allPricePlotPoints.last?.point
    }

    var orderedDisplayModes: [StockChartDisplayMode] {
        StockChartDisplayMode.allCases.filter(displayModes.contains)
    }

    var displayModesTitle: String {
        let title = orderedDisplayModes.map(\.title).joined(separator: "、")
        return title.isEmpty ? "未选择" : title
    }

    var hasPriceChart: Bool {
        displayModes.contains { $0.isPriceChart }
            || displayModes.contains(.preMarket)
            || displayModes.contains(.postMarket)
    }

    var hasBasePriceChart: Bool {
        displayModes.contains(.line) || displayModes.contains(.candlestick)
    }

    var hasPreMarketChart: Bool {
        range == .intraday && displayModes.contains(.preMarket)
    }

    var hasPostMarketChart: Bool {
        range == .intraday && displayModes.contains(.postMarket)
    }

    var preMarketTitle: String {
        stock.market == .aShare ? "集合竞价" : "盘前"
    }

    var postMarketTitle: String { "盘后" }

    init(
        snapshot: StockChartSnapshot,
        stock: StockHolding,
        range: StockChartRange,
        displayModes: Set<StockChartDisplayMode>
    ) {
        self.snapshot = snapshot
        self.stock = stock
        self.range = range
        self.displayModes = displayModes

        let hasRegularPriceChart = displayModes.contains(.line)
        // `indicatorPoints` is a warm-up series for technical indicators. It
        // may contain older days and extended-hours bars, so it must never be
        // drawn as the visible minute chart. `points` is the provider's
        // already-scoped display series.
        let chartPoints = snapshot.points.sorted { $0.date < $1.date }
        let regularPoints: [StockChartPoint]
        if range == .intraday {
            let sessionPoints = StockChartSeriesProcessor.regularSessionPoints(
                chartPoints,
                market: stock.market
            )
            // An intraday line must never fall back to pre-market/post-market
            // bars when the provider has no regular-session bars.
            if let latestDate = sessionPoints.last?.date {
                let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
                let latestDay = calendar.startOfDay(for: latestDate)
                regularPoints = sessionPoints.filter {
                    calendar.isDate($0.date, inSameDayAs: latestDay)
                }
            } else {
                regularPoints = []
            }
        } else {
            regularPoints = chartPoints
        }
        let scopedPreMarketPoints = Self.scopedExtendedHoursPoints(
            snapshot.preMarketPoints,
            regularPoints: hasRegularPriceChart ? regularPoints : [],
            market: stock.market
        )
        let scopedPostMarketPoints = Self.scopedExtendedHoursPoints(
            snapshot.postMarketPoints,
            regularPoints: hasRegularPriceChart ? regularPoints : [],
            market: stock.market
        )
        let preMarketCount = range == .intraday
            && displayModes.contains(.preMarket)
            && hasRegularPriceChart
            ? scopedPreMarketPoints.count
            : 0
        let plotPoints = regularPoints.enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: Self.xValue(
                    for: point,
                    index: index + preMarketCount,
                    range: range
                )
            )
        }
        self.plotPoints = plotPoints
        preMarketPlotPoints = (displayModes.contains(.preMarket) ? scopedPreMarketPoints : [])
            .enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: Self.xValue(for: point, index: index, range: range)
            )
        }
        let postMarketOffset = hasRegularPriceChart
            ? preMarketCount + regularPoints.count
            : 0
        postMarketPlotPoints = (displayModes.contains(.postMarket) ? scopedPostMarketPoints : [])
            .enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: Self.xValue(
                    for: point,
                    index: index + postMarketOffset,
                    range: range
                )
            )
        }
        let includesPreMarket = range == .intraday && displayModes.contains(.preMarket)
        let includesPostMarket = range == .intraday && displayModes.contains(.postMarket)
        var combinedPricePoints: [StockChartPlotPoint]
        if includesPreMarket {
            combinedPricePoints = hasRegularPriceChart
                ? preMarketPlotPoints + plotPoints
                : preMarketPlotPoints
        } else if includesPostMarket && !hasRegularPriceChart {
            combinedPricePoints = postMarketPlotPoints
        } else {
            combinedPricePoints = plotPoints
        }
        if includesPostMarket && hasRegularPriceChart {
            combinedPricePoints += postMarketPlotPoints
        }
        allPricePlotPoints = combinedPricePoints.sorted { $0.x < $1.x }
        technicalPlotPoints = Self.technicalPlotPoints(
            for: plotPoints,
            in: snapshot,
            range: range,
            market: stock.market
        )
        transactionMarkers = Self.transactionMarkers(
            for: stock,
            in: snapshot,
            range: range,
            plotPoints: plotPoints
        )
        xDomain = Self.xDomain(for: allPricePlotPoints)
        yDomain = Self.yDomain(
            snapshot: snapshot,
            displayModes: displayModes,
            technicalPlotPoints: technicalPlotPoints,
            transactionMarkers: transactionMarkers,
            plotPoints: plotPoints,
            preMarketPlotPoints: preMarketPlotPoints,
            postMarketPlotPoints: postMarketPlotPoints
        )
    }

    private static func scopedExtendedHoursPoints(
        _ points: [StockChartPoint],
        regularPoints: [StockChartPoint],
        market: StockMarket
    ) -> [StockChartPoint] {
        guard !points.isEmpty else { return [] }
        let calendar = StockChartSeriesProcessor.marketCalendar(market)
        // Providers may return yesterday's regular session together with
        // today's pre/post-market bars. Scope extended hours to the newest
        // day present in either series so the current session is not hidden
        // behind a stale regular-session cache.
        let referenceDate = max(
            regularPoints.last?.date ?? .distantPast,
            points.last!.date
        )
        let referenceDay = calendar.startOfDay(for: referenceDate)
        return points
            .filter { calendar.isDate($0.date, inSameDayAs: referenceDay) }
            .sorted { $0.date < $1.date }
    }

    func selectedPoint(at date: Date?) -> StockChartPoint? {
        guard let date else { return nil }
        return allPricePlotPoints.map(\.point).min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    func selectedPlotPoint(at date: Date?) -> StockChartPlotPoint? {
        guard let date else { return nil }
        return allPricePlotPoints.min {
            abs($0.point.date.timeIntervalSince(date))
                < abs($1.point.date.timeIntervalSince(date))
        }
    }

    func selectedTechnicalPlotPoint(at date: Date?) -> StockTechnicalPlotPoint? {
        guard let date else { return nil }
        return technicalPlotPoints.min {
            abs($0.indicator.date.timeIntervalSince(date))
                < abs($1.indicator.date.timeIntervalSince(date))
        }
    }

    func plotPoint(closestTo x: Double) -> StockChartPlotPoint? {
        allPricePlotPoints.min { abs($0.x - x) < abs($1.x - x) }
    }

    func plotPoint(
        closestTo x: Double,
        in visibleDomain: ClosedRange<Double>
    ) -> StockChartPlotPoint? {
        let visiblePoints = allPricePlotPoints.filter {
            visibleDomain.contains($0.x)
        }
        return (visiblePoints.isEmpty ? allPricePlotPoints : visiblePoints).min {
            abs($0.x - x) < abs($1.x - x)
        }
    }

    func isPreMarket(_ point: StockChartPoint) -> Bool {
        hasPreMarketChart && preMarketPlotPoints.contains { $0.point.id == point.id }
    }

    func isPostMarket(_ point: StockChartPoint) -> Bool {
        hasPostMarketChart && postMarketPlotPoints.contains { $0.point.id == point.id }
    }

    func technicalIndicator(at point: StockChartPoint) -> StockTechnicalIndicatorPoint? {
        technicalPlotPoints.first { $0.indicator.date == point.date }?.indicator
    }

    func transactionSelections(at point: StockChartPoint) -> [StockTransactionSelection] {
        let matchingMarkers = transactionMarkers.filter { $0.date == point.date }
        return StockTransactionType.allCases.compactMap { type in
            let markers = matchingMarkers.filter { $0.type == type }
            let totalQuantity = markers.reduce(Decimal.zero) { $0 + $1.quantity }
            guard totalQuantity > 0 else { return nil }
            let totalAmount = markers.reduce(Decimal.zero) {
                $0 + $1.quantity * $1.unitPrice
            }
            return StockTransactionSelection(
                type: type,
                averagePrice: totalAmount / totalQuantity
            )
        }
    }

    func xAxisValues(
        isExpanded: Bool,
        in requestedVisibleDomain: ClosedRange<Double>? = nil
    ) -> [Double] {
        let sourcePoints = range.isMinuteRange ? allPricePlotPoints : plotPoints
        let axisPlotPoints: [StockChartPlotPoint]
        let visibleDomain = requestedVisibleDomain
            ?? defaultVisibleXDomain(isExpanded: isExpanded)
        let visiblePoints = sourcePoints.filter { visibleDomain.contains($0.x) }
        axisPlotPoints = visiblePoints.isEmpty ? sourcePoints : visiblePoints
        guard axisPlotPoints.count > 1 else { return axisPlotPoints.map(\.x) }
        if range == .fiveDays {
            let calendar = Self.calendar(for: stock.market)
            var retainedDays = Set<Date>()
            return axisPlotPoints.compactMap { plotPoint in
                let day = calendar.startOfDay(for: plotPoint.point.date)
                guard retainedDays.insert(day).inserted else { return nil }
                return plotPoint.x
            }
        }

        let desiredCount: Int
        switch range {
        case .intraday:
            desiredCount = isExpanded ? 10 : 6
        case .fiveDays:
            desiredCount = isExpanded ? 8 : 5
        case .dayK:
            desiredCount = isExpanded ? 10 : 6
        case .weekK, .monthK:
            desiredCount = isExpanded ? 9 : 6
        case .quarterK, .yearK:
            desiredCount = isExpanded ? 10 : 6
        case .oneMonth, .threeMonths, .oneYear:
            desiredCount = isExpanded ? 8 : 5
        case .fiveYears, .tenYears, .sinceInception:
            desiredCount = isExpanded ? 10 : 6
        }
        let finalIndex = axisPlotPoints.count - 1
        let indices = Set((0..<desiredCount).map { position in
            Int(
                (Double(position) * Double(finalIndex) / Double(desiredCount - 1))
                    .rounded()
            )
        })
        return indices.sorted().map { axisPlotPoints[$0].x }
    }

    func chartDateText(_ date: Date) -> String {
        let formatter = Self.dateFormatter(market: stock.market)
        formatter.dateFormat = range == .intraday || range == .fiveDays
            ? "MM-dd HH:mm"
            : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func axisLabelText(_ date: Date) -> String {
        let formatter = Self.dateFormatter(market: stock.market)
        switch range {
        case .intraday:
            formatter.dateFormat = "HH:mm"
        case .fiveDays, .dayK, .oneMonth, .threeMonths, .oneYear:
            formatter.dateFormat = "MM-dd"
        case .weekK, .monthK, .quarterK, .yearK,
             .fiveYears, .tenYears, .sinceInception:
            formatter.dateFormat = "yyyy"
        }
        return formatter.string(from: date)
    }

    static func isModeAvailable(
        _ mode: StockChartDisplayMode,
        in snapshot: StockChartSnapshot?,
        range: StockChartRange? = nil
    ) -> Bool {
        guard let snapshot else { return mode == .line }
        let indicatorPointCount = snapshot.indicatorPoints?.count ?? snapshot.points.count
        let dailyIndicatorPointCount = snapshot.dailyIndicatorPoints?.count
        // K-line overlays are calculated from the canonical trading-day source,
        // then projected onto week/month/quarter/year bars. Availability must
        // therefore be based on that source rather than the much smaller
        // aggregated series (for example, VOO has only a handful of year bars).
        let technicalPointCount: Int
        if range?.isMinuteRange == true {
            technicalPointCount = indicatorPointCount
        } else if let dailyIndicatorPointCount {
            technicalPointCount = dailyIndicatorPointCount
        } else {
            technicalPointCount = indicatorPointCount
        }
        switch mode {
        case .line:
            return true
        case .preMarket:
            return range.map { $0 == .intraday } ?? true
                && !snapshot.preMarketPoints.isEmpty
        case .postMarket:
            return range.map { $0 == .intraday } ?? true
                && !snapshot.postMarketPoints.isEmpty
        case .candlestick:
            return snapshot.supportsCandlesticks
        case .movingAverage:
            return technicalPointCount >= 5
        case .bollingerBands:
            return technicalPointCount >= 20
        case .volume:
            return snapshot.points.contains { ($0.volume ?? 0) > 0 }
        case .macd:
            return technicalPointCount >= 2
        case .rsi:
            if range == .fiveDays {
                return (dailyIndicatorPointCount ?? 0) >= 15
            }
            return technicalPointCount >= 15
        }
    }

    static func rangePerformance(
        snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket,
        visibleXDomain: ClosedRange<Double>? = nil
    ) -> (change: Double, percent: Double)? {
        guard let latest = snapshot.latestPoint,
              let referencePrice = rangeReferencePrice(
                snapshot: snapshot,
                range: range,
                market: market,
                visibleXDomain: visibleXDomain
              ) else { return nil }
        guard referencePrice != 0 else { return nil }
        let change = latest.close - referencePrice
        return (change, change / referencePrice)
    }

    static func rangeReferencePrice(
        snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket,
        visibleXDomain: ClosedRange<Double>? = nil
    ) -> Double? {
        guard let first = snapshot.points.first else { return nil }
        switch range {
        case .intraday:
            return intradayPreviousClose(
                snapshot: snapshot,
                market: market
            ) ?? first.close
        case .fiveDays:
            let sortedPoints = snapshot.points.sorted { $0.date < $1.date }
            if let visibleXDomain {
                return sortedPoints.first(where: {
                    $0.date.timeIntervalSinceReferenceDate >= visibleXDomain.lowerBound
                })?.close ?? sortedPoints.first?.close ?? first.close
            }
            return sortedPoints.first?.close ?? first.close
        case .dayK, .weekK, .monthK, .quarterK, .yearK,
             .oneMonth, .threeMonths, .oneYear,
             .fiveYears, .tenYears, .sinceInception:
            if let visibleXDomain {
                let sortedPoints = snapshot.points.sorted { $0.date < $1.date }
                if let visibleFirst = sortedPoints.first(where: {
                    $0.date.timeIntervalSinceReferenceDate >= visibleXDomain.lowerBound
                }) {
                    return visibleFirst.close
                }
            }
            // Before the chart finishes its first layout pass there is no
            // bound viewport yet. Use the same default K-line window as the
            // canvas so the header does not briefly calculate against the
            // listing-day price.
            let sortedPoints = snapshot.points.sorted { $0.date < $1.date }
            let defaultCount: Int
            switch range {
            case .dayK: defaultCount = 65
            case .weekK: defaultCount = 104
            case .monthK: defaultCount = 60
            case .quarterK: defaultCount = 40
            case .yearK: defaultCount = sortedPoints.count
            default: defaultCount = sortedPoints.count
            }
            return sortedPoints.dropFirst(
                max(0, sortedPoints.count - defaultCount)
            ).first?.close ?? first.close
        }
    }

    static func intradayPreviousClose(
        snapshot: StockChartSnapshot,
        market: StockMarket
    ) -> Double? {
        guard let latest = snapshot.latestPoint else { return nil }
        return closingPrice(
            beforeTradingDayContaining: latest.date,
            in: snapshot.indicatorPoints ?? snapshot.points,
            market: market
        ) ?? snapshot.previousClose
    }

    static func candleWidth(pointCount: Int, isExpanded: Bool) -> CGFloat {
        let multiplier: CGFloat = isExpanded ? 1.25 : 1
        switch pointCount {
        case 0...30: return 8 * multiplier
        case 31...80: return 7 * multiplier
        case 81...160: return 5 * multiplier
        case 161...320: return 3.5 * multiplier
        default: return 2.5 * multiplier
        }
    }

    static func indicatorBarWidth(pointCount: Int, isExpanded: Bool) -> CGFloat {
        switch pointCount {
        case 0...40: return isExpanded ? 8 : 5
        case 41...100: return isExpanded ? 5 : 2.5
        case 101...200: return isExpanded ? 3 : 1.25
        default: return isExpanded ? 1.1 : 0.75
        }
    }

    static func timeZone(for market: StockMarket) -> TimeZone {
        let identifier: String
        switch market {
        case .aShare: identifier = "Asia/Shanghai"
        case .hongKong: identifier = "Asia/Hong_Kong"
        case .unitedStates: identifier = "America/New_York"
        }
        return TimeZone(identifier: identifier) ?? .gmt
    }

    static func priceText(_ value: Double, currencyCode: String) -> String {
        StockValueFormatter.price(Decimal(value), currencyCode: currencyCode)
    }

    static func plainPriceText(_ value: Double) -> String {
        decimalText(value, minimumFractionDigits: 2, maximumFractionDigits: 4)
    }

    static func indicatorText(_ value: Double) -> String {
        decimalText(value, minimumFractionDigits: 2, maximumFractionDigits: 4)
    }

    static func signedPriceText(_ value: Double, currencyCode: String) -> String {
        let prefix = value >= 0 ? "+" : "-"
        return prefix + priceText(abs(value), currencyCode: currencyCode)
    }

    static func clampedReferencePrice(
        _ value: Double,
        to domain: ClosedRange<Double>
    ) -> Double {
        min(max(value, domain.lowerBound), domain.upperBound)
    }

    static func volumeText(_ value: Double) -> String {
        switch abs(value) {
        case 100_000_000...:
            return String(format: "%.2f 亿", value / 100_000_000)
        case 10_000...:
            return String(format: "%.2f 万", value / 10_000)
        default:
            return decimalText(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
        }
    }

    private static func technicalPlotPoints(
        for plotPoints: [StockChartPlotPoint],
        in snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket
    ) -> [StockTechnicalPlotPoint] {
        let rawSourcePoints = (snapshot.indicatorPoints ?? plotPoints.map(\.point))
            .sorted { $0.date < $1.date }
        let sourcePoints: [StockChartPoint]
        if range.isMinuteRange {
            // Extended-hours bars are separate chart layers and must not
            // change regular-session technical values.
            let regularSessionPoints = StockChartSeriesProcessor.regularSessionPoints(
                rawSourcePoints,
                market: market
            )
            // Some persisted/test snapshots contain daily points while the
            // selected five-day view is still minute-based. Keep those
            // points usable for the daily RSI fallback when no intraday
            // regular-session bars are available.
            sourcePoints = regularSessionPoints.isEmpty && range == .fiveDays
                ? rawSourcePoints
                : regularSessionPoints
        } else {
            sourcePoints = rawSourcePoints
        }

        if range.isMinuteRange {
            // Keep the full minute history for indicator warm-up, then project
            // only the visible minute bars onto the chart. This gives the
            // first visible bar a real MA/BOLL/RSI state without drawing the
            // historical warm-up bars themselves.
            let minutePlotPoints = projectedTechnicalPlotPoints(
                StockTechnicalIndicators.calculate(sourcePoints),
                onto: plotPoints
            )
            guard range == .fiveDays,
                  let dailyPoints = snapshot.dailyIndicatorPoints,
                  !dailyPoints.isEmpty else {
                return minutePlotPoints
            }

            // Five-day price/overlay charts remain minute-based, but RSI keeps
            // the trading-day definition used everywhere except the intraday
            // chart. Project only the two RSI periods onto the minute points.
            let dailyIndicators = StockTechnicalIndicators.calculate(
                dailyPoints.sorted { $0.date < $1.date }
            )
            guard !dailyIndicators.isEmpty else { return minutePlotPoints }
            var dailyIndex = 0
            return minutePlotPoints.map { plotPoint in
                while dailyIndex + 1 < dailyIndicators.count,
                      dailyIndicators[dailyIndex + 1].date
                        <= plotPoint.indicator.date {
                    dailyIndex += 1
                }
                guard dailyIndicators[dailyIndex].date <= plotPoint.indicator.date else {
                    return plotPoint
                }
                let dailyIndicator = dailyIndicators[dailyIndex]
                return StockTechnicalPlotPoint(
                    indicator: plotPoint.indicator.replacingRSI(
                        with14: dailyIndicator.rsi14,
                        and30: dailyIndicator.rsi30
                    ),
                    x: plotPoint.x
                )
            }
        }

        // K-line overlays use the complete daily source regardless of the
        // display aggregation. This keeps MA/BOLL/MACD/RSI stable when moving
        // from daily to weekly/monthly/quarterly/yearly bars and gives long-
        // lived ETFs enough history for a 20-day Bollinger window.
        let dailyPoints = (snapshot.dailyIndicatorPoints ?? sourcePoints)
            .sorted { $0.date < $1.date }
        let dailyIndicators = StockTechnicalIndicators.calculate(dailyPoints)
        guard !dailyIndicators.isEmpty else { return [] }
        return projectedTechnicalPlotPoints(
            dailyIndicators,
            onto: plotPoints,
            replaceIndicatorDate: true
        )
    }

    private static func projectedTechnicalPlotPoints(
        _ indicators: [StockTechnicalIndicatorPoint],
        onto plotPoints: [StockChartPlotPoint],
        replaceIndicatorDate: Bool = false
    ) -> [StockTechnicalPlotPoint] {
        guard !indicators.isEmpty, !plotPoints.isEmpty else { return [] }
        let sortedIndicators = indicators.sorted { $0.date < $1.date }
        var indicatorIndex = 0
        return plotPoints.compactMap { plotPoint in
            while indicatorIndex + 1 < sortedIndicators.count,
                  sortedIndicators[indicatorIndex + 1].date
                    <= plotPoint.point.date {
                indicatorIndex += 1
            }
            guard sortedIndicators[indicatorIndex].date <= plotPoint.point.date else {
                return nil
            }
            let indicator = replaceIndicatorDate
                ? sortedIndicators[indicatorIndex].replacing(date: plotPoint.point.date)
                : sortedIndicators[indicatorIndex]
            return StockTechnicalPlotPoint(indicator: indicator, x: plotPoint.x)
        }
    }

    private static func closingPrice(
        beforeTradingDayContaining date: Date,
        in points: [StockChartPoint],
        market: StockMarket
    ) -> Double? {
        let startOfTradingDay = StockChartSeriesProcessor
            .marketCalendar(market)
            .startOfDay(for: date)
        return points
            .filter { $0.date < startOfTradingDay }
            .max { $0.date < $1.date }?
            .close
    }

    private static func transactionMarkers(
        for stock: StockHolding,
        in snapshot: StockChartSnapshot,
        range: StockChartRange,
        plotPoints: [StockChartPlotPoint]
    ) -> [StockTransactionMarker] {
        let marketCalendar = calendar(for: stock.market)
        let sourcePoints = range.isMinuteRange
            ? (snapshot.indicatorPoints ?? snapshot.points)
            : snapshot.points
        return stock.transactions.compactMap { transaction in
            guard transaction.quantity > 0,
                  transaction.unitPrice > 0,
                  let transactionDate = marketDate(
                    for: transaction.tradedAt,
                    market: stock.market
                  ) else { return nil }

            let matchingPoints = sourcePoints.filter { point in
                if range == .weekK || range == .fiveYears || range == .tenYears {
                    return marketCalendar.dateInterval(of: .weekOfYear, for: point.date)?
                        .contains(transactionDate) == true
                }
                if range == .monthK || range == .sinceInception {
                    return marketCalendar.dateInterval(of: .month, for: point.date)?
                        .contains(transactionDate) == true
                }
                if range == .quarterK {
                    let pointComponents = marketCalendar.dateComponents([.year, .month], from: point.date)
                    let transactionComponents = marketCalendar.dateComponents(
                        [.year, .month],
                        from: transactionDate
                    )
                    return pointComponents.year == transactionComponents.year
                        && pointComponents.month.map { (($0 - 1) / 3) }
                            == transactionComponents.month.map { (($0 - 1) / 3) }
                }
                if range == .yearK {
                    return marketCalendar.component(.year, from: point.date)
                        == marketCalendar.component(.year, from: transactionDate)
                }
                return marketCalendar.isDate(point.date, inSameDayAs: transactionDate)
            }
            guard !matchingPoints.isEmpty else { return nil }
            let markerPoint: StockChartPoint
            let markerPrice: Double
            if range == .intraday {
                let transactionPrice = NSDecimalNumber(decimal: transaction.unitPrice).doubleValue
                markerPoint = matchingPoints.min { left, right in
                    let leftDistance = abs(left.close - transactionPrice)
                    let rightDistance = abs(right.close - transactionPrice)
                    if leftDistance == rightDistance {
                        return left.date < right.date
                    }
                    return leftDistance < rightDistance
                } ?? matchingPoints[0]
                markerPrice = transactionPrice
            } else if range == .fiveDays {
                markerPoint = matchingPoints[matchingPoints.count / 2]
                markerPrice = markerPoint.close
            } else {
                markerPoint = matchingPoints.last ?? matchingPoints[0]
                markerPrice = markerPoint.close
            }
            guard let plotPoint = plotPoints.first(where: {
                $0.point.id == markerPoint.id
            }) else { return nil }
            return StockTransactionMarker(
                id: transaction.id,
                date: markerPoint.date,
                plotX: plotPoint.x,
                plotPrice: markerPrice,
                type: transaction.type,
                quantity: transaction.quantity,
                unitPrice: transaction.unitPrice
            )
        }
        .sorted { $0.date < $1.date }
    }

    private static func marketDate(for date: Date, market: StockMarket) -> Date? {
        let localComponents = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day],
            from: date
        )
        var marketComponents = localComponents
        marketComponents.calendar = calendar(for: market)
        marketComponents.timeZone = timeZone(for: market)
        marketComponents.hour = 12
        return marketComponents.calendar?.date(from: marketComponents)
    }

    private static func xValue(
        for point: StockChartPoint,
        index: Int,
        range: StockChartRange
    ) -> Double {
        switch range {
        case .intraday, .fiveDays:
            return Double(index)
        default:
            return point.date.timeIntervalSinceReferenceDate
        }
    }

    private static func xDomain(
        for plotPoints: [StockChartPlotPoint]
    ) -> ClosedRange<Double> {
        guard let minimum = plotPoints.map(\.x).min(),
              let maximum = plotPoints.map(\.x).max() else {
            return 0...1
        }
        guard minimum != maximum else { return (minimum - 1)...(maximum + 1) }
        return minimum...maximum
    }

    func defaultVisibleXDomain(isExpanded _: Bool) -> ClosedRange<Double> {
        if range.isMinuteRange {
            let minutePlotPoints = allPricePlotPoints
            guard let latest = minutePlotPoints.last else { return xDomain }
            let calendar = Self.calendar(for: stock.market)
            let latestDay = calendar.startOfDay(for: latest.point.date)
            let startIndex: Int
            if range == .intraday {
                startIndex = minutePlotPoints.firstIndex {
                    calendar.isDate($0.point.date, inSameDayAs: latestDay)
                } ?? 0
            } else {
                var days: [Date] = []
                for point in minutePlotPoints.reversed() {
                    let day = calendar.startOfDay(for: point.point.date)
                    if !days.contains(day) { days.append(day) }
                    if days.count == 5 { break }
                }
                let earliestDay = days.last ?? latestDay
                startIndex = minutePlotPoints.firstIndex {
                    calendar.isDate($0.point.date, inSameDayAs: earliestDay)
                } ?? 0
            }
            var lower = minutePlotPoints[startIndex].x
            var upper = latest.x
            if range == .intraday, hasPreMarketChart, let first = preMarketPlotPoints.first?.x {
                lower = min(lower, first)
            }
            if range == .intraday, hasPostMarketChart, let last = postMarketPlotPoints.last?.x {
                upper = max(upper, last)
            }
            guard lower < upper else { return xDomain }
            return clampedVisibleXDomain(lower...upper)
        }

        guard range.isKLineRange else { return xDomain }
        guard let latest = plotPoints.last else { return xDomain }
        let pointCount = min(
            defaultKLinePointCount,
            plotPoints.count
        )
        guard pointCount > 1,
              plotPoints.count >= pointCount else {
            return xDomain
        }
        let first = plotPoints[plotPoints.count - pointCount].x
        guard first < latest.x else {
            return xDomain
        }
        return clampedVisibleXDomain(first...latest.x)
    }

    private var defaultKLinePointCount: Int {
        switch range {
        case .dayK: return 65
        case .weekK: return 104
        case .monthK: return 60
        case .quarterK: return 40
        case .yearK: return plotPoints.count
        default: return plotPoints.count
        }
    }

    /// Keeps a persisted/gesture-created viewport inside the complete data
    /// domain. A refresh can replace the available history, so callers should
    /// clamp before passing the viewport to `Chart`.
    func clampedVisibleXDomain(_ candidate: ClosedRange<Double>) -> ClosedRange<Double> {
        let fullLength = xDomain.upperBound - xDomain.lowerBound
        guard fullLength > 0 else { return xDomain }
        let candidateLength = candidate.upperBound - candidate.lowerBound
        guard candidateLength > 0 else { return xDomain }
        let length = min(candidateLength, fullLength)
        let lower = min(
            max(candidate.lowerBound, xDomain.lowerBound),
            xDomain.upperBound - length
        )
        return lower...(lower + length)
    }

    func visibleData(in visibleXDomain: ClosedRange<Double>) -> StockChartVisibleData {
        StockChartVisibleData(
            plotPoints: plotPoints.filter { visibleXDomain.contains($0.x) },
            preMarketPlotPoints: preMarketPlotPoints.filter {
                visibleXDomain.contains($0.x)
            },
            postMarketPlotPoints: postMarketPlotPoints.filter {
                visibleXDomain.contains($0.x)
            },
            technicalPlotPoints: technicalPlotPoints.filter {
                visibleXDomain.contains($0.x)
            },
            transactionMarkers: transactionMarkers.filter {
                visibleXDomain.contains($0.plotX)
            }
        )
    }

    func visiblePlotPointCount(in visibleXDomain: ClosedRange<Double>) -> Int {
        visibleData(in: visibleXDomain).plotPointCount
    }

    func yDomain(for visibleXDomain: ClosedRange<Double>) -> ClosedRange<Double> {
        yDomain(for: visibleData(in: visibleXDomain))
    }

    func yDomain(for visibleData: StockChartVisibleData) -> ClosedRange<Double> {
        guard range.isMinuteRange || range.isKLineRange else { return yDomain }
        guard visibleData.containsPricePoints else {
            return yDomain
        }
        return Self.yDomain(
            snapshot: snapshot,
            displayModes: displayModes,
            technicalPlotPoints: visibleData.technicalPlotPoints,
            transactionMarkers: visibleData.transactionMarkers,
            plotPoints: visibleData.plotPoints,
            preMarketPlotPoints: visibleData.preMarketPlotPoints,
            postMarketPlotPoints: visibleData.postMarketPlotPoints
        )
    }

    private static func yDomain(
        snapshot: StockChartSnapshot,
        displayModes: Set<StockChartDisplayMode>,
        technicalPlotPoints: [StockTechnicalPlotPoint],
        transactionMarkers: [StockTransactionMarker],
        plotPoints: [StockChartPlotPoint],
        preMarketPlotPoints: [StockChartPlotPoint],
        postMarketPlotPoints: [StockChartPlotPoint]
    ) -> ClosedRange<Double> {
        if displayModes.contains(.rsi) { return 0...100 }
        if displayModes.contains(.volume) {
            var volumePoints = plotPoints.map(\.point)
            if displayModes.contains(.preMarket) {
                volumePoints += preMarketPlotPoints.map(\.point)
            }
            if displayModes.contains(.postMarket) {
                volumePoints += postMarketPlotPoints.map(\.point)
            }
            let maximum = volumePoints
                .compactMap(\.volume)
                .max() ?? 0
            return 0...max(maximum * 1.08, 1)
        }
        if displayModes.contains(.macd) {
            var values = [0.0]
            values += technicalPlotPoints.flatMap { point in
                [
                    point.indicator.macdLine,
                    point.indicator.macdSignal,
                    point.indicator.macdHistogram
                ]
            }
            return paddedDomain(values)
        }

        var values: [Double] = []
        if displayModes.contains(.line) { values += plotPoints.map(\.point.close) }
        if displayModes.contains(.candlestick) {
            values += plotPoints.flatMap { [$0.point.low, $0.point.high] }
        }
        if displayModes.contains(.movingAverage) {
            values += technicalPlotPoints.flatMap { point in
                [
                    point.indicator.movingAverage5,
                    point.indicator.movingAverage20,
                    point.indicator.movingAverage60
                ].compactMap { $0 }
            }
        }
        if displayModes.contains(.bollingerBands) {
            values += technicalPlotPoints.flatMap { point in
                [
                    point.indicator.bollingerUpper,
                    point.indicator.bollingerLower
                ].compactMap { $0 }
            }
        }
        if displayModes.contains(.preMarket) {
            values += preMarketPlotPoints.map(\.point.close)
        }
        if displayModes.contains(.postMarket) {
            values += postMarketPlotPoints.map(\.point.close)
        }
        if displayModes.contains(.line) || displayModes.contains(.candlestick) {
            values += transactionMarkers.map(\.plotPrice)
        }
        return paddedDomain(values)
    }

    private static func paddedDomain(_ values: [Double]) -> ClosedRange<Double> {
        guard !values.isEmpty else { return 0...1 }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let spread = maximum - minimum
        let padding = max(spread * 0.08, max(abs(maximum) * 0.002, 0.01))
        return (minimum - padding)...(maximum + padding)
    }

    private static func calendar(for market: StockMarket) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(for: market)
        return calendar
    }

    private static func dateFormatter(market: StockMarket) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone(for: market)
        return formatter
    }

    private static func decimalText(
        _ value: Double,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "--"
    }
}

#endif
