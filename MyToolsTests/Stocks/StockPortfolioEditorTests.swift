import Foundation
import Testing
@testable import MyTools

struct StockPortfolioEditorTests {
    @Test func xirrUsesActualRenminbiBoundaryCashFlows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let investedAt = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        let valuedAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        var deposit = StockCashFlowRecord()
        deposit.occurredAt = investedAt
        deposit.currency = .cny
        deposit.amount = 100_000

        let result = StockXIRRCalculator.calculate(
            records: [deposit],
            terminalValueRenminbi: 110_000,
            asOf: valuedAt,
            calendar: calendar
        )

        let rate = try #require(result.annualRate)
        #expect(abs(NSDecimalNumber(decimal: rate - Decimal(string: "0.10")!).doubleValue) < 0.000_001)
        #expect(result.investedRenminbi == 100_000)
        #expect(result.withdrawnRenminbi == 0)
        #expect(result.unavailableReason == nil)
    }

    @Test func xirrIncludesWithdrawalButExcludesInternalTransferLoss() throws {
        let start = Self.date(day: 1)
        let end = Self.date(day: 11)
        var deposit = StockCashFlowRecord()
        deposit.occurredAt = start
        deposit.amount = 100
        var withdrawal = StockCashFlowRecord()
        withdrawal.occurredAt = Self.date(day: 6)
        withdrawal.kind = .withdrawal
        withdrawal.amount = 20
        var loss = StockCashFlowRecord()
        loss.occurredAt = Self.date(day: 7)
        loss.kind = .transferLoss
        loss.amount = 5

        let result = StockXIRRCalculator.calculate(
            records: [deposit, withdrawal, loss],
            terminalValueRenminbi: 80,
            asOf: end
        )

        #expect(result.annualRate != nil)
        #expect(result.investedRenminbi == 100)
        #expect(result.withdrawnRenminbi == 20)
    }

    @Test func currentRenminbiValuationConvertsForeignTransferLossAtLatestRate() throws {
        let total = try #require(StockRenminbiValuation.total(
            values: [
                .cny: 1_000,
                .usd: Decimal(string: "-18.94")!
            ],
            buyingRates: [.cny: 1, .usd: Decimal(string: "7.2")!]
        ))

        #expect(total == Decimal(string: "863.632")!)
    }

    @Test func xirrPreservesTheSpecificReasonTerminalValueIsUnavailable() {
        var deposit = StockCashFlowRecord()
        deposit.occurredAt = Self.date(day: 1)
        deposit.amount = 100

        let reason = StockXIRRSnapshot.UnavailableReason.incompleteTerminalValue(
            missingQuoteSymbols: ["AAPL"],
            missingRateCurrencies: [],
            unresolvedExchangeCount: 0
        )
        let result = StockXIRRCalculator.calculate(
            records: [deposit],
            terminalValueRenminbi: nil,
            terminalValueUnavailableReason: reason,
            asOf: Self.date(day: 11)
        )

        #expect(result.unavailableReason == reason)
    }

    @Test func xirrFailsClosedForForeignBoundaryFlowWithoutHistoricalRenminbiBasis() throws {
        var deposit = StockCashFlowRecord()
        deposit.occurredAt = Self.date(day: 1)
        deposit.currency = .usd
        deposit.amount = 100

        let result = StockXIRRCalculator.calculate(
            records: [deposit],
            terminalValueRenminbi: 800,
            asOf: Self.date(day: 11)
        )

        #expect(result.annualRate == nil)
        guard case let .missingRenminbiBasis(recordIDs) = result.unavailableReason else {
            Issue.record("Expected missing RMB basis")
            return
        }
        #expect(recordIDs == [deposit.id])
    }

    @Test func xirrRecoversLegacyForeignDepositFromLinkedRenminbiExchange() throws {
        let exchangeID = UUID()
        var legacyDeposit = StockCashFlowRecord()
        legacyDeposit.occurredAt = Self.date(day: 1)
        legacyDeposit.currency = .usd
        legacyDeposit.amount = 1_000
        legacyDeposit.linkedExchangeRecordID = exchangeID
        let exchange = StockExchangeRecordSnapshot(
            id: exchangeID,
            exchangedAt: Self.date(day: 1),
            soldCurrency: .cny,
            boughtCurrency: .usd,
            soldAmount: 7_000,
            boughtAmount: 1_000,
            fee: 10
        )

        let result = StockXIRRCalculator.calculate(
            records: [legacyDeposit],
            exchangeRecords: [exchange],
            terminalValueRenminbi: 7_100,
            asOf: Self.date(day: 11)
        )

        #expect(result.annualRate != nil)
        #expect(result.investedRenminbi == 7_010)
        #expect(result.unavailableReason == nil)
    }

    @Test func stockCashFlowVaultFieldIsBackwardCompatibleAndStrictWhenPresent() throws {
        let legacy = try JSONDecoder().decode(VaultData.self, from: Data("{}".utf8))
        #expect(legacy.stockCashFlowRecords.isEmpty)

        var record = StockCashFlowRecord()
        record.kind = .withdrawal
        record.currency = .usd
        record.amount = 12.34
        record.note = "test"
        let restored = try JSONDecoder().decode(
            VaultData.self,
            from: JSONEncoder().encode(VaultData(stockCashFlowRecords: [record]))
        )
        #expect(restored.stockCashFlowRecords == [record])

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                VaultData.self,
                from: Data("{\"stockCashFlowRecords\":{}}".utf8)
            )
        }
    }

    @Test func cashLedgerCombinesExternalFlowsExchangeAndStockActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exchangeID = UUID()
        var deposit = StockCashFlowRecord()
        deposit.occurredAt = now.addingTimeInterval(-400)
        deposit.currency = .cny
        deposit.amount = 7_010
        deposit.linkedExchangeRecordID = exchangeID

        var loss = StockCashFlowRecord()
        loss.occurredAt = now.addingTimeInterval(-100)
        loss.kind = .transferLoss
        loss.currency = .usd
        loss.amount = 3

        var buy = StockTransaction()
        buy.tradedAt = now.addingTimeInterval(-200)
        buy.quantity = 5
        buy.unitPrice = 100
        buy.fees = 1
        var dividend = StockDividend()
        dividend.receivedAt = now.addingTimeInterval(-50)
        dividend.grossAmount = 10
        dividend.withholdingTax = 2
        var stock = StockHolding()
        stock.market = .unitedStates
        stock.transactions = [buy]
        stock.dividends = [dividend]

        let result = StockCashLedger.build(
            records: [deposit, loss],
            exchangeRecords: [StockExchangeRecordSnapshot(
                id: exchangeID,
                exchangedAt: now.addingTimeInterval(-300),
                soldCurrency: .cny,
                boughtCurrency: .usd,
                soldAmount: 7_000,
                boughtAmount: 1_000,
                fee: 10
            )],
            stocks: [stock],
            asOf: now
        )

        #expect(result.balances[.cny] == nil)
        #expect(result.balances[.usd] == 504)
        #expect(result.unresolvedExchangeRecordIDs.isEmpty)
    }

    @Test func cashLedgerDoesNotApplyOneExchangeTwice() {
        let exchangeID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var first = StockCashFlowRecord()
        first.occurredAt = now.addingTimeInterval(-100)
        first.currency = .cny
        first.amount = 100
        first.linkedExchangeRecordID = exchangeID
        var second = first
        second.id = UUID()
        second.amount = 50

        let result = StockCashLedger.build(
            records: [first, second],
            exchangeRecords: [StockExchangeRecordSnapshot(
                id: exchangeID,
                exchangedAt: now.addingTimeInterval(-200),
                soldCurrency: .cny,
                boughtCurrency: .usd,
                soldAmount: 100,
                boughtAmount: 14,
                fee: 0
            )],
            stocks: [],
            asOf: now
        )

        #expect(result.balances[.cny] == 50)
        #expect(result.balances[.usd] == 14)
    }

    @Test func newTransactionDateDefaultsToTheMarketsBusinessDate() throws {
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let instant = try #require(shanghaiCalendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 29,
            hour: 1
        )))

        let usDate = StockTransaction.defaultTradingDate(
            at: instant,
            market: .unitedStates,
            displayCalendar: shanghaiCalendar
        )
        let aShareDate = StockTransaction.defaultTradingDate(
            at: instant,
            market: .aShare,
            displayCalendar: shanghaiCalendar
        )
        let hongKongDate = StockTransaction.defaultTradingDate(
            at: instant,
            market: .hongKong,
            displayCalendar: shanghaiCalendar
        )

        #expect(shanghaiCalendar.dateComponents([.year, .month, .day], from: usDate)
            == DateComponents(year: 2026, month: 9, day: 28))
        #expect(shanghaiCalendar.dateComponents([.year, .month, .day], from: aShareDate)
            == DateComponents(year: 2026, month: 9, day: 29))
        #expect(shanghaiCalendar.dateComponents([.year, .month, .day], from: hongKongDate)
            == DateComponents(year: 2026, month: 9, day: 29))
    }

    @Test func fiveDayPortfolioAxisUsesFiveEqualIntervals() throws {
        let values = PortfolioChartXAxis.values(pointCount: 101, range: .fiveDays)
        let labels = PortfolioChartXAxis.labelValues(pointCount: 101, range: .fiveDays)

        #expect(values == [0, 20, 40, 60, 80, 100])
        #expect(values.count - 1 == 5)
        #expect(labels == values)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = (1...5).flatMap { day in
            (0..<20).compactMap { minute in
                calendar.date(from: DateComponents(
                    year: 2026,
                    month: 9,
                    day: day,
                    hour: 9,
                    minute: minute
                ))
            }
        }
        let layout = PortfolioFiveDayXAxis.layout(
            dates: dates,
            calendar: calendar
        )
        #expect(layout.gridValues.count == 6)
        #expect(layout.labelTexts.count == 5)
        #expect(layout.centersLabelsInIntervals)
    }

    @Test func consecutiveCostLabelsWithTheSameDisplayValueAreMerged() throws {
        let labels = PortfolioCostLabelLayout.merged([
            .init(id: "a", seriesID: "US", cost: 5_724.6, startX: 0, endX: 2),
            .init(id: "b", seriesID: "US", cost: 5_725.2, startX: 2, endX: 4),
            .init(id: "c", seriesID: "US", cost: 5_724.8, startX: 4, endX: 6),
            .init(id: "d", seriesID: "US", cost: 12_010, startX: 6, endX: 7),
            .init(id: "e", seriesID: "US", cost: 12_049, startX: 7, endX: 8)
        ]) { value in
            abs(value) >= 10_000
                ? String(format: "%.1f万", value / 10_000)
                : String(format: "%.0f", value)
        }

        #expect(labels.map(\.text) == ["5725", "1.2万"])
        #expect(labels.map(\.x) == [3, 7])
    }

    @Test func otherPortfolioAxesKeepExistingFourIntervals() {
        let values = PortfolioChartXAxis.values(pointCount: 101, range: .dayK)
        let labels = PortfolioChartXAxis.labelValues(pointCount: 101, range: .dayK)

        #expect(values == [0, 25, 50, 75, 100])
        #expect(labels == values)
    }

    @Test func portfolioKLineAxesUseCalendarBucketsAndCompactLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = [
            calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!,
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!,
            calendar.date(from: DateComponents(year: 2026, month: 2, day: 28))!
        ]

        #expect(PortfolioChartXAxis.gridValues(dates: dates, range: .monthK, calendar: calendar) == [0, 1, 2])
        #expect(PortfolioChartXAxis.labelValues(dates: dates, range: .monthK, calendar: calendar) == [0, 1, 2])
        #expect(PortfolioChartXAxis.label(for: dates[0], range: .dayK, calendar: calendar) == "12-31")
        #expect(PortfolioChartXAxis.label(for: dates[1], range: .weekK, calendar: calendar) == "1月")
        #expect(PortfolioChartXAxis.label(for: dates[1], range: .monthK, calendar: calendar) == "1月")
        #expect(PortfolioChartXAxis.label(for: dates[1], range: .quarterK, calendar: calendar) == "Q1")
        #expect(PortfolioChartXAxis.label(for: dates[1], range: .yearK, calendar: calendar) == "2026")
    }

    @Test func portfolioLongPeriodAxisUsesSparseUniqueNaturalTicks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = (2020...2026).flatMap { year in
            (1...12).compactMap { month in
                calendar.date(from: DateComponents(year: year, month: month, day: 1))
            }
        }
        let layout = PortfolioChartXAxis.layout(
            dates: dates,
            range: .monthK,
            calendar: calendar
        )

        #expect(layout.labelValues.count <= 5)
        #expect(layout.gridValues == layout.labelValues)
        #expect(Set(layout.labelTexts.values).count == layout.labelTexts.count)
        #expect(!layout.centersLabelsInIntervals)
    }

    @Test func holdingsCSVScopesPreserveHistoryAndOmitWatchOnly() {
        var held = StockHolding(market: .hongKong, symbol: "00700", name: "持有")
        held.transactions = [Self.transaction(type: .buy, day: 1, quantity: 2)]
        held.latestPrice = 12
        var closed = StockHolding(market: .unitedStates, symbol: "CLOSED")
        closed.transactions = [Self.transaction(type: .buy, day: 1, quantity: 1),
                               Self.transaction(type: .sell, day: 2, quantity: 1)]
        closed.archivedAt = Self.date(day: 3)
        let watch = StockHolding(market: .unitedStates, symbol: "WATCHONLY")
        let stocks = [held, closed, watch]
        let date = Self.date(day: 4)
        let current = String(decoding: StockHoldingsCSVExport.data(stocks: stocks, scope: .current, extendedHours: [:], at: date), as: UTF8.self)
        #expect(current.contains("\"00700\""))
        #expect(current.contains("\"24\""))
        #expect(!current.contains("CLOSED"))
        #expect(!current.contains("WATCHONLY"))
        let all = String(decoding: StockHoldingsCSVExport.data(stocks: stocks, scope: .all, extendedHours: [:], at: date), as: UTF8.self)
        #expect(all.contains("CLOSED"))
        #expect(all.contains("已存档"))
        #expect(!all.contains("WATCHONLY"))
        #expect(all.hasPrefix("\u{FEFF}"))
    }

    @Test func holdingsCSVEscapesNamesAndLeavesMissingQuoteBlank() {
        var stock = StockHolding(market: .unitedStates, symbol: "TEST", name: "=SUM(1,2)\n\"名称\"")
        stock.transactions = [Self.transaction(type: .buy, day: 1, quantity: 2)]
        let data = StockHoldingsCSVExport.data(stocks: [stock], scope: .current, extendedHours: [:], at: Self.date(day: 4))
        let csv = String(decoding: data, as: UTF8.self)
        #expect(csv.contains("\"'=SUM(1,2)\n\"\"名称\"\"\""))
        #expect(csv.contains("\"\",\"当前价格\",\"\",\"\",\"\""))
        #expect(csv.contains("移动加权平均"))
    }

    @Test func holdingsWorkbookSeparatesRawRecordsFromDerivedSummary() throws {
        var transaction = Self.transaction(type: .buy, day: 1, quantity: 2)
        transaction.unitPrice = Decimal(string: "12.34")!
        transaction.fees = Decimal(string: "0.56")!
        var dividend = StockDividend()
        dividend.receivedAt = Self.date(day: 2)
        dividend.quantity = 2
        dividend.dividendPerShare = Decimal(string: "0.8")!
        dividend.grossAmount = Decimal(string: "1.6")!
        dividend.withholdingTax = Decimal(string: "0.16")!
        dividend.fees = Decimal(string: "0.02")!
        dividend.note = "季度分红"
        var stock = StockHolding(market: .unitedStates, symbol: "TEST", name: "测试")
        stock.transactions = [transaction]
        stock.dividends = [dividend]
        stock.latestPrice = 15

        let data = StockHoldingsXLSXExport.data(
            stocks: [stock],
            scope: .all,
            extendedHours: [:],
            at: Self.date(day: 4)
        )
        let rawRows = try BillXLSXReader.worksheetRows(from: data)

        #expect(rawRows.first?.contains("记录类型") == true)
        #expect(rawRows.contains { $0.contains("交易") && $0.contains("12.34") && $0.contains("0.56") })
        #expect(rawRows.contains { $0.contains("分红") && $0.contains("0.16") && $0.contains("季度分红") })
        #expect(rawRows.first?.contains("持仓盈亏") == false)
        #expect(data.range(of: Data("持仓汇总".utf8)) != nil)
        #expect(data.range(of: Data("累计总收益".utf8)) != nil)
    }

    @Test func movingAverageMatchesRKLBExampleAndHistoricalCostWithoutChangingTransactions() throws {
        var first = Self.transaction(type: .buy, day: 1, quantity: 5)
        first.unitPrice = Decimal(string: "65.5")!
        first.fees = Decimal(string: "0.99")!
        var second = Self.transaction(type: .buy, day: 2, quantity: 10)
        second.unitPrice = 64
        second.fees = first.fees
        var sale = Self.transaction(type: .sell, day: 3, quantity: 5)
        sale.unitPrice = Decimal(string: "73.2")!
        sale.fees = first.fees
        var stock = StockHolding(market: .unitedStates, symbol: "RKLB")
        stock.transactions = [first, second, sale]
        stock.latestPrice = Decimal(string: "70.31")!
        let archived = try JSONEncoder().encode(stock)
        let restored = try JSONDecoder().decode(StockHolding.self, from: archived)
        let metrics = restored.metrics()
        #expect(metrics.performance.shares == 10)
        #expect(metrics.performance.holdingCost == Decimal(string: "646.32"))
        #expect(metrics.performance.averageHoldingCost == Decimal(string: "64.632"))
        #expect(metrics.performance.realizedTradeProfitLoss == Decimal(string: "41.85"))
        #expect(metrics.holdingProfitLoss == Decimal(string: "56.78"))
        #expect(metrics.totalProfitLoss == Decimal(string: "98.63"))
        #expect(PortfolioValueHistoryBuilder.holdingCost(for: restored, on: Self.date(day: 4)) == metrics.performance.holdingCost)
        #expect(restored.transactions == stock.transactions)
    }

    @Test func movingAveragePartialSalesAndLiquidationPreserveCost() {
        var first = Self.transaction(type: .buy, day: 1, quantity: 5)
        first.unitPrice = 10
        first.fees = 1
        var second = Self.transaction(type: .buy, day: 2, quantity: 10)
        second.unitPrice = 20
        second.fees = 2
        var sale = Self.transaction(type: .sell, day: 3, quantity: 3)
        sale.unitPrice = 30
        var ledger = StockMovingAverageCostLedger()
        ledger.apply(first); ledger.apply(second); ledger.apply(sale)
        #expect(abs(ledger.cost - Decimal(string: "202.4")!) < Decimal(string: "0.00000000000000000001")!)
        sale.quantity = 4
        ledger.apply(sale)
        #expect(ledger.shares == 8)
        #expect(abs(ledger.cost - Decimal(253) * 8 / 15) < Decimal(string: "0.00000000000000000001")!)
        sale.quantity = 8
        ledger.apply(sale)
        #expect(ledger.shares == 0)
        #expect(ledger.cost == 0)
        #expect(abs(ledger.realized - 197) < Decimal(string: "0.00000000000000000001")!)
        ledger.apply(first)
        #expect(ledger.cost == 51)
    }

    @Test @MainActor func overviewCurrencyPreferenceDefaultsToNativeAndPersistsLocally() {
        let name = "stock-appearance-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = StockAppearanceSettings(defaults: defaults)
        #expect(!settings.overviewUsesRenminbi)
        settings.overviewUsesRenminbi = true
        #expect(StockAppearanceSettings(defaults: defaults).overviewUsesRenminbi)
    }
    @Test func performanceCacheReusesLedgerAcrossQuoteTicksAndInvalidatesEdits() {
        var stock = StockHolding(symbol: "TEST")
        stock.transactions = [Self.transaction(type: .buy, day: 1, quantity: 2)]
        let now = Self.date(day: 3)
        var cache = StockPerformanceCache()
        let original = cache.performance(for: stock, at: now)
        for tick in 1...50 {
            stock.latestPrice = Decimal(tick)
            #expect(cache.performance(for: stock, at: now) == original)
        }
        #expect(cache.replayCount == 1)
        stock.transactions[0].quantity = 3
        #expect(cache.performance(for: stock, at: now).shares == 3)
        #expect(cache.replayCount == 2)
        stock.dividends = [StockDividend()]
        _ = cache.performance(for: stock, at: now)
        #expect(cache.replayCount == 3)
    }

    @Test func performanceCacheExpiresWhenFutureTransactionBecomesEffective() {
        let now = Self.date(day: 3)
        var stock = StockHolding(symbol: "TEST")
        var buy = Self.transaction(type: .buy, day: 3, quantity: 2)
        buy.tradedAt = now.addingTimeInterval(60)
        stock.transactions = [buy]
        var cache = StockPerformanceCache()
        #expect(cache.performance(for: stock, at: now).shares == 0)
        #expect(cache.performance(for: stock, at: now.addingTimeInterval(60)).shares == 2)
        #expect(cache.replayCount == 2)
    }
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

    @Test func transactionSettlementSeparatesGrossFeesAndCashFlow() {
        var buy = Self.transaction(type: .buy, day: 1, quantity: 20)
        buy.unitPrice = Decimal(string: "89.2")!
        buy.fees = Decimal(string: "0.05")!
        var sell = buy
        sell.type = .sell

        #expect(buy.grossAmount == 1_784)
        #expect(buy.buyTotalCost == Decimal(string: "1784.05")!)
        #expect(buy.cashFlow == Decimal(string: "1784.05")!)
        #expect(sell.grossAmount == 1_784)
        #expect(sell.sellNetProceeds == Decimal(string: "1783.95")!)
        #expect(sell.cashFlow == Decimal(string: "-1783.95")!)
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

    @Test func legacyTransactionWithoutExecutionTimeDecodesAsUnknown() throws {
        let json = #"{"id":"9E354B58-669A-4C65-A896-BD6474C2B98D","type":"buy","tradedAt":0,"quantity":1,"unitPrice":2,"fees":0}"#
        let transaction = try JSONDecoder().decode(
            StockTransaction.self,
            from: Data(json.utf8)
        )

        #expect(transaction.executedAt == nil)
        #expect(transaction.quantity == 1)
        #expect(transaction.unitPrice == 2)
    }

    @Test func savingConfirmedExecutionTimePreservesMinuteAndDropsSeconds() throws {
        var transaction = Self.transaction(type: .buy, day: 1, quantity: 1)
        transaction.executedAt = Self.date(day: 1).addingTimeInterval(10 * 3_600 + 23 * 60 + 47)

        let stock = try #require(StockPortfolioEditor.upserting(transaction, in: StockHolding()))
        let stored = try #require(stock.transactions.first)

        #expect(stored.executedAt?.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)
        #expect(stored.tradedAt == StockTransaction.normalizedDate(transaction.tradedAt))
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
        // CRUD is independent of the day-level normalization covered by
        // `savingDividendNormalizesItsDayLevelDate` below. Compare against the
        // same canonical business date that the editor persists.
        dividend.receivedAt = StockTransaction.normalizedDate(dividend.receivedAt)
        dividend.grossAmount = 10
        var stock = StockPortfolioEditor.upserting(dividend, in: StockHolding())

        dividend.grossAmount = 20
        stock = StockPortfolioEditor.upserting(dividend, in: stock)
        #expect(stock.dividends == [dividend])

        stock = StockPortfolioEditor.deletingDividends(ids: [dividend.id], from: stock)
        #expect(stock.dividends.isEmpty)
    }

    @Test func dividendCountsForItsWholeReceivedDayButNotEarlierDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let receivedAt = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 16,
            hour: 23,
            minute: 59
        ))!
        let sameDayMorning = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 16,
            hour: 8
        ))!
        let previousDay = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 15,
            hour: 23,
            minute: 59
        ))!
        var dividend = StockDividend()
        dividend.receivedAt = receivedAt
        dividend.grossAmount = 10
        dividend.withholdingTax = 2
        var stock = StockHolding()
        stock.dividends = [dividend]

        #expect(stock.netDividendIncome(asOf: previousDay, calendar: calendar) == 0)
        #expect(stock.netDividendIncome(asOf: sameDayMorning, calendar: calendar) == 8)
    }

    @Test func savingDividendNormalizesItsDayLevelDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        var dividend = StockDividend()
        dividend.receivedAt = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 16,
            hour: 23,
            minute: 45
        ))!

        let stock = StockPortfolioEditor.upserting(dividend, in: StockHolding())
        let saved = try #require(stock.dividends.first)

        #expect(calendar.component(.hour, from: saved.receivedAt) == 12)
        #expect(calendar.isDate(saved.receivedAt, inSameDayAs: dividend.receivedAt))
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

    @Test func todayProfitLossUsesRegularSessionMoveAndCurrentShares() {
        var stock = StockHolding(market: .unitedStates, symbol: "AAPL")
        stock.transactions = [Self.transaction(type: .buy, day: 1, quantity: 3)]
        stock.latestPrice = 12
        stock.previousClose = 10

        #expect(stock.todayProfitLoss == 6)
        #expect(StockPortfolioSummary(market: .unitedStates, stocks: [stock]).todayProfitLoss == 6)
    }

    @Test func convertedPortfolioSummaryKeepsFourHeadlineMetricsAligned() {
        var aShare = StockHolding(market: .aShare, symbol: "600000")
        aShare.transactions = [Self.transaction(type: .buy, day: 1, quantity: 1)]
        aShare.latestPrice = 12
        aShare.previousClose = 11

        var unitedStates = StockHolding(market: .unitedStates, symbol: "AAPL")
        unitedStates.transactions = [Self.transaction(type: .buy, day: 1, quantity: 2)]
        unitedStates.latestPrice = 12
        unitedStates.previousClose = 11

        let summary = StockConvertedPortfolioSummary(
            stocks: [aShare, unitedStates],
            multipliers: [.aShare: 1, .unitedStates: 7]
        )

        #expect(summary.marketValue == 180)
        #expect(summary.todayProfitLoss == 15)
        #expect(summary.holdingProfitLoss == 30)
        #expect(summary.totalProfitLoss == 30)
    }

    @Test func stockMetricsFormatOnlyAtDisplayBoundary() {
        #expect(StockValueFormatter.integerQuantity(1200) == "1,200")
        #expect(StockValueFormatter.signedPercent(Decimal(string: "-0.03456")!) == "-3.46%")
        #expect(StockValueFormatter.signedPercent(Decimal(string: "0.02344")!) == "+2.34%")
        #expect(StockValueFormatter.signedPriceDifference(Decimal(string: "0.00004")!, currencyCode: "USD").hasSuffix("0.00"))
        #expect(StockValueFormatter.signedPriceDifference(Decimal(string: "-0.00004")!, currencyCode: "USD").hasPrefix("+"))
        #expect(StockValueFormatter.signedPriceDifference(Decimal(string: "0.0012")!, currencyCode: "USD").hasSuffix("0.0012"))
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
