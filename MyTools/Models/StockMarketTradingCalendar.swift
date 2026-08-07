import Foundation

enum StockMarketTradingCalendar {
    private static let additionalAShareClosures: [Int: Set<Int>] = [
        2025: [602, 1008],
        2026: [102, 406]
    ]

    static func isOpen(_ market: StockMarket, at date: Date = Date()) -> Bool {
        switch market {
        case .aShare:
            return isOpen(
                date,
                timeZone: "Asia/Shanghai",
                sessions: [(570, 690), (780, 900)],
                holiday: isAShareHoliday
            )
        case .hongKong:
            return isOpen(
                date,
                timeZone: "Asia/Hong_Kong",
                sessions: [(570, 720), (780, 960)],
                holiday: isHongKongHoliday
            )
        case .unitedStates:
            return isOpen(
                date,
                timeZone: "America/New_York",
                sessions: [(570, 960)],
                holiday: isUnitedStatesHoliday
            )
        }
    }

    static func sessionEnded(
        for market: StockMarket,
        between startDate: Date,
        and endDate: Date
    ) -> Bool {
        guard endDate > startDate else { return false }

        switch market {
        case .aShare:
            return sessionEnded(
                between: startDate,
                and: endDate,
                timeZone: "Asia/Shanghai",
                sessions: [(570, 690), (780, 900)],
                holiday: isAShareHoliday
            )
        case .hongKong:
            return sessionEnded(
                between: startDate,
                and: endDate,
                timeZone: "Asia/Hong_Kong",
                sessions: [(570, 720), (780, 960)],
                holiday: isHongKongHoliday
            )
        case .unitedStates:
            return sessionEnded(
                between: startDate,
                and: endDate,
                timeZone: "America/New_York",
                sessions: [(570, 960)],
                holiday: isUnitedStatesHoliday
            )
        }
    }

    private static func isOpen(
        _ date: Date,
        timeZone identifier: String,
        sessions: [(start: Int, end: Int)],
        holiday: (Date, Calendar) -> Bool
    ) -> Bool {
        let calendar = calendar(timeZone: identifier)
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              (2...6).contains(weekday),
              let hour = components.hour,
              let minute = components.minute else {
            return false
        }
        guard !holiday(date, calendar) else { return false }
        let localMinutes = hour * 60 + minute
        return sessions.contains { localMinutes >= $0.start && localMinutes < $0.end }
    }

    private static func sessionEnded(
        between startDate: Date,
        and endDate: Date,
        timeZone identifier: String,
        sessions: [(start: Int, end: Int)],
        holiday: (Date, Calendar) -> Bool
    ) -> Bool {
        let calendar = calendar(timeZone: identifier)
        var currentDay = calendar.startOfDay(for: startDate)
        let finalDay = calendar.startOfDay(for: endDate)

        while currentDay <= finalDay {
            let weekday = calendar.component(.weekday, from: currentDay)
            if (2...6).contains(weekday), !holiday(currentDay, calendar) {
                for session in sessions {
                    guard let sessionEnd = calendar.date(
                        byAdding: .minute,
                        value: session.end,
                        to: currentDay
                    ) else { continue }
                    if sessionEnd > startDate, sessionEnd <= endDate {
                        return true
                    }
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else {
                break
            }
            currentDay = nextDay
        }
        return false
    }

    private static func calendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
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
              let range = calendar.range(of: .day, in: .month, for: date),
              let last = makeDate(year: year, month: month, day: range.count, calendar: calendar) else {
            return false
        }
        return components.day == range.count && calendar.component(.weekday, from: last) == weekday
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
