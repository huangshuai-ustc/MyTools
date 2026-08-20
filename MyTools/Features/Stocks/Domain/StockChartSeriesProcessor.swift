#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockChartSeriesKind: String, Codable, Sendable {
    case intraday
    case fiveDayMinute
    case daily
    case weekly
    case monthly
}

enum StockChartSeriesProcessor {
    static func seriesKind(for range: StockChartRange) -> StockChartSeriesKind {
        switch range {
        case .intraday: return .intraday
        case .fiveDays: return .fiveDayMinute
        case .oneMonth, .threeMonths, .oneYear: return .daily
        case .fiveYears, .tenYears: return .weekly
        case .sinceInception: return .monthly
        }
    }

    static func compatibleMetadataRanges(for range: StockChartRange) -> [StockChartRange] {
        switch range {
        case .intraday: return [.intraday]
        case .fiveDays: return [.fiveDays]
        case .oneMonth: return [.oneMonth, .threeMonths, .oneYear]
        case .threeMonths: return [.threeMonths, .oneYear]
        case .oneYear: return [.oneYear]
        case .fiveYears: return [.fiveYears, .tenYears]
        case .tenYears: return [.tenYears]
        case .sinceInception: return [.sinceInception]
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
        guard let latest = sortedPoints.last else { return [] }
        let calendar = marketCalendar(market)

        switch range {
        case .intraday:
            return pointsOnLatestTradingDay(sortedPoints, market: market, at: now)
        case .fiveDays:
            return pointsOnLatestTradingDays(sortedPoints, count: 5, market: market, at: now)
        case .oneMonth:
            return points(
                sortedPoints,
                since: clampedStartDate(
                    calendar.date(byAdding: .month, value: -1, to: latest.date),
                    to: inceptionDate
                )
            )
        case .threeMonths:
            return points(
                sortedPoints,
                since: clampedStartDate(
                    calendar.date(byAdding: .month, value: -3, to: latest.date),
                    to: inceptionDate
                )
            )
        case .oneYear:
            return points(
                sortedPoints,
                since: clampedStartDate(
                    calendar.date(byAdding: .year, value: -1, to: latest.date),
                    to: inceptionDate
                )
            )
        case .fiveYears:
            return points(
                sortedPoints,
                since: clampedStartDate(
                    calendar.date(byAdding: .year, value: -5, to: latest.date),
                    to: inceptionDate
                )
            )
        case .tenYears:
            return points(
                sortedPoints,
                since: clampedStartDate(
                    calendar.date(byAdding: .year, value: -10, to: latest.date),
                    to: inceptionDate
                )
            )
        case .sinceInception:
            return points(sortedPoints, since: inceptionDate)
        }
    }

    /// Returns the earliest reliable history boundary available in the store.
    /// The monthly series is requested as the inception range, while weekly
    /// history may contain stale predecessor/ticker data and is therefore not
    /// used to infer a listing date.
    static func inceptionDate(
        in series: [String: [StockChartPoint]]
    ) -> Date? {
        let preferredKinds: [StockChartSeriesKind] = [
            .monthly,
            .daily,
            .fiveDayMinute,
            .intraday
        ]
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
        guard range != .sinceInception,
              let firstVisibleDate = visiblePoints.first?.date,
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
        let resampledSeries: [StockChartPoint]
        if range == .intraday {
            resampledSeries = resampledIntradayPoints(
                rawPoints.sorted { $0.date < $1.date },
                targetMinutes: 3
            )
        } else {
            resampledSeries = rawPoints.sorted { $0.date < $1.date }
        }
        let completeSeries = pointsThroughLatestTradingDay(
            resampledSeries,
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
            visible = pointsThroughLatestTradingDay(
                snapshot.points,
                market: market,
                at: now
            )
            indicatorPoints = snapshot.indicatorPoints.map {
                pointsThroughLatestTradingDay($0, market: market, at: now)
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

    /// Aggregates the latest completed/current regular session for the "当期数据" panel.
    /// Minute chart points are individual bars, so using the last bar directly would
    /// incorrectly show that bar's open/high/low and often a zero volume.
    static func currentSessionSummary(
        from points: [StockChartPoint],
        market: StockMarket,
        at now: Date = Date()
    ) -> StockChartSessionSummary? {
        let regularPoints = regularSessionPoints(points, market: market)
        // Daily/weekly providers timestamp bars at the calendar boundary, so
        // they do not pass the intraday session filter. Keep those bars usable
        // when the user switches the watch view away from a minute range.
        let sessionCandidates = regularPoints.isEmpty ? points : regularPoints
        let sessionPoints = pointsOnLatestTradingDay(
            sessionCandidates,
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
        let calendar = marketCalendar(market)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else {
                return false
            }
            let localMinutes = hour * 60 + minute
            switch market {
            case .aShare:
                return (555..<570).contains(localMinutes)
            case .hongKong:
                return false
            case .unitedStates:
                return (240..<570).contains(localMinutes)
            }
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
        let calendar = marketCalendar(market)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else {
                return false
            }
            let localMinutes = hour * 60 + minute
            switch market {
            case .aShare:
                return (900...903).contains(localMinutes) && localMinutes > 900
            case .hongKong:
                return false
            case .unitedStates:
                return (960...1200).contains(localMinutes) && localMinutes > 960
            }
        }
    }

    static func minimumPointCount(for range: StockChartRange) -> Int {
        switch range {
        case .intraday: return 1
        case .fiveDays: return 20
        case .oneMonth: return 6
        case .threeMonths: return 15
        case .oneYear: return 30
        case .fiveYears, .tenYears, .sinceInception: return 2
        }
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
        let groups = Dictionary(grouping: points) { point in
            calendar.dateInterval(of: .weekOfYear, for: point.date)?.start
                ?? calendar.startOfDay(for: point.date)
        }
        return groups.keys.sorted().compactMap { weekStart in
            guard let group = groups[weekStart]?.sorted(by: { $0.date < $1.date }),
                  let first = group.first,
                  let last = group.last else { return nil }
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

    static func resampledIntradayPoints(
        _ points: [StockChartPoint],
        targetMinutes: Int
    ) -> [StockChartPoint] {
        guard targetMinutes > 1 else { return points.sorted { $0.date < $1.date } }
        let interval = TimeInterval(targetMinutes * 60)
        let groups = Dictionary(grouping: points) { point in
            Int(point.date.timeIntervalSince1970 / interval)
        }
        return groups.keys.sorted().compactMap { bucket in
            guard let group = groups[bucket]?.sorted(by: { $0.date < $1.date }),
                  let first = group.first,
                  let last = group.last else { return nil }
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
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -4, to: endDate) ?? endDate
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -6, to: endDate) ?? endDate
        case .oneYear:
            return calendar.date(byAdding: .month, value: -15, to: endDate) ?? endDate
        case .fiveYears:
            return calendar.date(byAdding: .month, value: -78, to: endDate) ?? endDate
        case .tenYears:
            return calendar.date(byAdding: .month, value: -138, to: endDate) ?? endDate
        case .sinceInception:
            return Date(timeIntervalSince1970: 0)
        }
    }

    static func marketCalendar(_ market: StockMarket) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone(market)
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

    private static func clampedStartDate(_ startDate: Date?, to boundary: Date?) -> Date? {
        guard let boundary else { return startDate }
        guard let startDate else { return boundary }
        return max(startDate, boundary)
    }

    private static func seriesBucket(
        for date: Date,
        kind: StockChartSeriesKind,
        calendar: Calendar
    ) -> Date {
        switch kind {
        case .intraday, .fiveDayMinute:
            return calendar.dateInterval(of: .minute, for: date)?.start ?? date
        case .daily:
            return calendar.startOfDay(for: date)
        case .weekly:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .monthly:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }
}

#endif
