#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockMarketSession: String, Sendable {
    case preMarket
    case regular
    case postMarket
    case closed
}

enum StockMarketTradingCalendar {
    /// 内置休市表之外的零散休市日，用于还没抓到 `AShareHolidayService` 数据的年份。
    /// 数据到位后这里的条目只是多一层保险：两张表都只说「这天休市」，取并集即可。
    private static let additionalAShareClosures: [Int: Set<Int>] = [
        2025: [602, 1008],
        2026: [102, 406]
    ]

    /// Minute ranges use half-open intervals because provider timestamps mark
    /// the start of each minute bar. Chart filtering and live-session checks
    /// should therefore share these ranges.
    static func regularMinuteRanges(
        for market: StockMarket
    ) -> [(start: Int, end: Int)] {
        switch market {
        case .aShare: return [(570, 690), (780, 900)]
        case .hongKong: return [(570, 720), (780, 960)]
        case .unitedStates: return [(570, 960)]
        }
    }

    /// 给分时 bar 分档用的区间，比 `regularMinuteRanges` 多收盘那一分钟。
    ///
    /// 数据源会把「某一分钟的成交」标成这一分钟的结束时刻，收盘集合竞价因此正好落在
    /// 收盘时刻本身（东方财富 A 股 15:00、港股 16:00 那根 bar 就是定盘价），而
    /// `regularMinuteRanges` 右开，按它过滤会把这根 bar 丢掉：分时图末点停在 14:59 /
    /// 15:59，于是「当期数据」的收盘价、分时的今日涨跌、持仓总价值走势的末点全都和报价
    /// 里的收盘价对不上（03033 差 0.004，600519 能差 3.78）。午休前那根（A 股 11:30、
    /// 港股 12:00）同理，也是上半场的最后一分钟。
    ///
    /// 美股不能这样放宽：16:00 起就是盘后时段（`postMarketMinuteRange`），那一分钟必须
    /// 留给盘后，否则同一根 bar 会既算盘中又算盘后。因此只对没有盘后时段的市场生效。
    static func regularChartMinuteRanges(
        for market: StockMarket
    ) -> [(start: Int, end: Int)] {
        let ranges = regularMinuteRanges(for: market)
        guard postMarketMinuteRange(for: market) == nil else { return ranges }
        return ranges.map { (start: $0.start, end: $0.end + 1) }
    }

    static func preMarketMinuteRange(for market: StockMarket) -> (start: Int, end: Int)? {
        market == .unitedStates ? (240, 570) : nil
    }

    static func postMarketMinuteRange(for market: StockMarket) -> (start: Int, end: Int)? {
        market == .unitedStates ? (960, 1200) : nil
    }

    static func containsMinute(
        _ minute: Int,
        in ranges: [(start: Int, end: Int)]
    ) -> Bool {
        ranges.contains { minute >= $0.start && minute < $0.end }
    }

    static func isOpen(
        _ market: StockMarket,
        at date: Date = Date(),
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Bool {
        let rules = rules(for: market, snapshot: snapshot)
        return isActive(at: date, in: rules.regularRanges, rules: rules)
    }

    /// Whether a market is currently publishing an active session, including
    /// pre-market/auction data where the provider supports it.
    static func isSessionActive(
        _ market: StockMarket,
        at date: Date = Date(),
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Bool {
        session(for: market, at: date, snapshot: snapshot) != .closed
    }

    /// 当前所处时段。三个候选区间共用同一份规则，所以市场时区的 `Calendar` 和
    /// 交易日判定各只算一次——这是全模块最热的日历入口（刷新协调、图表分档、
    /// 行内报价都走它）。
    static func session(
        for market: StockMarket,
        at date: Date = Date(),
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> StockMarketSession {
        let rules = rules(for: market, snapshot: snapshot)
        if isActive(at: date, in: rules.regularRanges, rules: rules) { return .regular }
        if let range = rules.preMarketRange, isActive(at: date, in: [range], rules: rules) {
            return .preMarket
        }
        if let range = rules.postMarketRange, isActive(at: date, in: [range], rules: rules) {
            return .postMarket
        }
        return .closed
    }

    /// 只有美股有盘前/盘后区间，A 股与港股的 `preMarketRange`/`postMarketRange`
    /// 为 nil，于是这两个入口自然为假，不需要按市场写分支。
    static func isPreMarketOpen(
        _ market: StockMarket,
        at date: Date = Date(),
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Bool {
        let rules = rules(for: market, snapshot: snapshot)
        guard let range = rules.preMarketRange else { return false }
        return isActive(at: date, in: [range], rules: rules)
    }

    static func isPostMarketOpen(
        _ market: StockMarket,
        at date: Date = Date(),
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Bool {
        let rules = rules(for: market, snapshot: snapshot)
        guard let range = rules.postMarketRange else { return false }
        return isActive(at: date, in: [range], rules: rules)
    }

    /// Returns whether the date is a weekday on which this market has a session.
    /// This deliberately does not require the current time to be inside a session.
    static func isTradingDay(
        _ market: StockMarket,
        on date: Date,
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Bool {
        let rules = rules(for: market, snapshot: snapshot)
        return rules.isTradingDay(date, rules.calendar)
    }

    /// Returns the market-local start of the trading day immediately before
    /// `date`. Weekend and market holidays are skipped, but a missing quote or
    /// chart bar is not: callers can therefore detect a gap instead of silently
    /// treating an older close as the previous session's close.
    static func previousTradingDay(
        for market: StockMarket,
        before date: Date,
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Date? {
        let rules = rules(for: market, snapshot: snapshot)
        let calendar = rules.calendar
        let containingDay = calendar.startOfDay(for: date)
        guard var currentDay = calendar.date(
            byAdding: .day,
            value: -1,
            to: containingDay
        ) else { return nil }

        for _ in 0..<370 {
            if rules.isTradingDay(currentDay, calendar) {
                return calendar.startOfDay(for: currentDay)
            }
            guard let previousDay = calendar.date(
                byAdding: .day,
                value: -1,
                to: currentDay
            ) else { break }
            currentDay = previousDay
        }
        return nil
    }

    /// Returns true only when a market's final session (not a lunch break) ended
    static func finalSessionEnded(
        for market: StockMarket,
        between startDate: Date,
        and endDate: Date,
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Bool {
        let rules = rules(for: market, snapshot: snapshot)
        guard let finalRange = rules.regularRanges.last else { return false }
        return didAnySessionEnd(
            in: [finalRange],
            rules: rules,
            between: startDate,
            and: endDate
        )
    }

    /// 任意一个常规时段（含 A 股/港股午休前那半场）在区间内收盘。
    static func sessionEnded(
        for market: StockMarket,
        between startDate: Date,
        and endDate: Date,
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Bool {
        let rules = rules(for: market, snapshot: snapshot)
        return didAnySessionEnd(
            in: rules.regularRanges,
            rules: rules,
            between: startDate,
            and: endDate
        )
    }

    /// Identifies the most recent completed trading day, so a refresh attempt
    /// can be de-duplicated by session rather than by an arbitrary time window.
    ///
    /// 收盘时刻取自 `regularRanges.last.end`，不再由调用方手写分钟数——原先
    /// A 股 900、港股/美股 960 分三处传参，改一处时段就得同步改三处。
    static func latestCompletedFinalSessionEnd(
        for market: StockMarket,
        at date: Date = Date(),
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Date? {
        let rules = rules(for: market, snapshot: snapshot)
        guard let finalMinute = rules.regularRanges.last?.end else { return nil }
        let calendar = rules.calendar
        var currentDay = calendar.startOfDay(for: date)

        for _ in 0..<370 {
            if rules.isTradingDay(currentDay, calendar),
               let sessionEnd = calendar.date(
                   byAdding: .minute,
                   value: finalMinute,
                   to: currentDay
               ),
               sessionEnd <= date {
                return sessionEnd
            }

            guard let previousDay = calendar.date(
                byAdding: .day,
                value: -1,
                to: currentDay
            ) else { break }
            currentDay = previousDay
        }
        return nil
    }

    // MARK: - 每个市场一份规则，每种算法只有一份实现

    /// 一个市场的交易日历规则：时区、时段区间，以及**这一天是否开市**。
    ///
    /// 关键在最后一项问的是「交易日」而不是「节假日」。上一版的通用算法收
    /// `holiday: (Date, Calendar) -> Bool`，而 A 股的开市与否还得查
    /// `AShareHolidayService` 联网抓来的休市表，闭包表达不了，于是每个算法都被
    /// 复制出一个 `aShare*` 版本（`isOpen` 里还内联了第三份）。更糟的是「节假日」
    /// 和「非交易日」被当成同一件事——周末不是节假日，却同样不开市；调休补班日
    /// 被判成交易日正是这个混淆的产物。
    ///
    /// 现在市场差异全部收进这个结构，时段算法各只有一份实现。
    private struct Rules {
        let calendar: Calendar
        let regularRanges: [(start: Int, end: Int)]
        let preMarketRange: (start: Int, end: Int)?
        let postMarketRange: (start: Int, end: Int)?
        /// 这一天该市场是否开市。周末判定包含在内，没有市场能绕过它。
        let isTradingDay: (Date, Calendar) -> Bool
    }

    private static func rules(
        for market: StockMarket,
        snapshot: AShareHolidaySnapshot = AShareHolidayService.shared.snapshot
    ) -> Rules {
        Rules(
            calendar: calendar(for: market),
            regularRanges: regularMinuteRanges(for: market),
            preMarketRange: preMarketMinuteRange(for: market),
            postMarketRange: postMarketMinuteRange(for: market),
            isTradingDay: tradingDayPredicate(for: market, snapshot: snapshot)
        )
    }

    /// 每个市场「这一天是否开市」的判定。三者都以周一至周五为第一道闸，
    /// 差别只在休市日的来源。
    private static func tradingDayPredicate(
        for market: StockMarket,
        snapshot: AShareHolidaySnapshot
    ) -> (Date, Calendar) -> Bool {
        switch market {
        case .aShare:
            // 沪深交易所的交易日只有周一至周五里不休市的那些天。**调休补班日不交易**：
            // 国务院把某个周末调成上班日时，证券市场照旧休市。2025 年全部 5 个补班日
            // （01-26、02-08、04-27、09-28、10-11）在上证指数日 K 里都没有任何一根
            // 柱子，腾讯行情在这些天也不推新数据。所以 `AShareHolidayService` 只补
            // 「法定节假日落在周一至周五」这一半，它的补班标记在解析时就被丢弃——
            // 当成交易日会让页面一边显示「交易中」、一边永远刷不出新数据。
            //
            // snapshot 是引用类型，其内容只在 actor 内部发布前写入，因此这里的同步
            // 读取在任意线程都安全。
            return { date, calendar in
                isWeekday(date, calendar)
                    && !snapshot.isMandatedHoliday(for: date, calendar: calendar)
                    && !isAShareHoliday(date, calendar)
            }
        case .hongKong:
            return { date, calendar in
                isWeekday(date, calendar) && !isHongKongHoliday(date, calendar)
            }
        case .unitedStates:
            return { date, calendar in
                isWeekday(date, calendar) && !isUnitedStatesHoliday(date, calendar)
            }
        }
    }

    /// 周一至周五。`Calendar` 的 `weekday` 里 1 是周日、7 是周六。
    private static func isWeekday(_ date: Date, _ calendar: Calendar) -> Bool {
        (2...6).contains(calendar.component(.weekday, from: date))
    }

    /// `date` 是否落在给定的某个时段内。区间右开，理由见 `regularMinuteRanges`。
    private static func isActive(
        at date: Date,
        in ranges: [(start: Int, end: Int)],
        rules: Rules
    ) -> Bool {
        guard rules.isTradingDay(date, rules.calendar),
              let minute = localMinute(of: date, calendar: rules.calendar) else {
            return false
        }
        return containsMinute(minute, in: ranges)
    }

    private static func localMinute(of date: Date, calendar: Calendar) -> Int? {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return hour * 60 + minute
    }

    /// `ranges` 里是否有任意一个时段的收盘时刻落在 `(startDate, endDate]` 内。
    ///
    /// 左开右闭：收盘那一刻算「刚刚收过盘」，不算「上一次已经处理过」。
    /// `finalSessionEnded` 传最后一个时段（跳过午休），`sessionEnded` 传全部。
    private static func didAnySessionEnd(
        in ranges: [(start: Int, end: Int)],
        rules: Rules,
        between startDate: Date,
        and endDate: Date
    ) -> Bool {
        guard endDate > startDate, !ranges.isEmpty else { return false }
        let calendar = rules.calendar
        var currentDay = calendar.startOfDay(for: startDate)
        let finalDay = calendar.startOfDay(for: endDate)

        while currentDay <= finalDay {
            if rules.isTradingDay(currentDay, calendar) {
                for range in ranges {
                    guard let sessionEnd = calendar.date(
                        byAdding: .minute,
                        value: range.end,
                        to: currentDay
                    ) else { continue }
                    if sessionEnd > startDate, sessionEnd <= endDate {
                        return true
                    }
                }
            }

            guard let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: currentDay
            ) else { break }
            currentDay = nextDay
        }
        return false
    }

    /// 市场时区的公历。时区映射只有 `StockChartSeriesProcessor.marketTimeZone`
    /// 一份，本文件不再重复硬编码时区字符串。
    private static func calendar(for market: StockMarket) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockChartSeriesProcessor.marketTimeZone(market)
        return calendar
    }

    private static func isAShareHoliday(_ date: Date, _ calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return true }

        if additionalAShareClosures[year]?.contains(month * 100 + day) == true {
            return true
        }

        if month == 1, day == 1 {
            return true
        }
        if month == 5, (1...5).contains(day) {
            return true
        }
        if month == 10, (1...7).contains(day) {
            return true
        }
        if day == qingmingDay(in: year), month == 4 {
            return true
        }

        let lunar = lunarComponents(for: date, timeZone: calendar.timeZone)
        if lunar.month == 12, lunar.day >= 29 {
            return true
        }
        if lunar.month == 1, (1...7).contains(lunar.day) {
            return true
        }
        if lunar.month == 5, lunar.day == 5 {
            return true
        }
        if lunar.month == 8, lunar.day == 15 {
            return true
        }
        return false
    }

    private static func isHongKongHoliday(_ date: Date, _ calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return true }

        for fixedDate in [(1, 1), (5, 1), (7, 1), (10, 1), (12, 25), (12, 26)] {
            if isObservedFixedHoliday(
                date,
                month: fixedDate.0,
                day: fixedDate.1,
                calendar: calendar
            ) {
                return true
            }
        }
        if day == qingmingDay(in: year), month == 4 {
            return true
        }
        let lunar = lunarComponents(for: date, timeZone: calendar.timeZone)
        if lunar.month == 1, (1...3).contains(lunar.day) {
            return true
        }
        if lunar.month == 4, lunar.day == 8 {
            return true
        }
        if lunar.month == 5, lunar.day == 5 {
            return true
        }
        if lunar.month == 8, lunar.day == 16 {
            return true
        }
        if lunar.month == 9, lunar.day == 9 {
            return true
        }

        guard let easter = easterSunday(year: year, calendar: calendar) else { return false }
        let goodFriday = calendar.date(byAdding: .day, value: -2, to: easter)
        let easterMonday = calendar.date(byAdding: .day, value: 1, to: easter)
        return [goodFriday, easterMonday].contains {
            guard let holiday = $0 else { return false }
            return sameDay(date, holiday, calendar: calendar)
        }
    }

    private static func isUnitedStatesHoliday(_ date: Date, _ calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year else { return true }

        if isObservedFixedHoliday(date, month: 1, day: 1, calendar: calendar)
            || isObservedFixedHoliday(date, month: 6, day: 19, calendar: calendar)
            || isObservedFixedHoliday(date, month: 7, day: 4, calendar: calendar)
            || isObservedFixedHoliday(date, month: 12, day: 25, calendar: calendar) {
            return true
        }
        if isNthWeekday(date, month: 1, weekday: 2, occurrence: 3, calendar: calendar)
            || isNthWeekday(date, month: 2, weekday: 2, occurrence: 3, calendar: calendar)
            || isNthWeekday(date, month: 9, weekday: 2, occurrence: 1, calendar: calendar)
            || isLastWeekday(date, month: 5, weekday: 2, calendar: calendar)
            || isNthWeekday(date, month: 11, weekday: 5, occurrence: 4, calendar: calendar) {
            return true
        }

        guard let easter = easterSunday(year: year, calendar: calendar),
              let goodFriday = calendar.date(byAdding: .day, value: -2, to: easter) else {
            return false
        }
        return sameDay(date, goodFriday, calendar: calendar)
    }

    private static func lunarComponents(
        for date: Date,
        timeZone: TimeZone
    ) -> (month: Int, day: Int) {
        var calendar = Calendar(identifier: .chinese)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.month, .day], from: date)
        return (components.month ?? 0, components.day ?? 0)
    }

    private static func qingmingDay(in year: Int) -> Int {
        let shortYear = year % 100
        return Int(floor(Double(shortYear) * 0.2422 + 4.81)) - shortYear / 4
    }

    private static func isObservedFixedHoliday(
        _ date: Date,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Bool {
        let year = calendar.component(.year, from: date)
        for candidateYear in (year - 1)...(year + 1) {
            guard let holiday = makeDate(
                year: candidateYear,
                month: month,
                day: day,
                calendar: calendar
            ) else { continue }
            let weekday = calendar.component(.weekday, from: holiday)
            let offset: Int
            switch weekday {
            case 7: offset = -1
            case 1: offset = 1
            default: offset = 0
            }
            guard let observed = calendar.date(byAdding: .day, value: offset, to: holiday) else { continue }
            if sameDay(date, observed, calendar: calendar) { return true }
        }
        return false
    }

    private static func isNthWeekday(
        _ date: Date,
        month: Int,
        weekday: Int,
        occurrence: Int,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.month == month,
              let year = components.year,
              let first = makeDate(year: year, month: month, day: 1, calendar: calendar) else {
            return false
        }
        let firstWeekday = calendar.component(.weekday, from: first)
        let offset = (weekday - firstWeekday + 7) % 7
        let targetDay = 1 + offset + (occurrence - 1) * 7
        return components.day == targetDay
    }

    private static func isLastWeekday(
        _ date: Date,
        month: Int,
        weekday: Int,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.month == month,
              let year = components.year,
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return false
        }
        // Walk backwards from the last day of the month to find the last
        // occurrence of the target weekday (e.g. last Monday of May).
        for day in stride(from: range.count, through: max(1, range.count - 6), by: -1) {
            guard let candidate = makeDate(year: year, month: month, day: day, calendar: calendar) else { continue }
            if calendar.component(.weekday, from: candidate) == weekday {
                return components.day == day
            }
        }
        return false
    }

    private static func easterSunday(year: Int, calendar: Calendar) -> Date? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return makeDate(year: year, month: month, day: day, calendar: calendar)
    }

    private static func makeDate(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Date? {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }

    private static func sameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

#endif
