import Foundation
import Testing
@testable import MyTools

@MainActor
struct PartnershipTests {
#if MYTOOLS_FEATURE_PARTNERSHIP
    private final class ImportProvider: PartnershipStockImportProviding {
        var partnershipImportRecords: [PartnershipStockImportRecord]
        init(_ records: [PartnershipStockImportRecord]) { partnershipImportRecords = records }
    }

    private func makeStore() throws -> PartnershipStore {
        let store = PartnershipStore()
        try store.create(name: "合伙", manager: "我", partner: "对方", amounts: [9000, 1500], rate: Decimal(5) / 100)
        return store
    }

    // MARK: 出资比例与注资

    @Test func stockPurchaseFreezesSixToOneCashRatio() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        try store.recordStockPurchase(bookID: bookID, date: Date(timeIntervalSince1970: 1),
                                      symbol: "TEST", name: "测试股票", shares: 70, price: 100, fee: 0)
        let buy = try #require(store.books[0].records.first { $0.isPurchase })
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        #expect(buy.allocations.first { $0.memberID == investor }?.actual == 6000)
        #expect(buy.allocations.first { $0.memberID == partner }?.actual == 1000)
        #expect(PartnershipCalculator.stockSummary(store.books[0]).cash == 3500)
    }

    @Test func repeatedNonDivisiblePurchasesKeepTheSameExactCapitalSnapshot() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        let firstDate = Date(timeIntervalSince1970: 1)
        let secondDate = Date(timeIntervalSince1970: 2)

        try store.recordStockPurchase(bookID: bookID, date: firstDate, symbol: "ONE", name: "第一只",
                                      shares: 1, price: Decimal(string: "100.01")!, fee: 0)
        try store.recordStockPurchase(bookID: bookID, date: secondDate, symbol: "TWO", name: "第二只",
                                      shares: 1, price: Decimal(string: "200.02")!, fee: 0)

        let purchases = store.books[0].records.filter(\.isPurchase)
        #expect(purchases.count == 2)
        for purchase in purchases {
            #expect(purchase.frozenCapitalWeights.first { $0.memberID == investor }?.amount == 9000)
            #expect(purchase.frozenCapitalWeights.first { $0.memberID == partner }?.amount == 1500)
            #expect(purchase.allocations.reduce(Decimal.zero) { $0 + $1.actual } == purchase.cashAmount)
        }
        // Buying only moves value from cash to securities. It must not mutate
        // the authoritative 1:6 ownership weights used by the next purchase.
        let currentWeights = PartnershipCalculator.memberCapitalWeights(store.books[0])
        #expect(currentWeights.first { $0.memberID == investor }?.amount == 9000)
        #expect(currentWeights.first { $0.memberID == partner }?.amount == 1500)
    }

    @Test func proportionalContributionKeepsRatioThenSingleContributionShiftsIt() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        try store.contribute(bookID: bookID, amount: 700, memberID: nil, proportional: true)
        var summary = PartnershipCalculator.summary(store.books[0])
        #expect(summary.positions[0].capital == 9600)
        #expect(summary.positions[1].capital == 1600)
        try store.contribute(bookID: bookID, amount: 8000, memberID: store.books[0].members[1].id)
        summary = PartnershipCalculator.summary(store.books[0])
        #expect(summary.positions[0].capital == summary.positions[1].capital)
    }

    @Test func tinyProportionalContributionConservesCash() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        try store.addMember(bookID: bookID, name: "第三人", amount: 9000)
        let before = PartnershipCalculator.summary(store.books[0]).contributed
        try store.contribute(bookID: bookID, amount: Decimal(1) / 100, memberID: nil, proportional: true)
        let after = PartnershipCalculator.summary(store.books[0]).contributed
        #expect(after - before == Decimal(1) / 100)
        #expect(store.books[0].records.filter { $0.kind == .contribution }.allSatisfy { $0.amount > 0 })
    }
    // MARK: 卖出、收益池与分成

    @Test func stockSalesLinkToPurchaseAndSendAdjustedProfitToPool() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "TEST", name: "测试股票",
                                      shares: 70, price: 100, fee: 0)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 35, price: 120, fee: 0)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 35, price: 120, fee: 0)
        let book = store.books[0]
        let investor = book.members[0].id
        let partner = book.members[1].id
        let firstBuy = book.records.first(where: \.isPurchase)
        let sales = book.records.filter(\.isSale)
        #expect(sales.count == 2)
        #expect(sales.allSatisfy { $0.saleMatches.count == 1 })
        #expect(sales.allSatisfy { $0.parentRecordID == firstBuy?.id })
        let summary = PartnershipCalculator.stockSummary(book)
        #expect(summary.positions.isEmpty)
        #expect(summary.realizedProfit == 1400)
        let pool = summary.memberProfits
        #expect(pool.first { $0.memberID == investor }?.actual == 1210)
        #expect(pool.first { $0.memberID == partner }?.actual == 190)
    }

    @Test func sellReturnsOnlyPrincipalToAvailableCashProfitStaysInPool() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "TEST", name: "测试股票",
                                      shares: 70, price: 100, fee: 0)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 35, price: 120, fee: 0)
        let summary = PartnershipCalculator.stockSummary(store.books[0])
        // Only the matched principal (half of the 6000/1000 cost) returns to cash.
        #expect(summary.memberAvailableCash.first { $0.memberID == investor }?.actual == 6000)
        #expect(summary.memberAvailableCash.first { $0.memberID == partner }?.actual == 1000)
        #expect(summary.memberProfits.first { $0.memberID == investor }?.actual == 605)
        #expect(summary.memberProfits.first { $0.memberID == partner }?.actual == 95)
    }

    @Test func stockLossCompensatesPartnerAtConfiguredRate() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "TEST", name: "测试股票",
                                      shares: 70, price: 100, fee: 0)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 70, price: 80, fee: 0)
        let sale = try #require(store.books[0].records.last)
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        #expect(sale.allocations.first { $0.memberID == partner }?.actual == -190)
        #expect(sale.allocations.first { $0.memberID == investor }?.actual == -1210)
    }
    // MARK: 清账（重投 / 取回）

    @Test func settlementReinvestMovesPoolIntoAvailableCash() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "TEST", name: "测试股票",
                                      shares: 70, price: 100, fee: 0)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 70, price: 120, fee: 0)
        var summary = PartnershipCalculator.stockSummary(store.books[0])
        // Before settling: principal fully returned; profit only in the pool.
        #expect(summary.memberAvailableCash.first { $0.memberID == investor }?.actual == 9000)
        #expect(summary.memberAvailableCash.first { $0.memberID == partner }?.actual == 1500)
        #expect(summary.memberProfits.first { $0.memberID == investor }?.actual == 1210)
        #expect(summary.memberProfits.first { $0.memberID == partner }?.actual == 190)

        try store.settle(bookID: bookID, reinvest: [:]) // default 重投
        summary = PartnershipCalculator.stockSummary(store.books[0])
        #expect(summary.memberProfits.allSatisfy { $0.actual == 0 })
        #expect(summary.memberAvailableCash.first { $0.memberID == investor }?.actual == 10210)
        #expect(summary.memberAvailableCash.first { $0.memberID == partner }?.actual == 1690)
    }

    @Test func settlementTakeBackLeavesAvailableCashUnchanged() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "TEST", name: "测试股票",
                                      shares: 70, price: 100, fee: 0)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 70, price: 120, fee: 0)
        try store.settle(bookID: bookID, reinvest: [investor: false, partner: false]) // 取回
        let summary = PartnershipCalculator.stockSummary(store.books[0])
        #expect(summary.memberProfits.allSatisfy { $0.actual == 0 })
        #expect(summary.memberAvailableCash.first { $0.memberID == investor }?.actual == 9000)
        #expect(summary.memberAvailableCash.first { $0.memberID == partner }?.actual == 1500)
    }

    @Test func settlementReinvestChangesSubsequentBuyRatioWithoutTouchingHistory() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "ONE", name: "第一只",
                                      shares: 70, price: 100, fee: 0)
        let firstBuy = try #require(store.books[0].records.first { $0.isPurchase })
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "ONE", name: "第一只",
                                  shares: 70, price: 120, fee: 0)
        try store.settle(bookID: bookID, reinvest: [:]) // 重投，可用资金变为 10210 / 1690
        try store.recordStockPurchase(bookID: bookID, date: .now, symbol: "TWO", name: "第二只",
                                      shares: 119, price: 100, fee: 0)
        let book = store.books[0]
        let reinvestment = try #require(book.records.last { $0.isPurchase })
        #expect(reinvestment.allocations.first { $0.memberID == investor }?.actual == 10210)
        #expect(reinvestment.allocations.first { $0.memberID == partner }?.actual == 1690)
        // 历史买入冻结比例保持不变。
        #expect(book.records.first { $0.id == firstBuy.id }?.allocations == firstBuy.allocations)
    }
    // MARK: FIFO、撤销与校验

    @Test func automaticSaleAcrossPurchasesCreatesChildrenUnderEachPurchase() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "TEST", name: "测试股票",
                                      shares: 10, price: 100, fee: 0)
        try store.recordStockPurchase(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                      shares: 10, price: 100, fee: 0)
        let purchases = store.books[0].records.filter(\.isPurchase)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 15, price: 110, fee: 3)
        let sales = store.books[0].records.filter(\.isSale)
        #expect(sales.count == 2)
        #expect(Set(sales.compactMap(\.parentRecordID)) == Set(purchases.map(\.id)))
        #expect(Set(sales.compactMap(\.operationID)).count == 1)
        try store.undoLatestChange(bookID: bookID)
        #expect(store.books[0].records.filter(\.isSale).isEmpty)
    }

    @Test func withdrawalLimitedToAvailableCashUntilSettled() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let partner = store.books[0].members[1].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, symbol: "TEST", name: "测试股票",
                                      shares: 70, price: 100, fee: 0)
        try store.recordStockSale(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                  shares: 70, price: 120, fee: 0)
        try store.withdraw(bookID: bookID, amount: 1500, memberID: partner) // 可用现金归零
        #expect(throws: PartnershipError.self) {
            try store.withdraw(bookID: bookID, amount: 1, memberID: partner) // 收益尚未清账
        }
        try store.settle(bookID: bookID, reinvest: [:])
        try store.withdraw(bookID: bookID, amount: 190, memberID: partner)
        let cash = PartnershipCalculator.stockSummary(store.books[0]).memberAvailableCash
        #expect(cash.first { $0.memberID == partner }?.actual == 0)
    }

    @Test func withdrawalCannotUseMoneyStillInvestedInHoldings() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let partner = store.books[0].members[1].id
        try store.recordStockPurchase(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                      shares: 70, price: 100, fee: 0)
        #expect(throws: PartnershipError.self) {
            try store.withdraw(bookID: bookID, amount: 600, memberID: partner)
        }
    }

    @Test func tradeMoneyMustUseCentPrecisionAndSalesCannotPrecedePurchases() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        #expect(throws: PartnershipError.self) {
            try store.recordStockPurchase(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                          shares: 1, price: Decimal(string: "1.001")!, fee: 0)
        }
        let purchaseDate = Date(timeIntervalSince1970: 10_000)
        try store.recordStockPurchase(bookID: bookID, date: purchaseDate, symbol: "TEST", name: "测试股票",
                                      shares: 1, price: 100, fee: 0)
        #expect(throws: PartnershipError.self) {
            try store.recordStockSale(bookID: bookID, date: Date(timeIntervalSince1970: 9_999), symbol: "TEST",
                                      name: "测试股票", shares: 1, price: 100, fee: 0)
        }
    }
    // MARK: 股息、导入、审计日志

    @Test func dividendFreezesHoldingOwnershipAndSendsNetToPool() throws {
        let store = PartnershipStore()
        try store.create(name: "美股", manager: "我", partner: "对方", amounts: [900, 100], rate: Decimal(5) / 100)
        let bookID = store.books[0].id
        let manager = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        try store.recordStockPurchase(bookID: bookID, date: .distantPast, market: .unitedStates,
                                      symbol: "ABC", name: "示例", shares: 10, price: 100, fee: 0)
        try store.recordDividend(bookID: bookID, date: .now, market: .unitedStates, symbol: "ABC", name: "示例",
                                 grossAmount: 100, withholdingTax: 10, fee: 0)
        let dividend = try #require(store.books[0].records.first { $0.kind == .dividend })
        #expect(dividend.dividendNet == 90)
        #expect(dividend.allocations.first { $0.memberID == manager }?.actual == 81)
        #expect(dividend.allocations.first { $0.memberID == partner }?.actual == 9)
        let summary = PartnershipCalculator.stockSummary(store.books[0])
        #expect(summary.cash == 0) // 净额进收益池，不进可用资金
        #expect(summary.realizedProfit == 90)
        #expect(summary.memberProfits.first { $0.memberID == manager }?.actual == 81)
        #expect(summary.memberProfits.first { $0.memberID == partner }?.actual == 9)
    }

    @Test func auditLogRecordsEachChange() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        #expect(store.books[0].auditLog.count == 1) // 创建
        try store.recordStockPurchase(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                      shares: 10, price: 100, fee: 0)
        #expect(store.books[0].auditLog.count == 2)
        try store.undoLatestChange(bookID: bookID)
        #expect(store.books[0].auditLog.count == 3)
        #expect(store.books[0].auditLog.last?.action.contains("撤销") == true)
    }

    @Test func importIsAtomicAndUndoRevertsTheWholeImport() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let badProvider = ImportProvider([
            .init(id: UUID(), market: .unitedStates, symbol: "ONE", name: "第一只", side: .buy,
                  date: .distantPast, shares: 10, price: 100, fee: 0),
            .init(id: UUID(), market: .unitedStates, symbol: "ONE", name: "第一只", side: .sell,
                  date: .now, shares: 20, price: 100, fee: 0)
        ])
        store.attach(stockImportProvider: badProvider)
        #expect(throws: PartnershipError.self) {
            try store.importStockRecords(bookID: bookID, ids: Set(badProvider.partnershipImportRecords.map(\.id)))
        }
        #expect(store.books[0].records.filter { $0.kind == .buy || $0.kind == .sell }.isEmpty)

        let provider = ImportProvider([
            .init(id: UUID(), market: .unitedStates, symbol: "ONE", name: "第一只", side: .buy,
                  date: .distantPast, shares: 10, price: 100, fee: 0),
            .init(id: UUID(), market: .unitedStates, symbol: "TWO", name: "第二只", side: .buy,
                  date: .now, shares: 10, price: 100, fee: 0)
        ])
        store.attach(stockImportProvider: provider)
        try store.importStockRecords(bookID: bookID, ids: Set(provider.partnershipImportRecords.map(\.id)))
        #expect(store.books[0].records.filter(\.isPurchase).count == 2)
        try store.undoLatestChange(bookID: bookID)
        #expect(store.books[0].records.filter(\.isPurchase).isEmpty)
    }

    @Test func batchImportFreezesEachPurchaseSnapshotAndSourceIdentity() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        let investor = store.books[0].members[0].id
        let partner = store.books[0].members[1].id
        let records = [
            PartnershipStockImportRecord(id: UUID(), market: .unitedStates, symbol: "ONE", name: "第一只", side: .buy,
                                         date: Date(timeIntervalSince1970: 1), shares: 1,
                                         price: Decimal(string: "100.01")!, fee: 0),
            PartnershipStockImportRecord(id: UUID(), market: .unitedStates, symbol: "TWO", name: "第二只", side: .buy,
                                         date: Date(timeIntervalSince1970: 2), shares: 1,
                                         price: Decimal(string: "200.02")!, fee: 0)
        ]
        let provider = ImportProvider(records)
        store.attach(stockImportProvider: provider)
        try store.importStockRecords(bookID: bookID, ids: Set(records.map(\.id)))

        let purchases = store.books[0].records.filter(\.isPurchase)
        #expect(Set(purchases.compactMap(\.sourceRecordID)) == Set(records.map(\.id)))
        #expect(store.importCandidates(bookID: bookID).isEmpty)
        for purchase in purchases {
            #expect(purchase.frozenCapitalWeights.first { $0.memberID == investor }?.amount == 9000)
            #expect(purchase.frozenCapitalWeights.first { $0.memberID == partner }?.amount == 1500)
            #expect(purchase.allocations.reduce(Decimal.zero) { $0 + $1.actual } == purchase.cashAmount)
        }
    }

    @Test func recordWithoutCapitalSnapshotStillDecodes() throws {
        let record = PartnershipRecord(kind: .buy, symbol: "LEGACY", name: "旧记录", shares: 1, price: 1)
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "capitalWeightSnapshot")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PartnershipRecord.self, from: legacyData)
        #expect(decoded.symbol == "LEGACY")
        #expect(decoded.frozenCapitalWeights.isEmpty)
    }

    @Test func cancellingUndoRestoresTheLatestChange() throws {
        let store = try makeStore()
        let bookID = store.books[0].id
        try store.recordStockPurchase(bookID: bookID, date: .now, symbol: "TEST", name: "测试股票",
                                      shares: 10, price: 100, fee: 0)
        try store.undoLatestChange(bookID: bookID)
        #expect(store.books[0].records.filter(\.isPurchase).isEmpty)
        #expect(store.canCancelUndo(bookID: bookID))
        try store.cancelUndoLatestChange(bookID: bookID)
        #expect(store.books[0].records.filter(\.isPurchase).count == 1)
        #expect(!store.canCancelUndo(bookID: bookID))
    }
    // MARK: 旧数据迁移、持久化与模块显隐

    @Test func legacyThreeStreamJSONMigratesIntoUnifiedRecords() throws {
        let m1 = "00000000-0000-0000-0000-000000000001"
        let m2 = "00000000-0000-0000-0000-000000000002"
        let json = Data("""
        {
          "id": "00000000-0000-0000-0000-0000000000AA",
          "name": "旧账本",
          "type": "stockInvestment",
          "adjustmentRate": 0.05,
          "members": [
            {"id": "\(m1)", "name": "我", "isManager": true},
            {"id": "\(m2)", "name": "对方", "isManager": false}
          ],
          "entries": [
            {"id": "00000000-0000-0000-0000-0000000000E1", "kind": "contribution", "amount": 9000, "memberID": "\(m1)"},
            {"id": "00000000-0000-0000-0000-0000000000E2", "kind": "contribution", "amount": 1500, "memberID": "\(m2)"},
            {"id": "00000000-0000-0000-0000-0000000000E3", "kind": "valuation", "amount": 12000, "memberID": null},
            {"id": "00000000-0000-0000-0000-0000000000E4", "kind": "profitSettlement", "amount": 0,
             "allocations": [
               {"memberID": "\(m1)", "base": 300, "adjustment": 0, "actual": 300},
               {"memberID": "\(m2)", "base": 50, "adjustment": 0, "actual": 50}
             ]}
          ],
          "stockTrades": [
            {"id": "00000000-0000-0000-0000-0000000000B1", "side": "buy", "market": "unitedStates",
             "symbol": "TEST", "name": "测试", "shares": 70, "price": 100, "fee": 0,
             "allocations": [
               {"memberID": "\(m1)", "base": 6000, "adjustment": 0, "actual": 6000},
               {"memberID": "\(m2)", "base": 1000, "adjustment": 0, "actual": 1000}
             ]}
          ],
          "dividends": []
        }
        """.utf8)
        let book = try JSONDecoder().decode(PartnershipBook.self, from: json)
        // 注资 x2、买入 x1、清账 x1；净值/valuation 记录被丢弃。
        #expect(book.records.count == 4)
        #expect(book.records.filter { $0.kind == .contribution }.count == 2)
        #expect(book.records.contains { $0.kind == .buy })
        #expect(book.records.contains { $0.kind == .settlement })
        #expect(!book.records.contains { $0.kind == .withdrawal })
        let summary = PartnershipCalculator.stockSummary(book)
        #expect(summary.positions.first?.shares == 70)
        // 可用资金：注资 10500 − 买入冻结 7000 + 清账重投 350 = 3850。
        #expect(summary.cash == 3850)
    }

    @Test func defaultOffAndExplicitChoiceSurvivesReload() throws {
        let defaults = try #require(UserDefaults(suiteName: "PartnershipTests.\(UUID())"))
        let settings = ToolModuleSettings(defaults: defaults)
        #expect(!settings.isVisible(.partnership))
        settings.setVisible(true, for: .partnership)
        #expect(ToolModuleSettings(defaults: defaults).isVisible(.partnership))
        settings.setVisible(false, for: .partnership)
        #expect(!ToolModuleSettings(defaults: defaults).isVisible(.partnership))
    }

    @Test func persistenceCloudAndBackupRoundTrip() async throws {
        let store = try makeStore()
        try store.recordStockPurchase(bookID: store.books[0].id, date: .distantPast, symbol: "TEST",
                                      name: "测试股票", shares: 70, price: 100, fee: 0)
        let book = store.books[0]
        let vault = VaultData(partnershipBooks: [book])
        let decoded = try JSONDecoder().decode(VaultData.self, from: JSONEncoder().encode(vault))
        #expect(decoded.partnershipBooks == [book])
        let legacy = try JSONDecoder().decode(VaultData.self, from: Data("{}".utf8))
        #expect(legacy.partnershipBooks.isEmpty)
        let snapshot = try CloudSyncSnapshotBuilder.make(vault: vault, secrets: [], attachmentStore: AttachmentStore(), enabledModules: [.partnership])
        #expect(snapshot.items.count == 1)
        let changes = snapshot.items.map { CloudSyncChange.upsert(kind: $0.kind, id: $0.id, payload: $0.payload) }
        let merged = try CloudSyncMerger.apply(changes, to: VaultData(), secrets: [], enabledModules: [.partnership])
        #expect(merged.vault.partnershipBooks == [book])
        let deleted = try CloudSyncMerger.apply([.delete(kind: .partnershipBook, id: book.id)], to: vault, secrets: [], enabledModules: [.partnership])
        #expect(deleted.vault.partnershipBooks.isEmpty)
        let ignored = try CloudSyncMerger.apply(changes, to: VaultData(), secrets: [], enabledModules: [])
        #expect(ignored.vault.partnershipBooks.isEmpty)
        let processor = AppStoreBackupProcessor()
        for included: Set<ToolModule> in [[], [.partnership]] {
            let bytes = try await processor.makeBackup(vault: vault, secrets: [], includedModules: included, password: "test-password")
            let restored = try await processor.restorePayload(from: bytes, password: "test-password")
            #expect(restored.vault.partnershipBooks == (included.isEmpty ? [] : [book]))
        }
        let imported = VaultBackupPayload(vault: vault, includedModules: [.partnership])
        let restored = AppStoreBackupMerger.merge(localVault: VaultData(), localSecrets: [], imported: imported)
        #expect(restored.vault.partnershipBooks == [book])
    }
#else
    @Test func excludedModuleRetainsOpaqueVaultButDoesNotRegisterOrSync() throws {
        let json = Data(#"{"partnershipBooks":[{"id":"foreign","future":{"amount":123.45}}]}"#.utf8)
        let vault = try JSONDecoder().decode(VaultData.self, from: json)
        let decoded = try JSONDecoder().decode(VaultData.self, from: JSONEncoder().encode(vault))
        #expect(vault.partnershipBooks == decoded.partnershipBooks)
        #expect(!CompiledToolModules.contains(.partnership))
        let snapshot = try CloudSyncSnapshotBuilder.make(vault: vault, secrets: [], attachmentStore: AttachmentStore())
        #expect(!snapshot.items.contains { $0.kind == .partnershipBook })
    }
#endif
}
