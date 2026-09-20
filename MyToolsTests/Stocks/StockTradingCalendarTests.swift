import Foundation
import Testing
@testable import MyTools

/// A 股交易日与时段判定。核心是一条容易搞反的规则：**调休补班日证券市场不交易**。
///
/// holiday-cn 的数据把这类日子标成「工作日」（`isOffDay == false`），照字面理解
/// 就会把调休的周日判成开市——页面顶部显示「交易中」，可是行情源那天根本不发
/// 数据，于是一边显示开盘中一边永远刷不出新报价。2025 年全部 5 个补班日
/// （01-26、02-08、04-27、09-28、10-11）在上证指数日 K 里都没有任何一根柱子。
///
/// 这套判定现在只有一处实现：`StockMarketTradingCalendar` 给每个市场生成一份
/// 规则（时区 + 时段区间 + 交易日谓词），`isOpen`、`session`、`sessionEnded`、
/// `latestCompletedFinalSessionEnd` 全部复用同一份，所以下面这些入口不可能出现
/// 「一个认得调休、另一个不认得」的分叉。
struct StockTradingCalendarTests {
    /// 2026-09-20 是周日，因中秋国庆调休而补班，但 A 股休市。
    @Test func compensatoryWorkDayOnWeekendIsNotATradingDay() {
        #expect(
            StockMarketTradingCalendar.isTradingDay(
                .aShare,
                on: StockChartFixtures.date(2026, 9, 20, hour: 10),
                snapshot: Self.snapshot2026
            ) == false
        )
    }

    /// 补班日就算恰好没有任何休市表数据，也要靠「周末」本身拦住。
    @Test func compensatoryWorkDayIsNotATradingDayWithoutHolidayData() {
        #expect(
            StockMarketTradingCalendar.isTradingDay(
                .aShare,
                on: StockChartFixtures.date(2026, 9, 20, hour: 10),
                snapshot: AShareHolidaySnapshot()
            ) == false
        )
        // 2026-10-10 是周六补班，同理。
        #expect(
            StockMarketTradingCalendar.isTradingDay(
                .aShare,
                on: StockChartFixtures.date(2026, 10, 10, hour: 10),
                snapshot: AShareHolidaySnapshot()
            ) == false
        )
    }

    /// 法定节假日落在周一至周五时休市，这一半才是休市表的用处。
    @Test func mandatedHolidayOnWeekdayIsNotATradingDay() {
        // 2026-09-25 周五、2026-10-01 周四都在中秋国庆假期内。
        #expect(
            StockMarketTradingCalendar.isTradingDay(
                .aShare,
                on: StockChartFixtures.date(2026, 9, 25, hour: 10),
                snapshot: Self.snapshot2026
            ) == false
        )
        #expect(
            StockMarketTradingCalendar.isTradingDay(
                .aShare,
                on: StockChartFixtures.date(2026, 10, 1, hour: 10),
                snapshot: Self.snapshot2026
            ) == false
        )
    }

    @Test func ordinaryWeekdayIsATradingDay() {
        // 2026-09-21 周一、2026-09-18 周五都是普通交易日。
        #expect(
            StockMarketTradingCalendar.isTradingDay(
                .aShare,
                on: StockChartFixtures.date(2026, 9, 21, hour: 10),
                snapshot: Self.snapshot2026
            )
        )
        #expect(
            StockMarketTradingCalendar.isTradingDay(
                .aShare,
                on: StockChartFixtures.date(2026, 9, 18, hour: 10),
                snapshot: Self.snapshot2026
            )
        )
    }

    /// 非交易日不可能「开盘中」：`isOpen` 与 `session` 必须跟着交易日判定一起否掉，
    /// 否则顶部时段标签会和刷新结果对不上。10:00 落在上午的常规时段内，只有日期
    /// 判定能挡住它。
    @Test func aShareIsNotOpenOnCompensatoryWorkDay() {
        let noon = StockChartFixtures.date(2026, 9, 20, hour: 10)
        #expect(
            StockMarketTradingCalendar.isOpen(.aShare, at: noon, snapshot: Self.snapshot2026) == false
        )
        #expect(
            StockMarketTradingCalendar.session(
                for: .aShare,
                at: noon,
                snapshot: Self.snapshot2026
            ) == .closed
        )
        #expect(
            StockMarketTradingCalendar.isSessionActive(
                .aShare,
                at: noon,
                snapshot: Self.snapshot2026
            ) == false
        )
    }

    /// 「最近一次已完成的收盘」要跳过调休的周末，落回上一个真正的交易日。
    /// 刷新去重、分时缓存的有效期都按这个时刻算，错一天就会把上周五的数据
    /// 当成今天的。
    @Test func latestCompletedFinalSessionEndSkipsCompensatoryWeekend() {
        let settled = StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
            for: .aShare,
            at: StockChartFixtures.date(2026, 9, 20, hour: 21),
            snapshot: Self.snapshot2026
        )
        // 2026-09-19 周六、09-20 周日（补班）都不交易，上一个交易日是 09-18 周五。
        #expect(settled == StockChartFixtures.date(2026, 9, 18, hour: 15))
    }

    /// 收盘时刻取自常规时段的末端，不再由调用方手写分钟数。A 股 15:00、
    /// 港股 16:00、美股 16:00（当地时间）。
    @Test func latestCompletedFinalSessionEndUsesEachMarketsClose() {
        #expect(
            StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
                for: .hongKong,
                at: StockChartFixtures.date(2026, 9, 18, hour: 20, timeZone: "Asia/Hong_Kong")
            ) == StockChartFixtures.date(2026, 9, 18, hour: 16, timeZone: "Asia/Hong_Kong")
        )
        #expect(
            StockMarketTradingCalendar.latestCompletedFinalSessionEnd(
                for: .unitedStates,
                at: StockChartFixtures.date(2026, 9, 18, hour: 20, timeZone: "America/New_York")
            ) == StockChartFixtures.date(2026, 9, 18, hour: 16, timeZone: "America/New_York")
        )
    }

    /// 调休的周末没有任何时段收盘，跨过它的时间窗不能被判成「收过盘了」。
    @Test func noSessionEndsOverACompensatoryWeekend() {
        #expect(
            StockMarketTradingCalendar.sessionEnded(
                for: .aShare,
                between: StockChartFixtures.date(2026, 9, 19, hour: 16),
                and: StockChartFixtures.date(2026, 9, 20, hour: 23),
                snapshot: Self.snapshot2026
            ) == false
        )
    }

    /// `sessionEnded` 与 `finalSessionEnded` 的区别只有一处：前者把午休前那半场
    /// 也算收盘，后者只认当天最后一次收盘。两者现在共用同一个算法、靠传入的
    /// 时段区间区分，所以这条差异必须被锁住。
    @Test func lunchBreakCountsOnlyForSessionEnded() {
        let beforeLunch = StockChartFixtures.date(2026, 9, 18, hour: 11)
        let afterLunch = StockChartFixtures.date(2026, 9, 18, hour: 12)

        // A 股 11:30 是上半场收盘。
        #expect(
            StockMarketTradingCalendar.sessionEnded(
                for: .aShare,
                between: beforeLunch,
                and: afterLunch,
                snapshot: Self.snapshot2026
            )
        )
        #expect(
            StockMarketTradingCalendar.finalSessionEnded(
                for: .aShare,
                between: beforeLunch,
                and: afterLunch,
                snapshot: Self.snapshot2026
            ) == false
        )
        // 当天最后一次收盘（15:00）两者都认。
        #expect(
            StockMarketTradingCalendar.finalSessionEnded(
                for: .aShare,
                between: StockChartFixtures.date(2026, 9, 18, hour: 14),
                and: StockChartFixtures.date(2026, 9, 18, hour: 16),
                snapshot: Self.snapshot2026
            )
        )
    }

    /// 只收休市日的另一面：`isMandatedHoliday` 对没有记录的日子一律为假，
    /// 不能把「没写进表里」误读成什么别的状态。
    @Test func snapshotOnlyAnswersMandatedHolidays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt

        #expect(
            Self.snapshot2026.isMandatedHoliday(
                for: StockChartFixtures.date(2026, 10, 1),
                calendar: calendar
            )
        )
        // 补班日不进表，所以查不到。
        #expect(
            Self.snapshot2026.isMandatedHoliday(
                for: StockChartFixtures.date(2026, 9, 20),
                calendar: calendar
            ) == false
        )
        // 另一年没有数据。
        #expect(
            Self.snapshot2026.isMandatedHoliday(
                for: StockChartFixtures.date(2025, 10, 1),
                calendar: calendar
            ) == false
        )
    }

    /// 2026 年中秋国庆假期（holiday-cn 口径的休息日），键为 `月 * 100 + 日`。
    private static let snapshot2026: AShareHolidaySnapshot = {
        let snapshot = AShareHolidaySnapshot()
        snapshot.update(holidayOverrides: [
            2026: [925, 926, 927, 1001, 1002, 1003, 1004, 1005, 1006, 1007]
        ])
        return snapshot
    }()
}
