import Foundation
import Testing
@testable import MyTools

/// 行内报价的「单一来源」约定：价格、涨跌额和涨跌幅必须同时来自常规报价，或者同时
/// 来自扩展时段派生值，绝不混用。混用曾经产出「-$1.59（+0.45%）」这种自相矛盾的行。
struct StockActiveQuoteTests {
    @Test func preMarketTakesAmountAndPercentFromTheSameSource() throws {
        var stock = Self.usStock()
        // 报价源的昨收比图表解析出的昨收高，混用就会让金额变负而百分比为正。
        stock.previousClose = 100
        stock.latestPrice = 98
        stock.changePercent = Decimal(string: "-0.02")

        let quote = StockActiveQuote.make(
            stock: stock,
            extendedHours: Self.performance(
                preMarketPrice: 96,
                preMarketChange: Decimal(string: "0.43"),
                preMarketPercent: Decimal(string: "0.0045")
            ),
            at: Self.usDate(hour: 7)
        )

        #expect(quote.price == 96)
        #expect(quote.changeAmount == Decimal(string: "0.43"))
        #expect(quote.percent == Decimal(string: "0.0045"))
        // 同号：金额与百分比来自同一个基准。
        #expect((quote.changeAmount ?? 0) > 0)
        #expect(quote.sessionTitle == "盘前")
    }

    @Test func postMarketTakesAmountAndPercentFromTheSameSource() throws {
        var stock = Self.usStock()
        stock.previousClose = 100
        stock.latestPrice = 101

        let quote = StockActiveQuote.make(
            stock: stock,
            extendedHours: Self.performance(
                postMarketPrice: Decimal(string: "100.5"),
                postMarketChange: Decimal(string: "-0.5"),
                postMarketPercent: Decimal(string: "-0.00495")
            ),
            at: Self.usDate(hour: 17)
        )

        #expect(quote.price == Decimal(string: "100.5"))
        #expect(quote.changeAmount == Decimal(string: "-0.5"))
        #expect(quote.percent == Decimal(string: "-0.00495"))
        #expect(quote.sessionTitle == "盘后")
    }

    /// 扩展时段缺价时整组回退到常规报价，而不是「盘前价 + 常规百分比」这种拼接。
    @Test func missingExtendedHoursQuoteFallsBackWholesale() throws {
        var stock = Self.usStock()
        stock.previousClose = 100
        stock.latestPrice = 102
        stock.changePercent = Decimal(string: "0.02")

        let quote = StockActiveQuote.make(
            stock: stock,
            extendedHours: nil,
            at: Self.usDate(hour: 7)
        )

        #expect(quote.price == 102)
        #expect(quote.changeAmount == 2)
        #expect(quote.percent == Decimal(string: "0.02"))
        #expect(quote.sessionTitle == "当前价格")
    }

    @Test func regularSessionUsesProviderQuote() throws {
        var stock = Self.usStock()
        stock.previousClose = 100
        stock.latestPrice = 103
        stock.changePercent = Decimal(string: "0.03")

        let quote = StockActiveQuote.make(
            stock: stock,
            // 盘中即使缓存里有盘前数据也不采用。
            extendedHours: Self.performance(
                preMarketPrice: 96,
                preMarketChange: -4,
                preMarketPercent: Decimal(string: "-0.04")
            ),
            at: Self.usDate(hour: 11)
        )

        #expect(quote.price == 103)
        #expect(quote.changeAmount == 3)
        #expect(quote.percent == Decimal(string: "0.03"))
        #expect(quote.sessionTitle == "当前价格")
    }

    /// A 股与港股没有连续盘前盘后，任何时刻都走常规报价。
    @Test func aShareNeverUsesExtendedHours() throws {
        var stock = StockHolding(symbol: "600000")
        stock.market = .aShare
        stock.previousClose = 10
        stock.latestPrice = Decimal(string: "10.5")

        let quote = StockActiveQuote.make(
            stock: stock,
            extendedHours: Self.performance(preMarketPrice: 9, preMarketChange: -1),
            at: Self.usDate(hour: 7)
        )

        #expect(quote.price == Decimal(string: "10.5"))
        #expect(quote.changeAmount == Decimal(string: "0.5"))
        #expect(quote.sessionTitle == "当前价格")
    }

    @Test func missingPreviousCloseLeavesTheAmountUnknownInsteadOfZero() throws {
        var stock = Self.usStock()
        stock.latestPrice = 102

        let quote = StockActiveQuote.make(
            stock: stock,
            extendedHours: nil,
            at: Self.usDate(hour: 11)
        )

        #expect(quote.price == 102)
        #expect(quote.changeAmount == nil)
    }

    private static func usStock() -> StockHolding {
        var stock = StockHolding(symbol: "BABA")
        stock.market = .unitedStates
        return stock
    }

    private static func performance(
        preMarketPrice: Decimal? = nil,
        preMarketChange: Decimal? = nil,
        preMarketPercent: Decimal? = nil,
        postMarketPrice: Decimal? = nil,
        postMarketChange: Decimal? = nil,
        postMarketPercent: Decimal? = nil
    ) -> StockExtendedHoursPerformance {
        StockExtendedHoursPerformance(
            preMarketPrice: preMarketPrice,
            preMarketChange: preMarketChange,
            preMarketPercent: preMarketPercent,
            postMarketPrice: postMarketPrice,
            postMarketChange: postMarketChange,
            postMarketPercent: postMarketPercent
        )
    }

    private static func usDate(hour: Int, minute: Int = 0) -> Date {
        StockChartFixtures.date(
            2026, 9, 17,
            hour: hour,
            minute: minute,
            timeZone: "America/New_York"
        )
    }
}

/// 「总览 = 各行之和」必须是构造上成立的，而不是两条链路碰巧一致。
///
/// 顶部大字、市场概况、资产占比和持仓行都经过 `StockHoldingValuation`，它只从
/// `StockActiveQuote` 取价格与涨跌额，所以美股盘前/盘后不会再出现「上面按昨收、
/// 下面按盘前」。代价是盘前流动性稀薄时大字会跟着跳，这是刻意接受的。
struct StockHoldingValuationTests {
    /// 盘前的「当日盈亏」必须是股数 × 盘前涨跌额。
    ///
    /// 行情源在盘前给的是 T−1 收盘价，它的 `previousClose` 是 T−2 收盘，所以
    /// `StockHolding.todayProfitLoss` 在盘前描述的是**前一个交易日**的涨跌，
    /// 挂在「当日盈亏」下面就是错的标签。
    @Test func preMarketValuationUsesThePreMarketChangeNotYesterdaysMove() throws {
        let stock = Self.usStock(quantity: 100, cost: 90, latestPrice: 98, previousClose: 100)
        let valuation = StockHoldingValuation(
            stock: stock,
            extendedHours: Self.preMarket(price: 99, change: 1, percent: Decimal(string: "0.0102")),
            at: Self.usDate(hour: 7)
        )

        #expect(valuation.marketValue == 9_900)
        #expect(valuation.todayProfitLoss == 100)
        // 分母跟着报价走：99 − 1 = 98 才是本次百分比的基准，不是行情源的 100。
        #expect(valuation.previousMarketValue == 9_800)
        #expect(valuation.holdingProfitLoss == 900)
        // 若沿用常规报价，当日盈亏会是 100 × (98 − 100) = −200，方向都相反。
        #expect(stock.todayProfitLoss == -200)
    }

    @Test func overviewTotalsEqualTheSumOfRowsDuringPreMarket() throws {
        let now = Self.usDate(hour: 7)
        let extendedHours = Self.preMarket(price: 99, change: 1, percent: Decimal(string: "0.0102"))
        let first = Self.usStock(quantity: 100, cost: 90, latestPrice: 98, previousClose: 100)
        let second = Self.usStock(
            symbol: "BIDU",
            quantity: 50,
            cost: 80,
            latestPrice: 98,
            previousClose: 100
        )
        let map = [first.id: extendedHours, second.id: extendedHours]
        let rows = [first, second].map {
            StockHoldingValuation(stock: $0, extendedHours: extendedHours, at: now)
        }

        let converted = StockConvertedPortfolioSummary(
            stocks: [first, second],
            multipliers: [.unitedStates: 1],
            extendedHours: map,
            at: now
        )
        let market = StockPortfolioSummary(
            market: .unitedStates,
            stocks: [first, second],
            extendedHours: map,
            at: now
        )

        let expectedValue = rows.reduce(Decimal.zero) { $0 + ($1.marketValue ?? 0) }
        let expectedDaily = rows.reduce(Decimal.zero) { $0 + ($1.todayProfitLoss ?? 0) }
        #expect(converted.marketValue == expectedValue)
        #expect(converted.todayProfitLoss == expectedDaily)
        #expect(market.knownMarketValue == expectedValue)
        #expect(market.todayProfitLoss == expectedDaily)
        // 150 股 × 盘前涨 1。
        #expect(expectedDaily == 150)
    }

    /// 分母也同源，否则百分比会拿盘前的分子去除昨收的分母。缺百分比时整组回退。
    @Test func todayChangeRateFallsBackWholesaleWhenAPieceIsMissing() throws {
        let now = Self.usDate(hour: 7)
        let stock = Self.usStock(quantity: 100, cost: 90, latestPrice: 98, previousClose: 100)
        let summary = StockConvertedPortfolioSummary(
            stocks: [stock],
            multipliers: [.unitedStates: 1],
            extendedHours: [stock.id: Self.preMarket(price: 99, change: 1, percent: nil)],
            at: now
        )

        // 缺百分比时整组回退到常规报价：100 × (98 − 100) = −200，基准是昨收 10 000。
        #expect(summary.todayProfitLoss == -200)
        #expect(summary.previousMarketValue == 10_000)
        #expect(summary.todayChangeRate == Decimal(string: "-0.02"))
    }

    /// A 股与港股没有盘前盘后，即使表里塞了扩展时段数据也必须走常规报价。
    @Test func nonUnitedStatesMarketsIgnoreExtendedHours() throws {
        var stock = Self.usStock(quantity: 100, cost: 9, latestPrice: 10, previousClose: 9)
        stock.market = .aShare
        let valuation = StockHoldingValuation(
            stock: stock,
            extendedHours: Self.preMarket(price: 99, change: 1, percent: Decimal(string: "0.01")),
            at: Self.usDate(hour: 7)
        )

        #expect(valuation.marketValue == 1_000)
        #expect(valuation.todayProfitLoss == 100)
    }

    /// 与 `StockHolding` 的同名属性对齐：清仓后市值确定为 0，当日盈亏为 nil。
    @Test func closedPositionKeepsHoldingSemantics() throws {
        var stock = StockHolding(symbol: "BABA")
        stock.market = .unitedStates
        let valuation = StockHoldingValuation(stock: stock, extendedHours: nil)

        #expect(valuation.marketValue == 0)
        #expect(valuation.previousMarketValue == 0)
        #expect(valuation.todayProfitLoss == nil)
        #expect(valuation.holdingProfitLoss == 0)
    }

    /// 缺价格时整只股票的派生金额都是 nil，聚合方要据此把整列标成「待同步」。
    @Test func missingPriceMakesEveryDerivedAmountNil() throws {
        var stock = Self.usStock(quantity: 100, cost: 90, latestPrice: 98, previousClose: 100)
        stock.latestPrice = nil
        stock.previousClose = nil
        let valuation = StockHoldingValuation(stock: stock, extendedHours: nil)

        #expect(valuation.marketValue == nil)
        #expect(valuation.previousMarketValue == nil)
        #expect(valuation.todayProfitLoss == nil)
        #expect(valuation.holdingProfitLoss == nil)
    }

    private static func usStock(
        symbol: String = "BABA",
        quantity: Decimal,
        cost: Decimal,
        latestPrice: Decimal?,
        previousClose: Decimal?
    ) -> StockHolding {
        var stock = StockHolding(symbol: symbol)
        stock.market = .unitedStates
        var transaction = StockTransaction()
        transaction.type = .buy
        transaction.tradedAt = Date().addingTimeInterval(-86_400)
        transaction.quantity = quantity
        transaction.unitPrice = cost
        stock.transactions = [transaction]
        stock.latestPrice = latestPrice
        stock.previousClose = previousClose
        if let latestPrice, let previousClose, previousClose > 0 {
            stock.changePercent = (latestPrice - previousClose) / previousClose
        }
        return stock
    }

    private static func preMarket(
        price: Decimal?,
        change: Decimal?,
        percent: Decimal?
    ) -> StockExtendedHoursPerformance {
        StockExtendedHoursPerformance(
            preMarketPrice: price,
            preMarketChange: change,
            preMarketPercent: percent,
            postMarketPrice: nil,
            postMarketChange: nil,
            postMarketPercent: nil
        )
    }

    private static func usDate(hour: Int, minute: Int = 0) -> Date {
        StockChartFixtures.date(
            2026, 9, 17,
            hour: hour,
            minute: minute,
            timeZone: "America/New_York"
        )
    }
}
