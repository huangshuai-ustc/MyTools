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

    @Test func stockListStateSeparatesPositionWatchlistAndArchive() throws {
        let watchOnly = StockHolding(symbol: "AAPL")
        #expect(watchOnly.listState == .watchlist)

        var holding = watchOnly
        let buy = Self.transaction(type: .buy, day: 1, quantity: 2)
        holding.transactions = [buy]
        #expect(holding.listState == .holding)

        var closed = holding
        var sell = Self.transaction(type: .sell, day: 2, quantity: 2)
        sell.unitPrice = 12
        closed.transactions.append(sell)
        let archivedAt = Self.date(day: 3)
        closed = try #require(StockPortfolioEditor.archiving(closed, at: archivedAt))
        #expect(closed.listState == .archived)
        #expect(closed.archivedAt == archivedAt)
        #expect(closed.realizedProfitLoss == 4)
        let summary = StockPortfolioSummary(market: .aShare, stocks: [closed])
        #expect(summary.totalProfitLoss == 4)
        #expect(StockPortfolioEditor.restoring(closed)?.listState == .watchlist)
    }

    @Test func archivingRequiresHistoricalActivityAndZeroPosition() {
        let watchOnly = StockHolding(symbol: "AAPL")
        #expect(StockPortfolioEditor.archiving(watchOnly, at: Date()) == nil)

        var holding = watchOnly
        holding.transactions = [Self.transaction(type: .buy, day: 1, quantity: 1)]
        #expect(StockPortfolioEditor.archiving(holding, at: Date()) == nil)
    }

    @Test func addingTransactionRestoresAnArchivedStock() throws {
        var stock = StockHolding(symbol: "AAPL")
        stock.transactions = [
            Self.transaction(type: .buy, day: 1, quantity: 1),
            Self.transaction(type: .sell, day: 2, quantity: 1)
        ]
        stock = try #require(StockPortfolioEditor.archiving(stock, at: Self.date(day: 3)))

        let rebuy = Self.transaction(type: .buy, day: 4, quantity: 2)
        let restored = try #require(StockPortfolioEditor.upserting(rebuy, in: stock))
        #expect(restored.archivedAt == nil)
        #expect(restored.listState == .holding)
        #expect(restored.currentShares == 2)
    }

    @Test func legacyStockPayloadWithoutArchiveDateStillDecodes() throws {
        var stock = StockHolding(symbol: "AAPL")
        stock.archivedAt = Self.date(day: 3)
        let encoded = try JSONEncoder().encode(stock)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "archivedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StockHolding.self, from: legacyData)
        #expect(decoded.archivedAt == nil)
        #expect(decoded.listState == .watchlist)
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
            alerts: [deletedAlert, retainedAlert, unlinkedAlert],
            returnAlerts: []
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

    @Test func marketSummaryProfitRateUsesAggregateProfitAndHoldingCost() {
        var stock = StockHolding(market: .unitedStates, symbol: "AAPL")
        stock.transactions = [Self.transaction(type: .buy, day: 1, quantity: 2)]
        stock.latestPrice = 15

        let summary = StockPortfolioSummary(market: .unitedStates, stocks: [stock])

        #expect(summary.holdingCost == 20)
        #expect(summary.profitLoss == 10)
        #expect(summary.holdingProfitRate == 0.5)
    }

    @Test func stockMetricsFormatOnlyAtDisplayBoundary() {
        #expect(StockValueFormatter.integerQuantity(1200) == "1,200")
        #expect(StockValueFormatter.signedPercent(Decimal(string: "-0.03456")!) == "-3.46%")
        #expect(StockValueFormatter.signedPercent(Decimal(string: "0.02344")!) == "+2.34%")
        #expect(StockValueFormatter.money(Decimal(string: "123456.789")!, currencyCode: "CNY") == "¥123,456.79")
    }

    @Test func pointInTimeHoldingCostMatchesCurrentHoldingCostAtToday() {
        var stock = StockHolding(market: .aShare, symbol: "600000")
        var buy1 = Self.transaction(type: .buy, day: 1, quantity: 10)
        buy1.unitPrice = 10
        buy1.fees = 1
        var sell1 = Self.transaction(type: .sell, day: 2, quantity: 4)
        sell1.unitPrice = 12
        sell1.fees = 0.5
        var buy2 = Self.transaction(type: .buy, day: 3, quantity: 6)
        buy2.unitPrice = 11
        buy2.fees = 0.8
        stock.transactions = [buy1, sell1, buy2]

        let pointInTimeCost = PortfolioValueHistoryBuilder.holdingCost(for: stock, on: Date())
        #expect(pointInTimeCost == stock.holdingCost)
    }

    @Test func pointInTimeHoldingCostReplaysOnlyTransactionsUpToDate() {
        var stock = StockHolding(market: .aShare, symbol: "600000")
        var buy1 = Self.transaction(type: .buy, day: 1, quantity: 10)
        buy1.unitPrice = 10
        var buy2 = Self.transaction(type: .buy, day: 5, quantity: 5)
        buy2.unitPrice = 20
        stock.transactions = [buy1, buy2]

        let costBeforeSecondBuy = PortfolioValueHistoryBuilder.holdingCost(for: stock, on: Self.date(day: 3))
        #expect(costBeforeSecondBuy == 100)

        let costAfterSecondBuy = PortfolioValueHistoryBuilder.holdingCost(for: stock, on: Self.date(day: 5))
        #expect(costAfterSecondBuy == 200)
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

    @Test func minutePortfolioSeedsPricesForSymbolsWhoseCachesStartLater() throws {
        let firstMinute = Self.shanghaiDate(day: 14, hour: 9, minute: 30)
        let secondMinute = Self.shanghaiDate(day: 14, hour: 9, minute: 31)
        var firstStock = StockHolding(market: .aShare, symbol: "600000")
        var firstBuy = Self.transaction(type: .buy, day: 1, quantity: 1)
        firstBuy.unitPrice = 10
        firstStock.transactions = [firstBuy]
        var secondStock = StockHolding(market: .aShare, symbol: "600001")
        var secondBuy = Self.transaction(type: .buy, day: 1, quantity: 1)
        secondBuy.unitPrice = 20
        secondStock.transactions = [secondBuy]

        let series = PortfolioValueHistoryBuilder.buildMinuteSeries(
            for: .aShare,
            range: .fiveDays,
            stocks: [firstStock, secondStock],
            minutePointsBySymbol: [
                firstStock.symbol: [
                    Self.chartPoint(date: firstMinute, close: 10),
                    Self.chartPoint(date: secondMinute, close: 10)
                ],
                secondStock.symbol: [Self.chartPoint(date: secondMinute, close: 20)]
            ]
        )

        #expect(try #require(series.points.first).value == 30)
        #expect(try #require(series.points.last).value == 30)
    }

    @Test func minuteCNYSeriesSeedsEveryMarketsCostAtTimelineStart() throws {
        let firstDate = Self.shanghaiDate(day: 14, hour: 9, minute: 30)
        let laterDate = Self.shanghaiDate(day: 14, hour: 21, minute: 30)
        let aShare = PortfolioValueSeries(
            id: "a",
            label: "A 股",
            market: .aShare,
            currencyCode: "CNY",
            points: [PortfolioValuePoint(date: firstDate, value: 90)],
            costBasis: 100,
            costBasisPoints: [PortfolioCostBasisPoint(date: firstDate, cost: 100)]
        )
        let unitedStates = PortfolioValueSeries(
            id: "us",
            label: "美股",
            market: .unitedStates,
            currencyCode: "USD",
            points: [PortfolioValuePoint(date: laterDate, value: 9)],
            costBasis: 10,
            costBasisPoints: [PortfolioCostBasisPoint(date: laterDate, cost: 10)]
        )

        let combined = try #require(PortfolioValueHistoryBuilder.buildMinuteCNYSeries(
            from: [aShare, unitedStates],
            rates: [.usd: 7]
        ))

        #expect(try #require(combined.points.first).value == 153)
        #expect(try #require(combined.costBasisPoints.first).cost == 170)
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

    private static func shanghaiDate(day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 9,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private static func chartPoint(date: Date, close: Double) -> StockChartPoint {
        StockChartPoint(date: date, open: close, high: close, low: close, close: close, volume: 1)
    }
}
