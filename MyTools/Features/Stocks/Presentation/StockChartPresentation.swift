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
    case kdj
    case williamsR
    case cci
    case dmi
    case momentum
    case trix
    case volumeFlow
    case mfi
    case chaikinMoneyFlow
    case psychologicalLine
    case rateOfChange

    var id: Self { self }

    var title: String {
        switch self {
        case .preMarket: return "盘前"
        case .line: return "盘中"
        case .postMarket: return "盘后"
        case .candlestick: return "K 线"
        case .movingAverage: return "均线"
        case .bollingerBands: return "布林"
        case .volume: return "成交量"
        case .macd: return "MACD"
        case .rsi: return "RSI"
        case .kdj: return "KDJ"
        case .williamsR: return "W%R"
        case .cci: return "CCI"
        case .dmi: return "DMI"
        case .momentum: return "MTM"
        case .trix: return "TRIX"
        case .volumeFlow: return "OBV / A·D"
        case .mfi: return "MFI"
        case .chaikinMoneyFlow: return "Chaikin"
        case .psychologicalLine: return "PSY"
        case .rateOfChange: return "ROC"
        }
    }

    var isPriceChart: Bool {
        switch self {
        case .line, .candlestick, .movingAverage, .bollingerBands:
            return true
        case .preMarket, .postMarket, .volume, .macd, .rsi, .kdj,
                .williamsR, .cci, .dmi, .momentum, .trix, .volumeFlow,
                .mfi, .chaikinMoneyFlow, .psychologicalLine, .rateOfChange:
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
    /// Mode-independent chart work. Session filtering, indicator projection,
    /// and transaction matching are intentionally prepared once so toggling
    /// pre-market/regular/post-market layers only remaps their ordinal x
    /// coordinates instead of recalculating the complete chart on the main
    /// thread.
    private struct PreparedData {
        let regularPoints: [StockChartPoint]
        let preMarketPoints: [StockChartPoint]
        let postMarketPoints: [StockChartPoint]
        let standalonePreMarketPoints: [StockChartPoint]
        let standalonePostMarketPoints: [StockChartPoint]
        let technicalPlotPoints: [StockTechnicalPlotPoint]
        let transactionMarkers: [StockTransactionMarker]
    }

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
    private let preparedData: PreparedData
    let cachedIntradayPreviousClose: Double?
    private let decimalFormatter: NumberFormatter
    private let chartDateFormatter: DateFormatter
    private let axisDateFormatter: DateFormatter

    static func headerPerformanceTitle(for range: StockChartRange) -> String {
        range == .intraday ? "今日涨跌" : "区间涨跌"
    }

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
        range == .intraday
            && stock.market.supportsExtendedHoursChart
            && displayModes.contains(.preMarket)
    }

    var hasPostMarketChart: Bool {
        range == .intraday
            && stock.market.supportsExtendedHoursChart
            && displayModes.contains(.postMarket)
    }

    var preMarketTitle: String { "盘前" }

    var postMarketTitle: String { "盘后" }

    init(
        snapshot: StockChartSnapshot,
        stock: StockHolding,
        range: StockChartRange,
        displayModes: Set<StockChartDisplayMode>
    ) {
        let preparedData = Self.prepare(
            snapshot: snapshot,
            stock: stock,
            range: range
        )
        self.init(
            snapshot: snapshot,
            stock: stock,
            range: range,
            displayModes: displayModes,
            preparedData: preparedData
        )
    }

    /// Returns the same cached chart data with a different visible layer
    /// combination. This is the hot path used by the mode picker.
    func updatingDisplayModes(
        _ displayModes: Set<StockChartDisplayMode>
    ) -> StockChartPresentation {
        StockChartPresentation(
            snapshot: snapshot,
            stock: stock,
            range: range,
            displayModes: displayModes,
            preparedData: preparedData
        )
    }

    private init(
        snapshot: StockChartSnapshot,
        stock: StockHolding,
        range: StockChartRange,
        displayModes: Set<StockChartDisplayMode>,
        preparedData: PreparedData
    ) {
        self.snapshot = snapshot
        self.stock = stock
        self.range = range
        self.displayModes = displayModes
        self.preparedData = preparedData

        let hasRegularPriceChart = displayModes.contains(.line)
        let availablePreMarketPoints = hasRegularPriceChart
            ? preparedData.preMarketPoints
            : preparedData.standalonePreMarketPoints
        let availablePostMarketPoints = hasRegularPriceChart
            ? preparedData.postMarketPoints
            : preparedData.standalonePostMarketPoints
        let preMarketCount = range == .intraday
            && displayModes.contains(.preMarket)
            && hasRegularPriceChart
            ? availablePreMarketPoints.count
            : 0
        let plotPoints = preparedData.regularPoints.enumerated().map { index, point in
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
        preMarketPlotPoints = (displayModes.contains(.preMarket) ? availablePreMarketPoints : [])
            .enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: Self.xValue(for: point, index: index, range: range)
            )
        }
        let postMarketOffset = hasRegularPriceChart
            ? preMarketCount + preparedData.regularPoints.count
            : 0
        postMarketPlotPoints = (displayModes.contains(.postMarket) ? availablePostMarketPoints : [])
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
        technicalPlotPoints = preparedData.technicalPlotPoints.map {
            StockTechnicalPlotPoint(indicator: $0.indicator, x: $0.x + Double(preMarketCount))
        }
        transactionMarkers = preparedData.transactionMarkers.map {
            StockTransactionMarker(
                id: $0.id,
                date: $0.date,
                plotX: $0.plotX + Double(preMarketCount),
                plotPrice: $0.plotPrice,
                type: $0.type,
                quantity: $0.quantity,
                unitPrice: $0.unitPrice
            )
        }
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
        preMarketPointIDs = Set(preMarketPlotPoints.map { $0.point.id })
        postMarketPointIDs = Set(postMarketPlotPoints.map { $0.point.id })

        if range == .intraday || range == .fiveDays {
            cachedIntradayPreviousClose = Self.intradayPreviousClose(
                snapshot: snapshot,
                market: stock.market
            )
        } else {
            cachedIntradayPreviousClose = nil
        }

        let numFmt = NumberFormatter()
        numFmt.numberStyle = .decimal
        decimalFormatter = numFmt

        let chartDateFmt = DateFormatter()
        chartDateFmt.locale = Locale(identifier: "zh_CN")
        chartDateFmt.timeZone = Self.timeZone(for: stock.market)
        chartDateFmt.dateFormat = range == .intraday || range == .fiveDays ? "MM-dd HH:mm" : "yyyy-MM-dd"
        chartDateFormatter = chartDateFmt

        let axisFmt = DateFormatter()
        axisFmt.locale = Locale(identifier: "zh_CN")
        axisFmt.timeZone = Self.timeZone(for: stock.market)
        switch range {
        case .intraday:
            axisFmt.dateFormat = "HH:mm"
        case .fiveDays, .dayK:
            axisFmt.dateFormat = "MM-dd"
        case .weekK, .monthK, .quarterK, .yearK:
            axisFmt.dateFormat = "yyyy"
        }
        axisDateFormatter = axisFmt
    }

    private static func prepare(
        snapshot: StockChartSnapshot,
        stock: StockHolding,
        range: StockChartRange
    ) -> PreparedData {
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
        let basePlotPoints = regularPoints.enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: Self.xValue(for: point, index: index, range: range)
            )
        }
        return PreparedData(
            regularPoints: regularPoints,
            preMarketPoints: scopedExtendedHoursPoints(
                snapshot.preMarketPoints,
                regularPoints: regularPoints,
                market: stock.market
            ),
            postMarketPoints: scopedExtendedHoursPoints(
                snapshot.postMarketPoints,
                regularPoints: regularPoints,
                market: stock.market
            ),
            standalonePreMarketPoints: scopedExtendedHoursPoints(
                snapshot.preMarketPoints,
                regularPoints: [],
                market: stock.market
            ),
            standalonePostMarketPoints: scopedExtendedHoursPoints(
                snapshot.postMarketPoints,
                regularPoints: [],
                market: stock.market
            ),
            technicalPlotPoints: technicalPlotPoints(
                for: basePlotPoints,
                in: snapshot,
                range: range,
                market: stock.market
            ),
            transactionMarkers: transactionMarkers(
                for: stock,
                in: snapshot,
                range: range,
                plotPoints: basePlotPoints
            )
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
        selectedPlotPoint(at: date)?.point
    }

    func selectedPlotPoint(at date: Date?) -> StockChartPlotPoint? {
        guard let date else { return nil }
        return closestDatePlotPoint(
            in: 0..<allPricePlotPoints.count,
            to: date
        )
    }

    func selectedTechnicalPlotPoint(at date: Date?) -> StockTechnicalPlotPoint? {
        guard let date else { return nil }
        guard !technicalPlotPoints.isEmpty else { return nil }
        let insertion = lowerBoundTechnicalDate(for: date)
        if insertion == 0 { return technicalPlotPoints[0] }
        if insertion == technicalPlotPoints.count {
            return technicalPlotPoints[insertion - 1]
        }
        let previous = technicalPlotPoints[insertion - 1]
        let next = technicalPlotPoints[insertion]
        return abs(previous.indicator.date.timeIntervalSince(date))
            <= abs(next.indicator.date.timeIntervalSince(date))
            ? previous
            : next
    }

    func plotPoint(closestTo x: Double) -> StockChartPlotPoint? {
        closestPlotPoint(
            in: 0..<allPricePlotPoints.count,
            to: x
        )
    }

    func plotPoint(
        closestTo x: Double,
        in visibleDomain: ClosedRange<Double>
    ) -> StockChartPlotPoint? {
        guard !allPricePlotPoints.isEmpty else { return nil }
        let start = lowerBound(for: visibleDomain.lowerBound)
        let end = upperBound(for: visibleDomain.upperBound)
        let range = start..<end
        return range.isEmpty
            ? plotPoint(closestTo: x)
            : closestPlotPoint(in: range, to: x)
    }

    /// The chart's price points are sorted by their x coordinate. A binary
    /// search keeps drag selection logarithmic instead of scanning every
    /// cached historical bar on each touch.
    private func closestPlotPoint(
        in range: Range<Int>,
        to x: Double
    ) -> StockChartPlotPoint? {
        guard !range.isEmpty else { return nil }
        let insertion = lowerBound(for: x, in: range)
        if insertion <= range.lowerBound {
            return allPricePlotPoints[range.lowerBound]
        }
        if insertion >= range.upperBound {
            return allPricePlotPoints[range.upperBound - 1]
        }
        let previous = allPricePlotPoints[insertion - 1]
        let next = allPricePlotPoints[insertion]
        return abs(previous.x - x) <= abs(next.x - x) ? previous : next
    }

    private func closestDatePlotPoint(
        in range: Range<Int>,
        to date: Date
    ) -> StockChartPlotPoint? {
        guard !range.isEmpty else { return nil }
        let insertion = lowerBoundDate(for: date, in: range)
        if insertion <= range.lowerBound {
            return allPricePlotPoints[range.lowerBound]
        }
        if insertion >= range.upperBound {
            return allPricePlotPoints[range.upperBound - 1]
        }
        let previous = allPricePlotPoints[insertion - 1]
        let next = allPricePlotPoints[insertion]
        return abs(previous.point.date.timeIntervalSince(date))
            <= abs(next.point.date.timeIntervalSince(date))
            ? previous
            : next
    }

    private func lowerBound(for value: Double) -> Int {
        lowerBound(for: value, in: 0..<allPricePlotPoints.count)
    }

    private func lowerBound(for value: Double, in range: Range<Int>) -> Int {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if allPricePlotPoints[middle].x < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func lowerBoundDate(
        for value: Date,
        in range: Range<Int>
    ) -> Int {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if allPricePlotPoints[middle].point.date < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func lowerBoundTechnicalDate(for value: Date) -> Int {
        var lower = 0
        var upper = technicalPlotPoints.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if technicalPlotPoints[middle].indicator.date < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func upperBound(for value: Double) -> Int {
        var lower = 0
        var upper = allPricePlotPoints.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if allPricePlotPoints[middle].x <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    // Build lookup sets once so isPreMarket/isPostMarket are O(1) instead of
    // O(n) on every gesture-driven redraw.
    private let preMarketPointIDs: Set<Date>
    private let postMarketPointIDs: Set<Date>

    func isPreMarket(_ point: StockChartPoint) -> Bool {
        hasPreMarketChart && preMarketPointIDs.contains(point.id)
    }

    func isPostMarket(_ point: StockChartPoint) -> Bool {
        hasPostMarketChart && postMarketPointIDs.contains(point.id)
    }

    func technicalIndicator(at point: StockChartPoint) -> StockTechnicalIndicatorPoint? {
        guard let plotPoint = selectedTechnicalPlotPoint(at: point.date),
              plotPoint.indicator.date == point.date else {
            return nil
        }
        return plotPoint.indicator
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
        let visiblePoints = visibleElements(
            sourcePoints,
            in: visibleDomain,
            x: \.x
        )
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
        chartDateFormatter.string(from: date)
    }

    func axisLabelText(_ date: Date) -> String {
        axisDateFormatter.string(from: date)
    }

    static func isModeAvailable(
        _ mode: StockChartDisplayMode,
        in snapshot: StockChartSnapshot?,
        range: StockChartRange? = nil,
        market: StockMarket? = nil
    ) -> Bool {
        if (mode == .preMarket || mode == .postMarket),
           market?.supportsExtendedHoursChart == false {
            return false
        }
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
        case .kdj:
            return technicalPointCount >= 9
        case .williamsR, .cci, .mfi:
            return technicalPointCount >= 14
                && (mode != .mfi || snapshot.points.contains { ($0.volume ?? 0) > 0 })
        case .dmi:
            return technicalPointCount >= 28
        case .momentum, .rateOfChange:
            return technicalPointCount >= 11
        case .trix:
            return technicalPointCount >= 96
        case .volumeFlow:
            return technicalPointCount >= 2
                && snapshot.points.contains { ($0.volume ?? 0) > 0 }
        case .chaikinMoneyFlow:
            return technicalPointCount >= 21
                && snapshot.points.contains { ($0.volume ?? 0) > 0 }
        case .psychologicalLine:
            return technicalPointCount >= 13
        }
    }

    static func rangePerformance(
        snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket,
        visibleXDomain: ClosedRange<Double>? = nil,
        quotePreviousClose: Double? = nil,
        quoteUpdatedAt: Date? = nil
    ) -> (change: Double, percent: Double)? {
        guard let latest = snapshot.latestPoint,
              let referencePrice = rangeReferencePrice(
                snapshot: snapshot,
                range: range,
                market: market,
                visibleXDomain: visibleXDomain,
                quotePreviousClose: quotePreviousClose,
                quoteUpdatedAt: quoteUpdatedAt
              ) else { return nil }
        guard referencePrice != 0 else { return nil }
        let change = latest.close - referencePrice
        return (change, change / referencePrice)
    }

    static func rangeReferencePrice(
        snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket,
        visibleXDomain: ClosedRange<Double>? = nil,
        quotePreviousClose: Double? = nil,
        quoteUpdatedAt: Date? = nil
    ) -> Double? {
        guard let first = snapshot.points.first else { return nil }
        switch range {
        case .intraday:
            return intradayPreviousClose(
                snapshot: snapshot,
                market: market,
                quotePreviousClose: quotePreviousClose,
                quoteUpdatedAt: quoteUpdatedAt
            )
        case .fiveDays:
            let sortedPoints = snapshot.points.sorted { $0.date < $1.date }
            if let visibleXDomain {
                return pointAtVisibleStart(
                    sortedPoints,
                    visibleXDomain: visibleXDomain
                )?.close ?? sortedPoints.first?.close ?? first.close
            }
            return sortedPoints.first?.close ?? first.close
        case .dayK, .weekK, .monthK, .quarterK, .yearK:
            if let visibleXDomain {
                let sortedPoints = snapshot.points.sorted { $0.date < $1.date }
                if let visibleFirst = pointAtVisibleStart(
                    sortedPoints,
                    visibleXDomain: visibleXDomain
                ) {
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

    /// Returns the first bar visible in the dense ordinal x-domain.
    private static func pointAtVisibleStart(
        _ sortedPoints: [StockChartPoint],
        visibleXDomain: ClosedRange<Double>
    ) -> StockChartPoint? {
        guard !sortedPoints.isEmpty else { return nil }
        let index = min(
            max(Int(visibleXDomain.lowerBound.rounded(.up)), 0),
            sortedPoints.count - 1
        )
        return sortedPoints[index]
    }

    static func intradayPreviousClose(
        snapshot: StockChartSnapshot,
        market: StockMarket,
        quotePreviousClose: Double? = nil,
        quoteUpdatedAt: Date? = nil
    ) -> Double? {
        guard let latest = snapshot.latestPoint else { return nil }
        let dailyPreviousClose = snapshot.dailyIndicatorPoints.flatMap {
            closingPrice(
                beforeTradingDayContaining: latest.date,
                in: $0,
                market: market
            )
        }
        let minutePreviousClose = closingPrice(
            beforeTradingDayContaining: latest.date,
            in: snapshot.indicatorPoints ?? snapshot.points,
            market: market
        )

        // Only accept a quote from the same market-local day as the visible
        // regular session. During the next day's pre-market, the quote's
        // `previousClose` has already advanced to the visible day's close.
        let calendar = StockChartSeriesProcessor.marketCalendar(market)
        let currentQuotePreviousClose: Double? = {
            guard let quotePreviousClose,
                  quotePreviousClose > 0,
                  let quoteUpdatedAt,
                  calendar.isDate(quoteUpdatedAt, inSameDayAs: latest.date) else {
                return nil
            }
            return quotePreviousClose
        }()

        // Daily bars and the provider quote contain the exchange's settled
        // previous close. A minute feed can end at 15:59 or before the closing
        // auction and therefore must only be a fallback (for example BRK.B
        // reported 503.70 officially while its last minute bar was 503.87).
        // A daily candidate is valid only when it belongs to the immediately
        // preceding trading day. Yahoo can publish a timestamp with a null
        // close; after parsing, an unrestricted search would otherwise skip
        // that missing session and reuse an older value (NVDA: 227.98 instead
        // of 217.55).
        //
        // Before the next regular session opens, however, `points` still shows
        // the preceding trading day while a quote provider may already expose
        // that day's close as the new session's reference. A newer pre-market
        // day therefore keeps the historical close-before-visible-day rule.
        let latestRegularDay = calendar.startOfDay(for: latest.date)
        let hasNewerPreMarketDay = snapshot.preMarketPoints.contains {
            calendar.startOfDay(for: $0.date) > latestRegularDay
        }
        if hasNewerPreMarketDay {
            return dailyPreviousClose ?? minutePreviousClose
        }
        return dailyPreviousClose
            ?? currentQuotePreviousClose
            ?? snapshot.previousClose
            ?? minutePreviousClose
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
            // Project the cached minute indicators onto visible bars. The raw
            // history remains available for cache misses and indicator warm-up
            // validation, but normal loads do not recalculate it here.
            let minuteIndicators = usableCachedIndicators(
                snapshot.cachedMinuteTechnicalIndicators,
                sourcePointCount: sourcePoints.count
            ) ?? StockTechnicalIndicators.calculate(sourcePoints)
            let minutePlotPoints = projectedTechnicalPlotPoints(
                minuteIndicators,
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
            let dailyIndicators = usableCachedIndicators(
                snapshot.cachedDailyTechnicalIndicators,
                sourcePointCount: dailyPoints.count
            ) ?? StockTechnicalIndicators.calculate(dailyPoints.sorted { $0.date < $1.date })
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

        // K-line overlays use the cached daily indicators regardless of the
        // display aggregation. This keeps MA/BOLL/MACD/RSI stable when moving
        // from daily to weekly/monthly/quarterly/yearly bars.
        let dailyPoints = (snapshot.dailyIndicatorPoints ?? sourcePoints)
            .sorted { $0.date < $1.date }
        let dailyIndicators = usableCachedIndicators(
            snapshot.cachedDailyTechnicalIndicators,
            sourcePointCount: dailyPoints.count
        ) ?? StockTechnicalIndicators.calculate(dailyPoints)
        guard !dailyIndicators.isEmpty else { return [] }
        return projectedTechnicalPlotPoints(
            dailyIndicators,
            onto: plotPoints,
            replaceIndicatorDate: true
        )
    }

    /// Indicators persisted by versions before the advanced indicator set can
    /// still decode, but their newly-added fields are nil. Recalculate from the
    /// local price cache once instead of presenting empty charts.
    private static func usableCachedIndicators(
        _ indicators: [StockTechnicalIndicatorPoint]?,
        sourcePointCount: Int
    ) -> [StockTechnicalIndicatorPoint]? {
        guard let indicators, !indicators.isEmpty else { return nil }
        guard indicators.count == sourcePointCount else { return nil }
        guard sourcePointCount < 9
                || indicators.contains(where: { $0.stochasticK != nil }) else {
            return nil
        }
        return indicators
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
        let calendar = StockChartSeriesProcessor.marketCalendar(market)
        guard let previousTradingDay = StockMarketTradingCalendar
            .previousTradingDay(for: market, before: date) else {
            return nil
        }
        return points
            .filter { calendar.isDate($0.date, inSameDayAs: previousTradingDay) }
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
        let sourcePoints = (range.isMinuteRange
            ? (snapshot.indicatorPoints ?? snapshot.points)
            : snapshot.points)
            .sorted { $0.date < $1.date }
        return stock.transactions.compactMap { transaction in
            guard transaction.quantity > 0,
                  transaction.unitPrice > 0 else { return nil }
            // `tradedAt` remains a Beijing/device-calendar date in storage.
            // US date-only entries are plotted on the preceding US calendar
            // day, which is the trading date represented by the same Beijing
            // date (for example, Beijing 8/22 -> US 8/21).
            let transactionDate = chartTransactionDate(
                for: transaction.tradedAt,
                market: stock.market
            )

            let exactMatchingPoints = sourcePoints.filter { point in
                if range == .weekK {
                    return marketCalendar.dateInterval(of: .weekOfYear, for: point.date)?
                        .contains(transactionDate) == true
                }
                if range == .monthK {
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
            // A date-only plotting date can still fall on a market holiday or
            // weekend. Use
            // the last trading bar on or before that instant so day K, five
            // day, and intraday views keep the marker instead of dropping it.
            let matchingPoints = exactMatchingPoints.isEmpty
                ? sourcePoints.last(where: { $0.date <= transactionDate }).map { [$0] } ?? []
                : exactMatchingPoints
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
        .sorted {
            if $0.plotX == $1.plotX {
                return $0.date < $1.date
            }
            return $0.plotX < $1.plotX
        }
    }

    private static func chartTransactionDate(
        for date: Date,
        market: StockMarket
    ) -> Date {
        guard market == .unitedStates else { return date }
        let calendar = Calendar.autoupdatingCurrent
        return calendar.date(byAdding: .day, value: -1, to: date) ?? date
    }

    private static func xValue(
        for _: StockChartPoint,
        index: Int,
        range _: StockChartRange
    ) -> Double {
        // Allocate one slot per bar for every range. Weekends and exchange
        // holidays then do not create misleading empty gaps on the x-axis;
        // the actual date remains available in axis labels and summaries.
        return Double(index)
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
                // Binary search: find first point whose day equals latestDay.
                // minutePlotPoints is sorted by x (ascending date), so a scan
                // from the tail is cheap — regular sessions have ≤ 391 points.
                startIndex = minutePlotPoints.lastIndex {
                    !calendar.isDate($0.point.date, inSameDayAs: latestDay)
                }.map { $0 + 1 } ?? 0
            } else {
                var days: [Date] = []
                for point in minutePlotPoints.reversed() {
                    let day = calendar.startOfDay(for: point.point.date)
                    if !days.contains(day) { days.append(day) }
                    if days.count == 5 { break }
                }
                let earliestDay = days.last ?? latestDay
                startIndex = minutePlotPoints.lastIndex {
                    !calendar.isDate($0.point.date, inSameDayAs: earliestDay)
                        && $0.point.date < earliestDay
                }.map { $0 + 1 } ?? 0
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
            plotPoints: visibleElements(
                plotPoints,
                in: visibleXDomain,
                x: \.x
            ),
            preMarketPlotPoints: visibleElements(
                preMarketPlotPoints,
                in: visibleXDomain,
                x: \.x
            ),
            postMarketPlotPoints: visibleElements(
                postMarketPlotPoints,
                in: visibleXDomain,
                x: \.x
            ),
            technicalPlotPoints: visibleElements(
                technicalPlotPoints,
                in: visibleXDomain,
                x: \.x
            ),
            transactionMarkers: visibleElements(
                transactionMarkers,
                in: visibleXDomain,
                x: \.plotX
            )
        )
    }

    /// All chart-layer collections are stored in ascending plot-coordinate
    /// order. Slice the visible window by binary search so selection redraws
    /// do not scan the complete offline history.
    private func visibleElements<Element>(
        _ elements: [Element],
        in domain: ClosedRange<Double>,
        x: KeyPath<Element, Double>
    ) -> [Element] {
        guard !elements.isEmpty else { return [] }
        var lower = 0
        var upper = elements.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if elements[middle][keyPath: x] < domain.lowerBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let start = lower

        lower = start
        upper = elements.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if elements[middle][keyPath: x] <= domain.upperBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return Array(elements[start..<lower])
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
        if !displayModes.isDisjoint(with: [.rsi, .kdj, .mfi, .psychologicalLine]) {
            return 0...100
        }
        if displayModes.contains(.williamsR) { return -100...0 }
        if displayModes.contains(.chaikinMoneyFlow) { return -1...1 }
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
        if displayModes.contains(.cci) {
            return paddedDomain([-100, 100] + technicalPlotPoints.compactMap {
                $0.indicator.commodityChannelIndex
            })
        }
        if displayModes.contains(.dmi) {
            let values = technicalPlotPoints.flatMap {
                [
                    $0.indicator.positiveDirectionalIndex,
                    $0.indicator.negativeDirectionalIndex,
                    $0.indicator.averageDirectionalIndex
                ].compactMap { $0 }
            }
            return 0...max(100, values.max() ?? 0)
        }
        if displayModes.contains(.momentum) {
            return paddedDomain([0] + technicalPlotPoints.flatMap {
                [$0.indicator.momentum, $0.indicator.momentumAverage].compactMap { $0 }
            })
        }
        if displayModes.contains(.trix) {
            return paddedDomain([0] + technicalPlotPoints.flatMap {
                [$0.indicator.trix, $0.indicator.trixSignal].compactMap { $0 }
            })
        }
        if displayModes.contains(.volumeFlow) {
            return paddedDomain([0] + technicalPlotPoints.flatMap {
                [
                    $0.indicator.onBalanceVolume,
                    $0.indicator.accumulationDistribution
                ].compactMap { $0 }
            })
        }
        if displayModes.contains(.rateOfChange) {
            return paddedDomain([0] + technicalPlotPoints.compactMap {
                $0.indicator.rateOfChange
            })
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
