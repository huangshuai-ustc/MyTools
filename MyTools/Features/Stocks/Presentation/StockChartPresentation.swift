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
        switch session {
        case .preMarket:
            return [.preMarket]
        case .regular:
            return [.preMarket, .line]
        case .postMarket:
            return [.preMarket, .line, .postMarket]
        case .closed:
            return [.line]
        }
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

struct StockChartPresentation {
    let snapshot: StockChartSnapshot
    let stock: StockHolding
    let range: StockChartRange
    let displayModes: Set<StockChartDisplayMode>
    let plotPoints: [StockChartPlotPoint]
    let preMarketPlotPoints: [StockChartPlotPoint]
    let postMarketPlotPoints: [StockChartPlotPoint]
    let technicalPlotPoints: [StockTechnicalPlotPoint]
    let transactionMarkers: [StockTransactionMarker]
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>

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
        let preMarketCount = range == .intraday
            && displayModes.contains(.preMarket)
            && hasRegularPriceChart
            ? snapshot.preMarketPoints.count
            : 0
        let plotPoints = snapshot.points.enumerated().map { index, point in
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
        preMarketPlotPoints = snapshot.preMarketPoints.enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: Self.xValue(for: point, index: index, range: range)
            )
        }
        postMarketPlotPoints = snapshot.postMarketPoints.enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: Self.xValue(
                    for: point,
                    index: index + preMarketCount + snapshot.points.count,
                    range: range
                )
            )
        }
        technicalPlotPoints = Self.technicalPlotPoints(
            for: plotPoints,
            in: snapshot
        )
        transactionMarkers = Self.transactionMarkers(
            for: stock,
            in: snapshot,
            range: range
        )
        var activePlotPoints = plotPoints
        if displayModes.contains(.preMarket) {
            activePlotPoints = hasRegularPriceChart
                ? preMarketPlotPoints + activePlotPoints
                : preMarketPlotPoints
        }
        if displayModes.contains(.postMarket) {
            activePlotPoints = hasRegularPriceChart
                ? activePlotPoints + postMarketPlotPoints
                : postMarketPlotPoints
        }
        xDomain = Self.xDomain(for: activePlotPoints)
        yDomain = Self.yDomain(
            snapshot: snapshot,
            displayModes: displayModes,
            technicalPlotPoints: technicalPlotPoints
        )
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

    func xAxisValues(isExpanded: Bool) -> [Double] {
        let axisPlotPoints = range == .intraday ? allPricePlotPoints : plotPoints
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

    private var allPricePlotPoints: [StockChartPlotPoint] {
        var points: [StockChartPlotPoint]
        if hasPreMarketChart {
            points = displayModes.contains(.line)
                ? preMarketPlotPoints + plotPoints
                : preMarketPlotPoints
        } else if hasPostMarketChart && !displayModes.contains(.line) {
            points = postMarketPlotPoints
        } else {
            points = plotPoints
        }
        if hasPostMarketChart && displayModes.contains(.line) {
            points += postMarketPlotPoints
        }
        return points.sorted { $0.x < $1.x }
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
        case .fiveDays, .oneMonth, .threeMonths, .oneYear:
            formatter.dateFormat = "MM-dd"
        case .fiveYears, .tenYears, .sinceInception:
            formatter.dateFormat = "yyyy"
        }
        return formatter.string(from: date)
    }

    static func isModeAvailable(
        _ mode: StockChartDisplayMode,
        in snapshot: StockChartSnapshot?
    ) -> Bool {
        guard let snapshot else { return mode == .line }
        let indicatorPointCount = snapshot.indicatorPoints?.count ?? snapshot.points.count
        switch mode {
        case .line:
            return true
        case .preMarket:
            return !snapshot.preMarketPoints.isEmpty
        case .postMarket:
            return !snapshot.postMarketPoints.isEmpty
        case .candlestick:
            return snapshot.supportsCandlesticks
        case .movingAverage:
            return indicatorPointCount >= 5
        case .bollingerBands:
            return indicatorPointCount >= 20
        case .volume:
            return snapshot.points.contains { ($0.volume ?? 0) > 0 }
        case .macd:
            return indicatorPointCount >= 2
        case .rsi:
            return indicatorPointCount >= 15
        }
    }

    static func rangePerformance(
        snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket
    ) -> (change: Double, percent: Double)? {
        guard let latest = snapshot.latestPoint,
              let referencePrice = rangeReferencePrice(
                snapshot: snapshot,
                range: range,
                market: market
              ) else { return nil }
        guard referencePrice != 0 else { return nil }
        let change = latest.close - referencePrice
        return (change, change / referencePrice)
    }

    static func rangeReferencePrice(
        snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket
    ) -> Double? {
        guard let first = snapshot.points.first else { return nil }
        let history = snapshot.indicatorPoints ?? snapshot.points

        switch range {
        case .intraday:
            return intradayPreviousClose(
                snapshot: snapshot,
                market: market
            ) ?? first.close
        case .fiveDays:
            return closingPrice(
                beforeTradingDayContaining: first.date,
                in: history,
                market: market
            ) ?? first.close
        case .oneMonth, .threeMonths, .oneYear,
             .fiveYears, .tenYears, .sinceInception:
            return first.close
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
        let multiplier: CGFloat = isExpanded ? 1.4 : 1
        switch pointCount {
        case 0...40: return 7 * multiplier
        case 41...100: return 4 * multiplier
        default: return 2 * multiplier
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
        in snapshot: StockChartSnapshot
    ) -> [StockTechnicalPlotPoint] {
        let xValuesByDate = Dictionary(uniqueKeysWithValues: plotPoints.map {
            ($0.point.date, $0.x)
        })
        let indicators = StockTechnicalIndicators.calculate(
            snapshot.indicatorPoints ?? plotPoints.map(\.point)
        )
        return indicators.compactMap { indicator in
            guard let x = xValuesByDate[indicator.date] else { return nil }
            return StockTechnicalPlotPoint(indicator: indicator, x: x)
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
        range: StockChartRange
    ) -> [StockTransactionMarker] {
        let marketCalendar = calendar(for: stock.market)
        return stock.transactions.compactMap { transaction in
            guard transaction.quantity > 0,
                  transaction.unitPrice > 0,
                  let transactionDate = marketDate(
                    for: transaction.tradedAt,
                    market: stock.market
                  ) else { return nil }

            let matchingPoints = snapshot.points.filter { point in
                if range == .fiveYears || range == .tenYears {
                    return marketCalendar.dateInterval(of: .weekOfYear, for: point.date)?
                        .contains(transactionDate) == true
                }
                if range == .sinceInception {
                    return marketCalendar.dateInterval(of: .month, for: point.date)?
                        .contains(transactionDate) == true
                }
                return marketCalendar.isDate(point.date, inSameDayAs: transactionDate)
            }
            guard !matchingPoints.isEmpty else { return nil }
            let markerPoint: StockChartPoint
            if range == .intraday || range == .fiveDays {
                markerPoint = matchingPoints[matchingPoints.count / 2]
            } else {
                markerPoint = matchingPoints.last ?? matchingPoints[0]
            }
            guard let markerIndex = snapshot.points.firstIndex(where: {
                $0.id == markerPoint.id
            }) else { return nil }
            return StockTransactionMarker(
                id: transaction.id,
                date: markerPoint.date,
                plotX: xValue(
                    for: markerPoint,
                    index: markerIndex + (range == .intraday ? snapshot.preMarketPoints.count : 0),
                    range: range
                ),
                plotPrice: markerPoint.close,
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

    private static func yDomain(
        snapshot: StockChartSnapshot,
        displayModes: Set<StockChartDisplayMode>,
        technicalPlotPoints: [StockTechnicalPlotPoint]
    ) -> ClosedRange<Double> {
        if displayModes.contains(.rsi) { return 0...100 }
        if displayModes.contains(.volume) {
            var volumePoints = snapshot.points
            if displayModes.contains(.postMarket) { volumePoints += snapshot.postMarketPoints }
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
        if displayModes.contains(.line) { values += snapshot.points.map(\.close) }
        if displayModes.contains(.candlestick) {
            values += snapshot.points.flatMap { [$0.low, $0.high] }
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
            values += snapshot.preMarketPoints.map(\.close)
        }
        if displayModes.contains(.postMarket) {
            values += snapshot.postMarketPoints.map(\.close)
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
