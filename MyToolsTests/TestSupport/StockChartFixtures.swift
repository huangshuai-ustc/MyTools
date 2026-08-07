import Foundation
@testable import MyTools

enum StockChartFixtures {
    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0,
        timeZone: String = "Asia/Shanghai"
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    static func point(
        at date: Date,
        open: Double = 10,
        high: Double = 12,
        low: Double = 9,
        close: Double = 11,
        volume: Double? = 100
    ) -> StockChartPoint {
        StockChartPoint(
            date: date,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volume
        )
    }
}
