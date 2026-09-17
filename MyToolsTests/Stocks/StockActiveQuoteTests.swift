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
