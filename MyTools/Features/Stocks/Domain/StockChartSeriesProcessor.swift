#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockChartSeriesKind: String, Codable, Sendable {
    // `intraday` and `daily` are the only persisted raw source kinds.
    // The remaining kinds are used only as in-memory aggregation buckets.
    case intraday
    case fiveDayMinute
    case daily
    case weekly
    case monthly
    case quarterly
    case yearly
}

enum StockChartSeriesProcessor {
    static func seriesKind(for range: StockChartRange) -> StockChartSeriesKind {
        switch range {
        case .intraday, .fiveDays:
            // Both minute views share one raw intraday source. Five days is a
            // viewport over that source, not a separately persisted series.
            return .intraday
        case .dayK, .weekK, .monthK, .quarterK, .yearK:
            // Every K-line view shares the raw daily OHLCV source. Coarser
            // bars are generated only when the view is rendered.
            return .daily
        }
    }

    static func derivedSeriesKind(for range: StockChartRange) -> StockChartSeriesKind? {
        switch range {
        case .fiveDays: return .fiveDayMinute
        case .weekK: return .weekly
        case .monthK: return .monthly
        case .quarterK: return .quarterly
        case .yearK: return .yearly
        case .intraday, .dayK: return nil
        }
    }

    static func compatibleMetadataRanges(for range: StockChartRange) -> [StockChartRange] {
        switch range {
        case .intraday: return [.intraday]
        case .fiveDays: return [.fiveDays]
        case .dayK, .weekK, .monthK, .quarterK, .yearK:
            // Every K-line range is derived from the same complete daily
            // source, so one successful K-line fetch covers the other bar
            // granularities as well.
            return [.dayK, .weekK, .monthK, .quarterK, .yearK]
        }
    }

    static func visiblePoints(
        from storedPoints: [StockChartPoint],
        for range: StockChartRange,
        market: StockMarket,
        inceptionDate: Date? = nil,
        at now: Date = Date()
    ) -> [StockChartPoint] {
        let sortedPoints = pointsThroughLatestTradingDay(
            storedPoints,
            market: market,
            at: now
        )
        guard !sortedPoints.isEmpty else { return [] }
        switch range {
        case .intraday:
            return pointsOnLatestTradingDay(sortedPoints, market: market, at: now)
        case .fiveDays:
            return pointsOnLatestTradingDays(sortedPoints, count: 5, market: market, at: now)
        case .dayK, .weekK, .monthK, .quarterK, .yearK:
            // K-line tabs keep the complete fetched series. The presentation
            // layer chooses the recent default viewport and lets the user
            // pan/zoom across the remaining history.
            return points(sortedPoints, since: inceptionDate)
        }
    }

    /// Returns the earliest reliable history boundary available in the raw
    /// daily/minute source store.
    static func inceptionDate(
        in series: [String: [StockChartPoint]]
    ) -> Date? {
        let preferredKinds: [StockChartSeriesKind] = [.daily, .intraday]
        for kind in preferredKinds {
            if let firstDate = series[kind.rawValue]?.map(\.date).min() {
                return firstDate
            }
        }
        return nil
    }

    static func indicatorPoints(
        from storedPoints: [StockChartPoint],
        visiblePoints: [StockChartPoint],
        range: StockChartRange
    ) -> [StockChartPoint] {
        guard let firstVisibleDate = visiblePoints.first?.date,
              let lastVisibleDate = visiblePoints.last?.date else {
            return visiblePoints
        }

        let sortedPoints = storedPoints.sorted { $0.date < $1.date }
        guard let firstVisibleIndex = sortedPoints.firstIndex(where: {
            $0.date >= firstVisibleDate
        }),
        let lastVisibleIndex = sortedPoints.lastIndex(where: {
            $0.date <= lastVisibleDate
        }) else {
            return visiblePoints
        }

        let warmupStartIndex = max(0, firstVisibleIndex - 60)
        return Array(sortedPoints[warmupStartIndex...lastVisibleIndex])
    }

    static func preparedMinuteChartPoints(
        _ rawPoints: [StockChartPoint],
        range: StockChartRange,
        market: StockMarket,
        at now: Date = Date()
    ) -> (visible: [StockChartPoint], indicators: [StockChartPoint]) {
        // Preserve the provider's actual minute cadence. Only sub-minute
        // input is normalized to one-minute OHLCV; 3/5/15-minute bars remain
        // separate bars with their original timestamps.
        let resampledSeries = minuteNormalizedPoints(rawPoints, market: market)
        let sourceSeries = range == .fiveDays
            ? regularSessionPoints(resampledSeries, market: market)
            : resampledSeries
        let completeSeries = pointsThroughLatestTradingDay(
            sourceSeries,
            market: market,
            at: now
        )

        let visible: [StockChartPoint]
        if range == .intraday {
            visible = regularSessionPoints(
                pointsOnLatestTradingDay(completeSeries, market: market, at: now),
                market: market
            )
        } else {
            visible = pointsOnLatestTradingDays(
                completeSeries,
                count: 5,
                market: market,
                at: now
            )
        }
        return (visible, completeSeries)
    }

    static func normalizedSnapshot(
        _ snapshot: StockChartSnapshot,
        range: StockChartRange,
        market: StockMarket,
        at now: Date = Date()
    ) -> StockChartSnapshot? {
        let visible: [StockChartPoint]
        let indicatorPoints: [StockChartPoint]?

        if range == .intraday || range == .fiveDays {
            let prepared = preparedMinuteChartPoints(
                snapshot.indicatorPoints ?? snapshot.points,
                range: range,
                market: market,
                at: now
            )
            visible = prepared.visible
            indicatorPoints = prepared.indicators
        } else {
            let preparedPoints = preparedKLinePoints(
                snapshot.points,
                range: range,
                market: market
            )
            visible = pointsThroughLatestTradingDay(
                preparedPoints,
                market: market,
                at: now
            )
            indicatorPoints = snapshot.indicatorPoints.map {
                pointsThroughLatestTradingDay(
                    preparedKLinePoints($0, range: range, market: market),
                    market: market,
                    at: now
                )
            }
        }

        guard let latest = visible.last else { return nil }
        return StockChartSnapshot(
            symbol: snapshot.symbol,
            name: snapshot.name,
            currencyCode: snapshot.currencyCode,
            previousClose: snapshot.previousClose,
            points: visible,
            preMarketPoints: snapshot.preMarketPoints,
            postMarketPoints: snapshot.postMarketPoints,
            indicatorPoints: indicatorPoints,
            dailyIndicatorPoints: range.isKLineRange
                ? snapshot.points
                : snapshot.dailyIndicatorPoints,
            quoteUpdatedAt: latest.date,
            fetchedAt: snapshot.fetchedAt,
            source: snapshot.source,
            supportsCandlesticks: snapshot.supportsCandlesticks
        )
    }

    static func mergedPoints(
        _ existing: [StockChartPoint],
        with incoming: [StockChartPoint],
        kind: StockChartSeriesKind,
        market: StockMarket
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(market)
        var pointsByBucket: [Date: StockChartPoint] = [:]
        for point in existing {
            pointsByBucket[seriesBucket(for: point.date, kind: kind, calendar: calendar)] = point
        }
        for point in incoming {
            pointsByBucket[seriesBucket(for: point.date, kind: kind, calendar: calendar)] = point
        }
        return pointsByBucket.values.sorted { $0.date < $1.date }
    }

    static func regularUnitedStatesSessionPoints(
        _ points: [StockChartPoint]
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(.unitedStates)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else { return false }
            let localMinutes = hour * 60 + minute
            return localMinutes >= 570 && localMinutes <= 960
        }
    }

    static func regularSessionPoints(
        _ points: [StockChartPoint],
        market: StockMarket
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(market)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else {
                return false
            }
            let localMinutes = hour * 60 + minute
            switch market {
            case .aShare:
                return (570...690).contains(localMinutes)
                    || (780...900).contains(localMinutes)
            case .hongKong:
                return (570...720).contains(localMinutes)
                    || (780...960).contains(localMinutes)
            case .unitedStates:
                return (570...960).contains(localMinutes)
            }
        }
    }

    /// A non-regular session should still expose the last completed regular
    /// session. Providers can briefly return only the first few bars after a
    /// session boundary, so use the final regular-session timestamp as a
    /// completeness signal before accepting that response as the cache.
    static func hasCompletedRegularSession(
        _ points: [StockChartPoint],
        market: StockMarket
    ) -> Bool {
        guard let latest = points.max(by: { $0.date < $1.date }) else { return false }
        let calendar = marketCalendar(market)
        let components = calendar.dateComponents([.hour, .minute], from: latest.date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let localMinutes = hour * 60 + minute
        let expectedClose: Int
        switch market {
        case .aShare: expectedClose = 900
        case .hongKong, .unitedStates: expectedClose = 960
        }
        return localMinutes >= expectedClose - 15
    }

    /// Aggregates the latest completed/current regular session for the "当期数据" panel.
    /// The input must be minute-level points. K-line pages obtain a separate
    /// intraday snapshot before calling this method; a daily/weekly bar is not
    /// a substitute for the session's minute-level OHLCV.
    static func currentSessionSummary(
        from points: [StockChartPoint],
        market: StockMarket,
        at now: Date = Date()
    ) -> StockChartSessionSummary? {
        let regularPoints = regularSessionPoints(points, market: market)
        let sessionPoints = pointsOnLatestTradingDay(
            regularPoints,
            market: market,
            at: now
        ).sorted { $0.date < $1.date }
        guard let first = sessionPoints.first, let last = sessionPoints.last else {
            return nil
        }
        let volumes = sessionPoints.compactMap(\.volume)
        return StockChartSessionSummary(
            open: first.open,
            high: sessionPoints.map(\.high).max() ?? first.high,
            low: sessionPoints.map(\.low).min() ?? first.low,
            close: last.close,
            volume: volumes.isEmpty ? nil : volumes.reduce(0, +),
            date: last.date
        )
    }

    static func preMarketSessionPoints(
        _ points: [StockChartPoint],
        market: StockMarket
    ) -> [StockChartPoint] {
        guard market.supportsExtendedHoursChart else { return [] }
        let calendar = marketCalendar(market)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else {
                return false
            }
            let localMinutes = hour * 60 + minute
            return (240..<570).contains(localMinutes)
        }
    }

    static func preMarketUnitedStatesSessionPoints(
        _ points: [StockChartPoint]
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(.unitedStates)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else { return false }
            let localMinutes = hour * 60 + minute
            return localMinutes >= 240 && localMinutes < 570
        }
    }

    static func postMarketSessionPoints(
        _ points: [StockChartPoint],
        market: StockMarket
    ) -> [StockChartPoint] {
        guard market.supportsExtendedHoursChart else { return [] }
        let calendar = marketCalendar(market)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else {
                return false
            }
            let localMinutes = hour * 60 + minute
            return (960...1200).contains(localMinutes) && localMinutes > 960
        }
    }

    static func minimumPointCount(for range: StockChartRange) -> Int {
        switch range {
        case .intraday: return 1
        case .fiveDays: return 20
        case .dayK: return 20
        case .weekK: return 10
        case .monthK: return 6
        case .quarterK: return 4
        case .yearK: return 2
        }
    }

    /// Technical overlays on minute charts need enough prior bars and at
    /// least one completed day before the visible window. The cache/service
    /// layer uses this deterministic rule to decide whether a warm-up fetch is
    /// required; it does not affect which points are rendered.
    static func needsMinuteTechnicalWarmup(
        _ points: [StockChartPoint],
        market: StockMarket
    ) -> Bool {
        let sortedPoints = points.sorted { $0.date < $1.date }
        guard sortedPoints.count >= 60 else { return true }
        let calendar = marketCalendar(market)
        let tradingDays = Set(sortedPoints.map { calendar.startOfDay(for: $0.date) })
        return tradingDays.count < 2
    }

    static func hasRequiredCoverage(
        _ points: [StockChartPoint],
        for range: StockChartRange,
        market: StockMarket
    ) -> Bool {
        guard points.count >= minimumPointCount(for: range) else { return false }
        guard range == .fiveDays else { return true }

        let calendar = marketCalendar(market)
        let tradingDays = Set(points.map { calendar.startOfDay(for: $0.date) })
        return tradingDays.count == 5
    }

    static func weeklyPoints(
        from points: [StockChartPoint],
        calendar: Calendar
    ) -> [StockChartPoint] {
        aggregatePoints(points, kind: .weekly, calendar: calendar)
    }

    /// Normalizes only sub-minute input to one-minute OHLCV. If the provider
    /// returns 3/5/15-minute bars, their timestamps remain untouched and no
    /// artificial minute bars are created.
    private static func minuteNormalizedPoints(
        _ points: [StockChartPoint],
        market: StockMarket
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(market)
        let groups = Dictionary(grouping: points) { point in
            calendar.dateInterval(of: .minute, for: point.date)?.start ?? point.date
        }
        return groups.keys.sorted().compactMap { bucket in
            aggregateOHLCV(groups[bucket] ?? [])
        }
    }

    static func pointsOnLatestTradingDay(
        _ points: [StockChartPoint],
        market: StockMarket,
        at now: Date = Date()
    ) -> [StockChartPoint] {
        guard let latestDay = latestTradingDayStart(points, market: market, at: now) else {
            return []
        }
        let calendar = marketCalendar(market)
        return points.filter { calendar.isDate($0.date, inSameDayAs: latestDay) }
    }

    static func pointsOnLatestTradingDays(
        _ points: [StockChartPoint],
        count: Int,
        market: StockMarket,
        at now: Date = Date()
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(market)
        let days = points.reversed().reduce(into: [Date]()) { result, point in
            let day = calendar.startOfDay(for: point.date)
            guard result.count < count,
                  !result.contains(day),
                  StockMarketTradingCalendar.isTradingDay(market, on: day) else {
                return
            }
            let dayPoints = points.filter { calendar.isDate($0.date, inSameDayAs: day) }
            guard hasTradingEvidence(
                in: dayPoints,
                isCurrentOpenDay: calendar.isDate(day, inSameDayAs: now)
                    && StockMarketTradingCalendar.isOpen(market, at: now)
            ) else { return }
            result.append(day)
        }
        let retainedDays = Set(days)
        return points.filter { retainedDays.contains(calendar.startOfDay(for: $0.date)) }
    }

    private static func pointsThroughLatestTradingDay(
        _ points: [StockChartPoint],
        market: StockMarket,
        at now: Date
    ) -> [StockChartPoint] {
        let sortedPoints = points.sorted { $0.date < $1.date }
        guard let latestDay = latestTradingDayStart(sortedPoints, market: market, at: now),
              let lastIndex = sortedPoints.lastIndex(where: {
                  marketCalendar(market).isDate($0.date, inSameDayAs: latestDay)
              }) else {
            return []
        }
        return Array(sortedPoints[...lastIndex])
    }

    private static func latestTradingDayStart(
        _ points: [StockChartPoint],
        market: StockMarket,
        at now: Date
    ) -> Date? {
        let calendar = marketCalendar(market)
        var seenDays = Set<Date>()
        for point in points.sorted(by: { $0.date > $1.date }) {
            let day = calendar.startOfDay(for: point.date)
            guard seenDays.insert(day).inserted,
                  StockMarketTradingCalendar.isTradingDay(market, on: day) else {
                continue
            }
            let dayPoints = points.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let isCurrentOpenDay = calendar.isDate(day, inSameDayAs: now)
                && StockMarketTradingCalendar.isOpen(market, at: now)
            if hasTradingEvidence(in: dayPoints, isCurrentOpenDay: isCurrentOpenDay) {
                return day
            }
        }
        return nil
    }

    private static func hasTradingEvidence(
        in points: [StockChartPoint],
        isCurrentOpenDay: Bool
    ) -> Bool {
        guard !points.isEmpty else { return false }
        if isCurrentOpenDay { return true }
        return points.contains { point in
            (point.volume ?? 0) > 0
                || point.high > point.low
                || point.open != point.close
                || point.high != point.open
                || point.low != point.open
        }
    }

    static func historicalStartDate(
        for range: StockChartRange,
        endingAt endDate: Date,
        calendar: Calendar
    ) -> Date {
        switch range {
        case .intraday:
            return endDate
        case .fiveDays:
            return calendar.date(byAdding: .day, value: -12, to: endDate) ?? endDate
        case .dayK, .weekK, .monthK, .quarterK, .yearK:
            // All K-line tabs use the complete listing history. Providers
            // aggregate this source into their requested bar size below.
            return Date(timeIntervalSince1970: -2_208_988_800)
        }
    }

    static func marketCalendar(_ market: StockMarket) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(market)
        // Financial weekly bars use the ISO Monday-Sunday bucket. The
        // resulting OHLCV bar still contains only actual trading days.
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func marketTimeZone(_ market: StockMarket) -> TimeZone {
        let identifier: String
        switch market {
        case .aShare: identifier = "Asia/Shanghai"
        case .hongKong: identifier = "Asia/Hong_Kong"
        case .unitedStates: identifier = "America/New_York"
        }
        return TimeZone(identifier: identifier) ?? .gmt
    }

    private static func points(
        _ points: [StockChartPoint],
        since startDate: Date?
    ) -> [StockChartPoint] {
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    static func seriesBucket(
        for date: Date,
        kind: StockChartSeriesKind,
        calendar: Calendar
    ) -> Date {
        switch kind {
        case .intraday, .fiveDayMinute:
            return calendar.dateInterval(of: .minute, for: date)?.start ?? date
        case .daily:
            return dailyBucket(for: date, calendar: calendar)
        case .weekly:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .monthly:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .quarterly:
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { return date }
            let quarterMonth = ((month - 1) / 3) * 3 + 1
            return calendar.date(from: DateComponents(year: year, month: quarterMonth, day: 1))
                ?? calendar.startOfDay(for: date)
        case .yearly:
            let year = calendar.component(.year, from: date)
            return calendar.date(from: DateComponents(year: year, month: 1, day: 1))
                ?? calendar.startOfDay(for: date)
        }
    }

    /// Returns the calendar-day identity used by the raw daily cache. Keeping
    /// this separate from `seriesBucket` makes the cache merge explicit and
    /// prevents a provider timestamp from creating duplicate daily bars.
    static func dailyBucket(
        for date: Date,
        calendar: Calendar
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func preparedKLinePoints(
        _ points: [StockChartPoint],
        range: StockChartRange,
        market: StockMarket
    ) -> [StockChartPoint] {
        let calendar = marketCalendar(market)
        switch range {
        case .weekK:
            return weeklyPoints(from: points, calendar: calendar)
        case .monthK:
            return monthlyPoints(from: points, calendar: calendar)
        case .quarterK:
            return aggregatePoints(
                points,
                kind: .quarterly,
                calendar: calendar
            )
        case .yearK:
            return aggregatePoints(
                points,
                kind: .yearly,
                calendar: calendar
            )
        default:
            return points.sorted { $0.date < $1.date }
        }
    }

    static func monthlyPoints(
        from points: [StockChartPoint],
        calendar: Calendar
    ) -> [StockChartPoint] {
        aggregatePoints(points, kind: .monthly, calendar: calendar)
    }

    private static func aggregatePoints(
        _ points: [StockChartPoint],
        kind: StockChartSeriesKind,
        calendar: Calendar
    ) -> [StockChartPoint] {
        // Standard OHLCV resampling: open=first, high=max, low=min,
        // close=last, volume=sum within each exchange-calendar bucket.
        let groups = Dictionary(grouping: points) {
            seriesBucket(for: $0.date, kind: kind, calendar: calendar)
        }
        return groups.keys.sorted().compactMap { bucket in
            aggregateOHLCV(groups[bucket] ?? [])
        }
    }

    private static func aggregateOHLCV(
        _ points: [StockChartPoint]
    ) -> StockChartPoint? {
        let group = points.sorted { $0.date < $1.date }
        guard let first = group.first, let last = group.last else { return nil }
        let volumes = group.compactMap(\.volume)
        return StockChartPoint(
            date: last.date,
            open: first.open,
            high: group.map(\.high).max() ?? last.high,
            low: group.map(\.low).min() ?? last.low,
            close: last.close,
            volume: volumes.isEmpty ? nil : volumes.reduce(0, +)
        )
    }

}

#endif
