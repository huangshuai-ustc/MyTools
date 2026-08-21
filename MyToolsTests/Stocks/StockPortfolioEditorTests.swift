import Foundation
import Testing
@testable import MyTools

struct StockPortfolioEditorTests {
    @Test func symbolMatchingUsesMarketNormalizationAndSupportsExclusion() {
        var stock = StockHolding()
        stock.market = .hongKong
        stock.symbol = "00700"

        #expect(StockPortfolioEditor.containsStock(
            in: [stock],
            market: .hongKong,
            symbol: "HK700"
        ))
        #expect(!StockPortfolioEditor.containsStock(
            in: [stock],
            market: .hongKong,
            symbol: "HK700",
            excluding: stock.id
        ))

        var aShare = StockHolding()
        aShare.market = .aShare
        aShare.symbol = " sh600000.ss "
        #expect(StockPortfolioEditor.normalizedHolding(aShare).symbol == "600000")
    }

    @Test func deletingStocksAlsoRemovesOnlyTheirAlerts() {
        var deletedStock = StockHolding()
        deletedStock.id = UUID()
        var retainedStock = StockHolding()
        retainedStock.id = UUID()
        let deletedAlert = StockPriceAlert(stockID: deletedStock.id, threshold: 10)
        let retainedAlert = StockPriceAlert(stockID: retainedStock.id, threshold: 20)
        let unlinkedAlert = StockPriceAlert(stockID: nil, threshold: 30)

        let result = StockPortfolioEditor.deletingStocks(
            ids: [deletedStock.id],
            from: [deletedStock, retainedStock],
            alerts: [deletedAlert, retainedAlert, unlinkedAlert]
        )

        #expect(result.stocks == [retainedStock])
        #expect(result.stockPriceAlerts == [retainedAlert, unlinkedAlert])
        #expect(result.removedAlertIDs == [deletedAlert.id])
    }

    @Test func transactionCannotSellBeforeSharesAreAvailable() {
        let sell = Self.transaction(type: .sell, day: 1, quantity: 1)

        #expect(StockPortfolioEditor.upserting(sell, in: StockHolding()) == nil)
    }

    @Test func sameDayInsertionAndEditingKeepStableOrder() throws {
        let first = Self.transaction(type: .buy, day: 1, quantity: 1)
        let second = Self.transaction(type: .buy, day: 1, quantity: 2)
        var stock = try #require(StockPortfolioEditor.upserting(first, in: StockHolding()))
        stock = try #require(StockPortfolioEditor.upserting(second, in: stock))

        #expect(stock.transactionsChronologically.map(\.id) == [first.id, second.id])
        #expect(stock.transactionsChronologically.map(\.dayOrder) == [0, 1])

        var editedFirst = first
        editedFirst.unitPrice = 25
        editedFirst.dayOrder = nil
        stock = try #require(StockPortfolioEditor.upserting(editedFirst, in: stock))

        #expect(stock.transactionsChronologically.map(\.id) == [first.id, second.id])
        #expect(stock.transactionsChronologically.map(\.dayOrder) == [0, 1])
        #expect(stock.transactionsChronologically.first?.unitPrice == 25)
    }

    @Test func deletingBuyIsRejectedWhenItWouldInvalidateLaterSale() throws {
        let buy = Self.transaction(type: .buy, day: 1, quantity: 2)
        let sell = Self.transaction(type: .sell, day: 2, quantity: 1)
        var stock = try #require(StockPortfolioEditor.upserting(buy, in: StockHolding()))
        stock = try #require(StockPortfolioEditor.upserting(sell, in: stock))

        #expect(StockPortfolioEditor.deletingTransactions(ids: [buy.id], from: stock) == nil)
    }

    @Test func reorderRequiresEveryTransactionFromOneDay() throws {
        let first = Self.transaction(type: .buy, day: 1, quantity: 1)
        let second = Self.transaction(type: .buy, day: 1, quantity: 2)
        var stock = try #require(StockPortfolioEditor.upserting(first, in: StockHolding()))
        stock = try #require(StockPortfolioEditor.upserting(second, in: stock))

        let reordered = try #require(StockPortfolioEditor.reorderingTransactions(
            [second.id, first.id],
            in: stock
        ))

        #expect(reordered.transactionsChronologically.map(\.id) == [second.id, first.id])
        #expect(StockPortfolioEditor.reorderingTransactions([first.id], in: stock) == nil)
    }

    @Test func dividendsCanBeInsertedUpdatedAndDeleted() {
        var dividend = StockDividend()
        dividend.grossAmount = 10
        var stock = StockPortfolioEditor.upserting(dividend, in: StockHolding())

        dividend.grossAmount = 20
        stock = StockPortfolioEditor.upserting(dividend, in: stock)
        #expect(stock.dividends == [dividend])

        stock = StockPortfolioEditor.deletingDividends(ids: [dividend.id], from: stock)
        #expect(stock.dividends.isEmpty)
    }

    @Test func holdingProfitRateUsesUnroundedDecimalValues() {
        var stock = StockHolding()
        var transaction = Self.transaction(type: .buy, day: 1, quantity: 3)
        transaction.unitPrice = Decimal(string: "10.123456")!
        transaction.fees = Decimal(string: "0.000001")!
        stock.transactions = [transaction]
        stock.latestPrice = Decimal(string: "11.234567")!

        let expectedCost = Decimal(string: "30.370369")!
        let expectedProfit = Decimal(string: "3.333332")!
        #expect(stock.holdingCost == expectedCost)
        #expect(stock.holdingProfitLoss == expectedProfit)
        #expect(stock.holdingProfitRate == expectedProfit / expectedCost)
    }

    @Test func stockMetricsFormatOnlyAtDisplayBoundary() {
        #expect(StockValueFormatter.integerQuantity(1200) == "1,200")
        #expect(StockValueFormatter.signedPercent(Decimal(string: "-0.03456")!) == "-3.46%")
        #expect(StockValueFormatter.signedPercent(Decimal(string: "0.02344")!) == "+2.34%")
        #expect(StockValueFormatter.money(Decimal(string: "123456.789")!, currencyCode: "CNY") == "¥123,456.79")
    }

    @Test func costAllocationUsesRemainingHoldingCostAndCurrencyConversion() throws {
        var aShare = StockHolding(market: .aShare, symbol: "600000")
        aShare.transactions = [Self.transaction(type: .buy, day: 1, quantity: 1)]

        var unitedStates = StockHolding(market: .unitedStates, symbol: "VOO")
        var foreignBuy = Self.transaction(type: .buy, day: 1, quantity: 2)
        foreignBuy.unitPrice = 50
        unitedStates.transactions = [foreignBuy]

        let allocation = StockCostAllocationSnapshot(
            stocks: [aShare, unitedStates],
            costMultipliers: [.aShare: 1, .unitedStates: 7]
        )

        #expect(allocation.isComplete)
        let aShareAllocation = try #require(allocation.holdingShare(for: aShare.id))
        let unitedStatesAllocation = try #require(allocation.holdingShare(for: unitedStates.id))
        #expect(aShareAllocation == Decimal(1) / Decimal(71))
        #expect(unitedStatesAllocation == Decimal(70) / Decimal(71))
    }

    private static func transaction(
        type: StockTransactionType,
        day: Int,
        quantity: Decimal
    ) -> StockTransaction {
        var transaction = StockTransaction()
        transaction.type = type
        transaction.tradedAt = date(day: day)
        transaction.quantity = quantity
        transaction.unitPrice = 10
        return transaction
    }

    private static func date(day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: day,
            hour: 12
        ))!
    }
}
