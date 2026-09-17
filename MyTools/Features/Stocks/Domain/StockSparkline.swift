#if MYTOOLS_FEATURE_STOCKS
import Foundation

/// 迷你图的横坐标域：当前时段当天的全部交易分钟。
///
/// x 用「累计在盘分钟」而不是墙钟分钟，A 股午休因此不会在图里留出空档；域长固定
/// 为整个时段，所以刚开盘时折线只占左侧一小段，随时间从左往右生长。
struct StockSparklineDomain: Equatable, Sendable {
    struct MinuteRange: Equatable, Sendable {
        let start: Int
        let end: Int

        var length: Int { max(end - start, 0) }
    }

    let market: StockMarket
    let ranges: [MinuteRange]

    var totalMinutes: Int { ranges.reduce(0) { $0 + $1.length } }

    /// 与 `StockSparklineSeries.resolve` 选序列的规则保持一致：盘前只有盘前区间，
    /// 盘后在当日盘中之后接上盘后区间，其余时段只有盘中区间。
    static func make(market: StockMarket, session: StockMarketSession) -> StockSparklineDomain {
        let regular = StockMarketTradingCalendar.regularMinuteRanges(for: market)
            .map { MinuteRange(start: $0.start, end: $0.end) }
        switch session {
        case .preMarket:
            guard let range = StockMarketTradingCalendar.preMarketMinuteRange(for: market) else {
                return StockSparklineDomain(market: market, ranges: regular)
            }
            return StockSparklineDomain(
                market: market,
                ranges: [MinuteRange(start: range.start, end: range.end)]
            )
        case .postMarket:
            guard let range = StockMarketTradingCalendar.postMarketMinuteRange(for: market) else {
                return StockSparklineDomain(market: market, ranges: regular)
            }
            return StockSparklineDomain(
                market: market,
                ranges: regular + [MinuteRange(start: range.start, end: range.end)]
            )
        case .regular, .closed:
            return StockSparklineDomain(market: market, ranges: regular)
        }
    }

    /// 归一化横坐标（0...1）。域为空时返回 nil，调用方回退到等距排布。
    func offset(for date: Date) -> Double? {
        let total = totalMinutes
        guard total > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockChartSeriesProcessor.marketTimeZone(market)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        let minuteOfDay = hour * 60 + minute
        var elapsed = 0
        for range in ranges {
            guard minuteOfDay >= range.start else { break }
            elapsed += min(minuteOfDay - range.start, range.length)
        }
        return min(max(Double(elapsed) / Double(total), 0), 1)
    }
}

/// 迷你图的时段解析结果：画哪一段、以及配套的横坐标域。
///
/// 两者必须来自同一次判定，否则会画出「盘前的横坐标 + 昨天的盘中折线」这种错位。
/// 零轴不在这里：它由行内报价直接给出（`StockWatchlistRow.sparklineBaseline`），
/// 这样虚线与色块、涨跌文案永远同一个基准。
struct StockSparklineSelection: Equatable, Sendable {
    let points: [StockChartPoint]
    let domain: StockSparklineDomain
}

/// A downsampled intraday close series prepared for the inline sparkline drawn
/// in the watchlist. This is transient quote presentation data derived from the
/// chart cache, so it is never persisted with the holding itself — the same
/// contract `StockExtendedHoursPerformance` follows.
///
/// Values are `Double` because the only consumer is `Canvas` drawing. Money and
/// share math stays on `Decimal` elsewhere.
struct StockSparklineSeries: Equatable, Sendable {
    /// Chronological close prices, already reduced to at most `maxPoints`.
    let values: [Double]
    /// 与 `values` 一一对应的归一化横坐标（0...1）。有 `StockSparklineDomain` 时按
    /// 当日时段的真实进度排布，没有域时退化为等距。
    let offsets: [Double]

    var lowest: Double { values.min() ?? 0 }
    var highest: Double { values.max() ?? 0 }

    /// Builds a series from cached chart points.
    ///
    /// Returns nil for an empty input so callers can render an equal-height
    /// placeholder instead of an empty frame that would collapse the row.
    static func make(
        points: [StockChartPoint],
        domain: StockSparklineDomain? = nil,
        maxPoints: Int = 40
    ) -> StockSparklineSeries? {
        guard !points.isEmpty, maxPoints > 0 else { return nil }
        let sampled = sampleIndices(count: points.count, maxPoints: maxPoints).map { points[$0] }
        let offsets = sampled.enumerated().map { index, point in
            domain?.offset(for: point.date) ?? evenOffset(index, count: sampled.count)
        }
        return StockSparklineSeries(values: sampled.map(\.close), offsets: offsets)
    }

    private static func evenOffset(_ index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return Double(index) / Double(count - 1)
    }

    /// Picks the cached points that belong to the session the row is currently
    /// showing, together with the x-axis domain that belongs to the same
    /// decision.
    ///
    /// 唯一规则：**画行内报价所属的那个时段**。`StockActiveQuote` 只有在缓存里存在
    /// 「当天」的盘前/盘后数据时才显示扩展时段报价（`StockChartPresentation` 的派生
    /// 值同样按当天校验），否则回退到常规报价，所以这里逐条对齐那套回退：
    ///
    /// - 盘前有当天数据 → 画当天盘前，用盘前横坐标域。没有当天数据时行内显示的是
    ///   常规报价（上一个已收盘交易日的收盘价），因此改画那一段完整时段，而不是留空。
    /// - 盘后把当天盘后接在当天盘中之后，与 `postMarketPerformance` 度量的正是同一对
    ///   数据；缺任一半都退回当天盘中。
    /// - 盘中只画当天盘中：旁边的价格是实时的，换成别的交易日必然自相矛盾，缺数据
    ///   就留空。
    /// - 休市画最近一个已结算时段，此时行内价格也正是那一段的收盘。
    ///
    /// 「已结算时段」只接受当天或本市场最近一个已收盘交易日（`acceptsSettledDay`）。
    /// 否则一份好几天没刷成功的缓存会配上一个刚刷新的报价——绿色跌幅配一条上涨折线
    /// 就是这样来的。A 股午休落在 `.closed`，那时最近交易日就是当天，上半场不会消失。
    static func resolve(
        regular: [StockChartPoint],
        preMarket: [StockChartPoint],
        postMarket: [StockChartPoint],
        market: StockMarket,
        at now: Date = Date()
    ) -> StockSparklineSelection {
        let calendar = StockChartSeriesProcessor.marketCalendar(market)
        func today(_ points: [StockChartPoint]) -> [StockChartPoint] {
            points.filter { calendar.isDate($0.date, inSameDayAs: now) }
        }
        func onRegularAxis(_ points: [StockChartPoint]) -> StockSparklineSelection {
            StockSparklineSelection(
                points: points,
                domain: .make(market: market, session: .regular)
            )
        }
        // 行内报价回退到常规报价时画的那一段：缓存里最近的交易日，且必须是当天或本
        // 市场最近一个已收盘的交易日。
        func settledSession() -> StockSparklineSelection {
            let points = StockChartSeriesProcessor.pointsOnLatestTradingDay(
                regular,
                market: market,
                at: now
            )
            guard let day = points.first?.date,
                  acceptsSettledDay(day, market: market, at: now) else {
                return onRegularAxis([])
            }
            return onRegularAxis(points)
        }
        switch StockMarketTradingCalendar.session(for: market, at: now) {
        case .preMarket:
            let preMarketToday = today(preMarket)
            guard !preMarketToday.isEmpty else { return settledSession() }
            return StockSparklineSelection(
                points: preMarketToday,
                domain: .make(market: market, session: .preMarket)
            )
        case .postMarket:
            let regularToday = today(regular)
            let postMarketToday = today(postMarket)
            // 盘后的零轴是当天盘中的收盘价，缺任一半时行内也拿不到盘后涨跌，一起退回
            // 当天盘中。
            guard !postMarketToday.isEmpty, !regularToday.isEmpty else {
                return onRegularAxis(regularToday)
            }
            return StockSparklineSelection(
                points: (regularToday + postMarketToday).sorted { $0.date < $1.date },
                domain: .make(market: market, session: .postMarket)
            )
        case .regular:
            return onRegularAxis(today(regular))
        case .closed:
            return settledSession()
        }
    }

    /// 可以整段回看的交易日：当天，或本市场最近一个已收盘交易日。
    static func acceptsSettledDay(
        _ day: Date,
        market: StockMarket,
        at now: Date
    ) -> Bool {
        let calendar = StockChartSeriesProcessor.marketCalendar(market)
        if calendar.isDate(day, inSameDayAs: now) { return true }
        guard let settled = StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
            for: market,
            at: now
        ) else { return false }
        return calendar.isDate(day, inSameDayAs: settled)
    }

    /// Evenly spaced sampling that always keeps the first and last point, so the
    /// rendered start and end match the real session open and latest print.
    static func sampleIndices(count: Int, maxPoints: Int) -> [Int] {
        guard count > 0, maxPoints > 0 else { return [] }
        guard count > maxPoints else { return Array(0..<count) }
        guard maxPoints > 1 else { return [count - 1] }
        let lastIndex = count - 1
        let steps = maxPoints - 1
        return (0...steps).map { step in
            let position = Double(step) / Double(steps) * Double(lastIndex)
            return min(lastIndex, Int(position.rounded()))
        }
    }
}

#endif
