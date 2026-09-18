import Foundation
import Testing
@testable import MyTools

struct StockSparklineTests {
    @Test func downsamplingKeepsBoundsAndRequestedPointCount() throws {
        let closes = (0..<120).map { Double($0) }
        let points = closes.enumerated().map { index, close in
            StockChartFixtures.point(
                at: StockChartFixtures.date(2026, 9, 17, hour: 9, minute: 30 + index),
                close: close
            )
        }

        let series = try #require(
            StockSparklineSeries.make(points: points, maxPoints: 40)
        )

        #expect(series.values.count == 40)
        #expect(series.values.first == 0)
        #expect(series.values.last == 119)
        #expect(series.lowest == 0)
        #expect(series.highest == 119)
    }

    @Test func shortSeriesIsKeptVerbatim() throws {
        let points = [11.0, 12.0, 10.5].enumerated().map { index, close in
            StockChartFixtures.point(
                at: StockChartFixtures.date(2026, 9, 17, hour: 10, minute: index),
                close: close
            )
        }

        let series = try #require(
            StockSparklineSeries.make(points: points, maxPoints: 40)
        )

        #expect(series.values == [11, 12, 10.5])
    }

    @Test func emptyInputProducesNoSeries() {
        #expect(StockSparklineSeries.make(points: []) == nil)

        let point = StockChartFixtures.point(
            at: StockChartFixtures.date(2026, 9, 17),
            close: 12
        )
        #expect(
            StockSparklineSeries.make(points: [point], maxPoints: 0) == nil
        )
    }
}

/// `resolve` decides which cached series the row draws and on which axis. The
/// cached intraday snapshot can still hold a previous trading day, so these
/// tests pin the mapping with an injected `now`. 零轴不由它决定——那是行内报价的
/// 「价格 − 涨跌额」，见 `StockWatchlistRow.sparklineBaseline`。
struct StockSparklineSessionPointsTests {
    private static func usDate(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        StockChartFixtures.date(
            2026, 9, day,
            hour: hour,
            minute: minute,
            timeZone: "America/New_York"
        )
    }

    private static func resolve(
        regular: [StockChartPoint] = [],
        preMarket: [StockChartPoint] = [],
        postMarket: [StockChartPoint] = [],
        market: StockMarket = .unitedStates,
        at now: Date
    ) -> StockSparklineSelection {
        StockSparklineSeries.resolve(
            regular: regular,
            preMarket: preMarket,
            postMarket: postMarket,
            market: market,
            at: now
        )
    }

    @Test func preMarketDrawsTodayPreMarketInsteadOfYesterdayRegular() {
        let selection = Self.resolve(
            regular: [StockChartFixtures.point(at: Self.usDate(16, hour: 10), close: 100)],
            preMarket: [StockChartFixtures.point(at: Self.usDate(17, hour: 6), close: 105)],
            at: Self.usDate(17, hour: 7)
        )

        #expect(selection.points.map(\.close) == [105])
        #expect(selection.domain == .make(market: .unitedStates, session: .preMarket))
    }

    /// 盘前数据没更新时行内会回退到常规报价（上一个已收盘交易日的收盘价），迷你图
    /// 必须画同一段，否则一边是昨天的收盘、一边是空白。
    @Test func staleTodayPreMarketFallsBackToTheSettledRegularSession() {
        let selection = Self.resolve(
            regular: [StockChartFixtures.point(at: Self.usDate(16, hour: 10), close: 100)],
            preMarket: [StockChartFixtures.point(at: Self.usDate(16, hour: 6), close: 105)],
            at: Self.usDate(17, hour: 7)
        )

        #expect(selection.points.map(\.close) == [100])
        #expect(selection.domain == .make(market: .unitedStates, session: .regular))
    }

    @Test func preMarketWithoutTodayBarsDrawsTheSettledRegularSession() {
        let selection = Self.resolve(
            regular: [StockChartFixtures.point(at: Self.usDate(16, hour: 10), close: 100)],
            at: Self.usDate(17, hour: 7)
        )

        #expect(selection.points.map(\.close) == [100])
    }

    /// 只回看当天或最近一个已收盘交易日：更早的缓存配不上一个刚刷新过的报价。
    @Test func fallbackRejectsARegularDayOlderThanTheSettledSession() {
        let selection = Self.resolve(
            regular: [StockChartFixtures.point(at: Self.usDate(10, hour: 10), close: 100)],
            at: Self.usDate(17, hour: 7)
        )

        #expect(selection.points.isEmpty)
    }

    @Test func closedSessionRejectsARegularDayOlderThanTheSettledSession() {
        let selection = Self.resolve(
            regular: [StockChartFixtures.point(at: Self.usDate(10, hour: 10), close: 100)],
            at: Self.usDate(17, hour: 22)
        )

        #expect(selection.points.isEmpty)
    }

    /// 盘中时段缓存还没刷到当天时同样留空，不把上一交易日的完整走势冒充成今天。
    @Test func regularSessionDrawsNothingWhenTodayHasNoBarsYet() {
        let selection = Self.resolve(
            regular: [StockChartFixtures.point(at: Self.usDate(16, hour: 10), close: 100)],
            at: Self.usDate(17, hour: 11)
        )

        #expect(selection.points.isEmpty)
    }

    @Test func postMarketAppendsExtendedBarsToTodayRegularLine() {
        let selection = Self.resolve(
            regular: [
                StockChartFixtures.point(at: Self.usDate(17, hour: 10), close: 100),
                StockChartFixtures.point(at: Self.usDate(17, hour: 15), close: 101)
            ],
            preMarket: [StockChartFixtures.point(at: Self.usDate(17, hour: 6), close: 99)],
            postMarket: [StockChartFixtures.point(at: Self.usDate(17, hour: 16, minute: 30), close: 102)],
            at: Self.usDate(17, hour: 17)
        )

        #expect(selection.points.map(\.close) == [100, 101, 102])
        #expect(selection.domain == .make(market: .unitedStates, session: .postMarket))
    }

    /// 盘后的参照是当天盘中的收盘价；当天盘中还没刷到时行内也拿不到盘后涨跌，两边
    /// 一起退回当天盘中（此处为空）。
    @Test func postMarketNeedsTodayRegularBarsAsItsReference() {
        let selection = Self.resolve(
            regular: [StockChartFixtures.point(at: Self.usDate(16, hour: 10), close: 100)],
            postMarket: [StockChartFixtures.point(at: Self.usDate(17, hour: 17), close: 102)],
            at: Self.usDate(17, hour: 17, minute: 30)
        )

        #expect(selection.points.isEmpty)
        #expect(selection.domain == .make(market: .unitedStates, session: .regular))
    }

    @Test func closedSessionDrawsTheLatestRegularDayOnly() {
        let selection = Self.resolve(
            regular: [
                StockChartFixtures.point(at: Self.usDate(16, hour: 10), close: 99),
                StockChartFixtures.point(at: Self.usDate(17, hour: 10), close: 100)
            ],
            preMarket: [StockChartFixtures.point(at: Self.usDate(17, hour: 6), close: 105)],
            at: Self.usDate(17, hour: 22)
        )

        #expect(selection.points.map(\.close) == [100])
    }

    /// 盘中和休市一律画盘中线：只有盘前数据时宁可不画，也不把盘前当成盘中。
    @Test func regularSessionNeverSubstitutesPreMarketBars() {
        let selection = Self.resolve(
            preMarket: [StockChartFixtures.point(at: Self.usDate(17, hour: 6), close: 105)],
            at: Self.usDate(17, hour: 11)
        )

        #expect(selection.points.isEmpty)
        #expect(StockSparklineSeries.make(
            points: selection.points,
            domain: selection.domain
        ) == nil)
    }

    @Test func aShareIgnoresExtendedHoursSeries() {
        let regular = StockChartFixtures.point(
            at: StockChartFixtures.date(2026, 9, 17, hour: 10),
            close: 12
        )

        let selection = Self.resolve(
            regular: [regular],
            market: .aShare,
            at: StockChartFixtures.date(2026, 9, 17, hour: 14)
        )

        #expect(selection.points.map(\.close) == [12])
    }
}

/// 横坐标域：整条 x 轴代表本时段的全部交易分钟，折线从左往右生长。
struct StockSparklineDomainTests {
    @Test func unitedStatesRegularSessionMapsOpenToZeroAndCloseToOne() throws {
        let domain = StockSparklineDomain.make(market: .unitedStates, session: .regular)
        #expect(domain.totalMinutes == 390)

        let open = try #require(domain.offset(for: Self.usDate(hour: 9, minute: 30)))
        let noon = try #require(domain.offset(for: Self.usDate(hour: 12, minute: 45)))
        let close = try #require(domain.offset(for: Self.usDate(hour: 16, minute: 0)))

        #expect(open == 0)
        #expect(abs(noon - 0.5) < 0.01)
        #expect(close == 1)
    }

    @Test func unitedStatesPreMarketUsesOnlyThePreMarketRange() throws {
        let domain = StockSparklineDomain.make(market: .unitedStates, session: .preMarket)
        #expect(domain.totalMinutes == 330)

        #expect(try #require(domain.offset(for: Self.usDate(hour: 4, minute: 0))) == 0)
        #expect(try #require(domain.offset(for: Self.usDate(hour: 9, minute: 30))) == 1)
        // 早于域起点的时间戳夹到 0，不会画到轴外。
        #expect(try #require(domain.offset(for: Self.usDate(hour: 3, minute: 0))) == 0)
    }

    @Test func unitedStatesPostMarketAppendsExtendedRangeAfterRegular() throws {
        let domain = StockSparklineDomain.make(market: .unitedStates, session: .postMarket)
        #expect(domain.totalMinutes == 630)

        let close = try #require(domain.offset(for: Self.usDate(hour: 16, minute: 0)))
        #expect(abs(close - 390.0 / 630.0) < 0.0001)
        #expect(try #require(domain.offset(for: Self.usDate(hour: 20, minute: 0))) == 1)
    }

    @Test func aShareLunchBreakLeavesNoGapOnTheAxis() throws {
        let domain = StockSparklineDomain.make(market: .aShare, session: .regular)
        #expect(domain.totalMinutes == 240)

        // 11:30 收上半场、13:00 开下半场，两者在轴上是同一个位置。
        let morningClose = try #require(domain.offset(for: Self.shanghaiDate(hour: 11, minute: 30)))
        let afternoonOpen = try #require(domain.offset(for: Self.shanghaiDate(hour: 13, minute: 0)))
        #expect(morningClose == 0.5)
        #expect(afternoonOpen == 0.5)
        #expect(try #require(domain.offset(for: Self.shanghaiDate(hour: 15, minute: 0))) == 1)
    }

    @Test func nonUnitedStatesMarketsFallBackToRegularRangesForExtendedSessions() {
        let preMarket = StockSparklineDomain.make(market: .hongKong, session: .preMarket)
        let regular = StockSparklineDomain.make(market: .hongKong, session: .regular)
        #expect(preMarket == regular)
    }

    @Test func emptyDomainReturnsNoOffsetSoCallersFallBackToEvenSpacing() {
        let domain = StockSparklineDomain(market: .aShare, ranges: [])
        #expect(domain.offset(for: Self.shanghaiDate(hour: 10, minute: 0)) == nil)
    }

    @Test func seriesUsesDomainOffsetsInsteadOfEvenSpacing() throws {
        let domain = StockSparklineDomain.make(market: .unitedStates, session: .regular)
        let points = [
            StockChartFixtures.point(at: Self.usDate(hour: 9, minute: 30), close: 100),
            StockChartFixtures.point(at: Self.usDate(hour: 10, minute: 30), close: 101)
        ]

        let series = try #require(
            StockSparklineSeries.make(points: points, domain: domain)
        )

        // 等距排布会给出 [0, 1]；按域排布第二点只走完 60/390。
        #expect(series.offsets.count == 2)
        #expect(series.offsets[0] == 0)
        #expect(abs(series.offsets[1] - 60.0 / 390.0) < 0.0001)
    }

    private static func usDate(hour: Int, minute: Int) -> Date {
        StockChartFixtures.date(
            2026, 9, 17,
            hour: hour,
            minute: minute,
            timeZone: "America/New_York"
        )
    }

    private static func shanghaiDate(hour: Int, minute: Int) -> Date {
        StockChartFixtures.date(
            2026, 9, 17,
            hour: hour,
            minute: minute,
            timeZone: "Asia/Shanghai"
        )
    }
}

/// 行内盘前/盘后报价的当天校验。缓存里留着上一交易日的扩展时段数据时必须整套返回
/// nil，让行内回退到常规报价——否则价格是昨天的盘前，而迷你图按当天判定画另一段。
struct StockExtendedHoursDayValidationTests {
    @Test func preMarketPerformanceUsesTodayBarsAgainstTheSettledClose() throws {
        let snapshot = Self.snapshot(
            points: [Self.point(16, hour: 15, close: 100)],
            preMarketPoints: [Self.point(17, hour: 6, close: 105)]
        )

        let performance = try #require(
            StockChartPresentation.preMarketPerformance(
                snapshot: snapshot,
                market: .unitedStates,
                at: Self.date(17, hour: 7)
            )
        )

        #expect(abs(performance.change - 5) < 0.0001)
        #expect(abs(performance.percent - 0.05) < 0.0001)
    }

    @Test func preMarketPerformanceIsNilWhenTheCachedPreMarketIsFromAnotherDay() {
        let snapshot = Self.snapshot(
            points: [Self.point(15, hour: 15, close: 100)],
            preMarketPoints: [Self.point(16, hour: 6, close: 105)]
        )

        #expect(StockChartPresentation.preMarketPerformance(
            snapshot: snapshot,
            market: .unitedStates,
            at: Self.date(17, hour: 7)
        ) == nil)
    }

    @Test func postMarketPerformanceMeasuresAgainstTheSameDayRegularClose() throws {
        let snapshot = Self.snapshot(
            points: [Self.point(17, hour: 15, close: 100)],
            postMarketPoints: [Self.point(17, hour: 17, close: 102)]
        )

        let performance = try #require(
            StockChartPresentation.postMarketPerformance(
                snapshot: snapshot,
                market: .unitedStates,
                at: Self.date(17, hour: 17, minute: 30)
            )
        )

        #expect(abs(performance.change - 2) < 0.0001)
        #expect(abs(performance.percent - 0.02) < 0.0001)
    }

    @Test func postMarketPerformanceIsNilWhenTheRegularReferenceIsFromAnotherDay() {
        let snapshot = Self.snapshot(
            points: [Self.point(16, hour: 15, close: 100)],
            postMarketPoints: [Self.point(17, hour: 17, close: 102)]
        )

        #expect(StockChartPresentation.postMarketPerformance(
            snapshot: snapshot,
            market: .unitedStates,
            at: Self.date(17, hour: 17, minute: 30)
        ) == nil)
    }

    @Test func postMarketPerformanceIsNilWhenTheCachedPostMarketIsFromAnotherDay() {
        let snapshot = Self.snapshot(
            points: [Self.point(16, hour: 15, close: 100)],
            postMarketPoints: [Self.point(16, hour: 17, close: 102)]
        )

        #expect(StockChartPresentation.postMarketPerformance(
            snapshot: snapshot,
            market: .unitedStates,
            at: Self.date(17, hour: 17, minute: 30)
        ) == nil)
    }

    private static func date(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        StockChartFixtures.date(
            2026, 9, day,
            hour: hour,
            minute: minute,
            timeZone: "America/New_York"
        )
    }

    private static func point(_ day: Int, hour: Int, close: Double) -> StockChartPoint {
        StockChartFixtures.point(at: date(day, hour: hour), close: close)
    }

    private static func snapshot(
        points: [StockChartPoint],
        preMarketPoints: [StockChartPoint] = [],
        postMarketPoints: [StockChartPoint] = []
    ) -> StockChartSnapshot {
        StockChartSnapshot(
            symbol: "BRK.B",
            name: "Berkshire",
            currencyCode: "USD",
            previousClose: nil,
            points: points,
            preMarketPoints: preMarketPoints,
            postMarketPoints: postMarketPoints,
            indicatorPoints: nil,
            quoteUpdatedAt: Date(timeIntervalSince1970: 0),
            fetchedAt: Date(timeIntervalSince1970: 0),
            source: "Fixture",
            supportsCandlesticks: true
        )
    }
}

struct StockConvertedPortfolioSummaryTests {
    @Test func todayChangeRateUsesYesterdayClosingValue() {
        var stock = StockHolding(symbol: "600000")
        stock.transactions = [Self.buy(quantity: 100, unitPrice: 10)]
        stock.latestPrice = 11
        stock.previousClose = 10

        let summary = StockConvertedPortfolioSummary(
            stocks: [stock],
            multipliers: [.aShare: 1]
        )

        #expect(summary.previousMarketValue == 1_000)
        #expect(summary.todayProfitLoss == 100)
        #expect(summary.todayChangeRate == Decimal(string: "0.1"))
    }

    @Test func todayChangeRateIsNilWhenQuoteIsMissing() {
        var stock = StockHolding(symbol: "600000")
        stock.transactions = [Self.buy(quantity: 100, unitPrice: 10)]

        let summary = StockConvertedPortfolioSummary(
            stocks: [stock],
            multipliers: [.aShare: 1]
        )

        #expect(summary.todayProfitLoss == nil)
        #expect(summary.previousMarketValue == nil)
        #expect(summary.todayChangeRate == nil)
    }

    @Test func todayChangeRateIsNilWhenExchangeRateIsMissing() {
        var stock = StockHolding(symbol: "AAPL")
        stock.market = .unitedStates
        stock.transactions = [Self.buy(quantity: 10, unitPrice: 100)]
        stock.latestPrice = 110
        stock.previousClose = 100

        let summary = StockConvertedPortfolioSummary(
            stocks: [stock],
            multipliers: [.aShare: 1]
        )

        #expect(summary.marketValue == nil)
        #expect(summary.todayChangeRate == nil)
    }

    /// 已实现收益只依赖汇率，不依赖行情：卖出盈亏和净分红都是已经落袋的金额。
    /// 总览里它是「持仓总盈亏 + 已实现收益 = 累计总收益」这一行的中间列，缺行情时
    /// 另外两列显示待同步，它仍应给出数字。
    @Test func realizedProfitLossSurvivesAMissingQuote() {
        var stock = StockHolding(symbol: "600000")
        stock.transactions = [
            Self.buy(quantity: 100, unitPrice: 10),
            Self.sell(quantity: 40, unitPrice: 15)
        ]
        stock.dividends = [Self.dividend(gross: 30, tax: 5)]

        let summary = StockConvertedPortfolioSummary(
            stocks: [stock],
            multipliers: [.aShare: 1]
        )

        // 卖出实现 40 × (15 − 10) = 200，净分红 30 − 5 = 25。
        #expect(summary.realizedProfitLoss == 225)
        #expect(summary.holdingProfitLoss == nil)
        #expect(summary.totalProfitLoss == nil)
    }

    @Test func realizedProfitLossIsNilWhenExchangeRateIsMissing() {
        var stock = StockHolding(symbol: "AAPL")
        stock.market = .unitedStates
        stock.transactions = [
            Self.buy(quantity: 10, unitPrice: 100),
            Self.sell(quantity: 10, unitPrice: 120)
        ]

        let summary = StockConvertedPortfolioSummary(
            stocks: [stock],
            multipliers: [.aShare: 1]
        )

        #expect(summary.realizedProfitLoss == nil)
    }

    @Test func realizedProfitLossConvertsEachMarketWithItsOwnRate() {
        var aShare = StockHolding(symbol: "600000")
        aShare.transactions = [
            Self.buy(quantity: 100, unitPrice: 10),
            Self.sell(quantity: 100, unitPrice: 11)
        ]

        var usStock = StockHolding(symbol: "AAPL")
        usStock.market = .unitedStates
        usStock.transactions = [
            Self.buy(quantity: 10, unitPrice: 100),
            Self.sell(quantity: 10, unitPrice: 110)
        ]

        let summary = StockConvertedPortfolioSummary(
            stocks: [aShare, usStock],
            multipliers: [.aShare: 1, .unitedStates: 7]
        )

        // A 股 100 + 美股 100 × 7。
        #expect(summary.realizedProfitLoss == 800)
    }

    private static func buy(quantity: Decimal, unitPrice: Decimal) -> StockTransaction {
        var transaction = StockTransaction()
        transaction.type = .buy
        transaction.tradedAt = Date().addingTimeInterval(-86_400)
        transaction.quantity = quantity
        transaction.unitPrice = unitPrice
        return transaction
    }

    private static func sell(quantity: Decimal, unitPrice: Decimal) -> StockTransaction {
        var transaction = StockTransaction()
        transaction.type = .sell
        transaction.tradedAt = Date().addingTimeInterval(-43_200)
        transaction.quantity = quantity
        transaction.unitPrice = unitPrice
        return transaction
    }

    private static func dividend(gross: Decimal, tax: Decimal) -> StockDividend {
        var dividend = StockDividend()
        dividend.receivedAt = Date().addingTimeInterval(-43_200)
        dividend.grossAmount = gross
        dividend.withholdingTax = tax
        return dividend
    }
}
