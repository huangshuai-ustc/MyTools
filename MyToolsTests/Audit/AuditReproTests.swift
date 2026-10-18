import Foundation
import Testing
@testable import MyTools

/// 审计复现测试：断言的是“预期正确行为”。尚未修复的问题包在
/// `withKnownIssue` 中，修复后该包装会因“未再复现”而失败，届时移除包装即可。
/// 目前所有复现项均已修复，不再有 `withKnownIssue`。
@MainActor
struct AuditReproTests {
#if MYTOOLS_FEATURE_FINANCE
    // AUDIT-005：other 类机构通过 accounts 写入的账户应保留在 other 载荷中。
    @Test func auditOtherInstitutionKeepsAccounts() throws {
        var institution = FinancialInstitution(kind: .other)
        var account = FinancialAccount()
        account.name = "其他账户"
        var child = FinancialAccount()
        child.name = "子账户"
        account.subaccounts = [child]
        institution.accounts = [account]
        #expect(institution.accounts.count == 1)
        #expect(institution.other?.accounts.count == 1)
        #expect(institution.bank == nil)
        #expect(institution.allAccounts.map(\.id) == [account.id, child.id])
        try institution.validate()

        let decoded = try JSONDecoder().decode(FinancialInstitution.self, from: JSONEncoder().encode(institution))
        #expect(decoded.accounts.map(\.name) == ["其他账户"])
    }

    // 支付币种账户支持多套资料，悬挂引用必须保留并由校验阻断。
    @Test func auditPaymentAccountKeepsMultipleReceivingProfilesPerAccount() {
        var institution = FinancialInstitution(kind: .payment)
        let account = PaymentAccount()
        institution.paymentAccounts = [account]
        let first = FinanceReceivingMethod(accountID: account.id)
        let second = FinanceReceivingMethod(accountID: account.id)
        let orphan = FinanceReceivingMethod(accountID: UUID())
        institution.receivingMethods = [first, second, orphan]
        #expect(institution.receivingMethods.map(\.id) == [first.id, second.id, orphan.id])
        #expect(institution.paymentAccounts.first?.receivingProfiles.map(\.id) == [first.id, second.id])
        #expect(throws: (any Error).self) { try institution.validate() }
        #expect(institution.paymentAccounts.first?.receivingProfile?.id == first.id)
    }
#endif

#if MYTOOLS_FEATURE_HEALTH
    // AUDIT-006：已裁决为“所选模块整体替换”，仅本地存在的记录不保留。
    @Test func auditBackupImportReplacesSelectedModuleWholesale() throws {
        var localRecord = MedicalRecord()
        localRecord.hospital = "仅本地"
        var importedRecord = MedicalRecord()
        importedRecord.hospital = "备份中"
        let merged = try AppStoreBackupMerger.merge(
            localVault: VaultData(medicalRecords: [localRecord]),
            localSecrets: [],
            imported: VaultBackupPayload(
                vault: VaultData(medicalRecords: [importedRecord]),
                includedModules: [.healthRecords]
            )
        )
        #expect(merged.vault.medicalRecords.map(\.id) == [importedRecord.id])
    }
#endif

#if MYTOOLS_FEATURE_STOCKS
    private func marketDate(_ market: StockMarket, _ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockChartSeriesProcessor.marketTimeZone(market)
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // AUDIT-013：元旦落在周六时 NYSE 不在前一周五休市（2021-12-31 为交易日）。
    @Test func auditUSNewYearSaturdayDoesNotCloseFriday() {
        #expect(StockMarketTradingCalendar.isTradingDay(.unitedStates, on: marketDate(.unitedStates, 2021, 12, 31)))
        // 其他周六节日仍提前到周五：2021-12-25 圣诞为周六，12-24 休市。
        #expect(!StockMarketTradingCalendar.isTradingDay(.unitedStates, on: marketDate(.unitedStates, 2021, 12, 24)))
    }

    // AUDIT-013：香港假日落在周六不补假（2023-07-01 周六，06-30 为交易日）。
    @Test func auditHongKongSaturdayHolidayDoesNotCloseFriday() {
        #expect(StockMarketTradingCalendar.isTradingDay(.hongKong, on: marketDate(.hongKong, 2023, 6, 30)))
        // 周日假日顺延到周一：2023-01-01 为周日，01-02 休市。
        #expect(!StockMarketTradingCalendar.isTradingDay(.hongKong, on: marketDate(.hongKong, 2023, 1, 2)))
    }

    // AUDIT-014：有官方休市表的年份不再叠加农历推算（2024-02-08 腊月廿九正常交易），
    // 但除夕仍休市（2024-02-09，holiday-cn 当年未标休）；
    // 没有官方表时，闰月里的同名日期不算节日（2028 闰五月初五 = 2028-06-27，周二）。
    @Test func auditAShareOfficialTableOverridesLunarRules() {
        let snapshot = AShareHolidaySnapshot()
        snapshot.update(holidayOverrides: [2024: [210, 211, 212, 213, 214, 215, 216, 217]])
        #expect(StockMarketTradingCalendar.isTradingDay(.aShare, on: marketDate(.aShare, 2024, 2, 8), snapshot: snapshot))
        #expect(!StockMarketTradingCalendar.isTradingDay(.aShare, on: marketDate(.aShare, 2024, 2, 9), snapshot: snapshot))
        let empty = AShareHolidaySnapshot()
        #expect(StockMarketTradingCalendar.isTradingDay(.aShare, on: marketDate(.aShare, 2028, 6, 27), snapshot: empty))
    }

    private func beijing(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        StockMarketClock.beijingCalendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func marketDay(_ market: StockMarket, _ year: Int, _ month: Int, _ day: Int) -> Date {
        StockChartSeriesProcessor.marketCalendar(market).date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func trade(_ type: StockTransactionType, on date: Date, at time: Date? = nil, quantity: Decimal, order: Int? = nil) -> StockTransaction {
        var value = StockTransaction()
        value.type = type
        value.tradedAt = StockTransaction.normalizedDate(date)
        value.executedAt = time
        value.dayOrder = order
        value.quantity = quantity
        value.unitPrice = 10
        return value
    }

    // AUDIT-091：北京日期 + 北京时刻组装成交时刻，再换算到市场交易日（夏令时/冬令时/港股/A 股）。
    @Test func auditExecutionTimeIsBeijingWallClock() throws {
        let summer = try #require(StockTransaction.executionInstant(tradingDate: beijing(2026, 10, 14), beijingTime: beijing(2026, 1, 1, 3, 30)))
        #expect(summer == utc("2026-10-13T19:30:00Z"))
        let winter = try #require(StockTransaction.executionInstant(tradingDate: beijing(2026, 1, 15), beijingTime: beijing(2026, 1, 1, 4, 30)))
        #expect(winter == utc("2026-01-14T20:30:00Z"))
        let us = StockMarketClock.marketLocalComponents(of: summer, market: .unitedStates)
        #expect([us.month, us.day, us.hour, us.minute] == [10, 13, 15, 30])
        #expect(StockMarketClock.marketBusinessDayStart(of: trade(.buy, on: beijing(2026, 10, 14), at: summer, quantity: 1), market: .unitedStates) == marketDay(.unitedStates, 2026, 10, 13))
        #expect(StockMarketClock.marketBusinessDayStart(of: trade(.buy, on: beijing(2026, 1, 15), at: winter, quantity: 1), market: .unitedStates) == marketDay(.unitedStates, 2026, 1, 14))
        let hk = try #require(StockTransaction.executionInstant(tradingDate: beijing(2026, 10, 13), beijingTime: beijing(2026, 1, 1, 10, 0)))
        let hkLocal = StockMarketClock.marketLocalComponents(of: hk, market: .hongKong)
        #expect([hkLocal.day, hkLocal.hour] == [13, 10])
        #expect(StockMarketClock.marketBusinessDayStart(of: trade(.buy, on: beijing(2026, 10, 13), at: hk, quantity: 1), market: .aShare) == marketDay(.aShare, 2026, 10, 13))
    }

    // AUDIT-092：冬令时美股只填日期的交易落在同一日期的美股交易日上。
    @Test func auditDateOnlyWinterUSTradeUsesSameDatedBar() {
        let buy = trade(.buy, on: beijing(2026, 1, 14), quantity: 1)
        let points = [13, 14, 15].map { day in
            StockChartPoint(date: marketDay(.unitedStates, 2026, 1, day).addingTimeInterval(16 * 3_600), open: 10, high: 10, low: 10, close: 10, volume: 1)
        }
        let placement = StockIntradayTransactionPlacement.resolve(transactions: [buy], points: points, market: .unitedStates)
        #expect(placement[buy.id]?.date == points[1].date)
    }

    // AUDIT-015：组合日线在交易所属市场交易日同时计入股数与成本。
    @Test func auditDailySeriesCountsSharesAndCostOnTheSameMarketDay() throws {
        let executed = try #require(StockTransaction.executionInstant(tradingDate: beijing(2026, 1, 15), beijingTime: beijing(2026, 1, 1, 4, 30)))
        var stock = StockHolding(market: .unitedStates, symbol: "NBIS")
        stock.transactions = [trade(.buy, on: beijing(2026, 1, 15), at: executed, quantity: 2)]
        let points = [13, 14, 15].map { day in
            StockChartPoint(date: marketDay(.unitedStates, 2026, 1, day).addingTimeInterval(16 * 3_600), open: 10, high: 10, low: 10, close: 10, volume: 1)
        }
        let series = PortfolioValueHistoryBuilder.buildSeries(for: .unitedStates, stocks: [stock], dailyPointsBySymbol: ["NBIS": points])
        let first = try #require(series.points.first)
        #expect(first.date == marketDay(.unitedStates, 2026, 1, 14))
        #expect(first.value == 20)
        #expect(series.costBasisPoints.first?.date == first.date)
        #expect(series.costBasisPoints.first?.cost == 20)
    }

    // AUDIT-093：同日卖出成交时间早于买入时，任意时刻的已生效持股都不能为负。
    @Test func auditSameDaySellBeforeBuyExecutionIsRejected() {
        let day = beijing(2026, 9, 1)
        var stock = StockHolding(market: .aShare, symbol: "600000")
        stock.transactions = [
            trade(.buy, on: day, at: beijing(2026, 9, 1, 10, 30), quantity: 10, order: 0),
            trade(.sell, on: day, at: beijing(2026, 9, 1, 9, 45), quantity: 5, order: 1)
        ]
        #expect(!stock.hasValidTransactionOrder)
        stock.transactions[1].executedAt = beijing(2026, 9, 1, 10, 45)
        #expect(stock.hasValidTransactionOrder)
    }

    // 同日带时间的买入之后、未填时间的卖出不早于该买入，不能按当天零点判为先卖。
    @Test func auditUntimedSellAfterTimedBuyOnSameDayIsValid() {
        let day = beijing(2026, 9, 1)
        var stock = StockHolding(market: .aShare, symbol: "600000")
        stock.transactions = [
            trade(.buy, on: day, at: beijing(2026, 9, 1, 10, 0), quantity: 10, order: 0),
            trade(.sell, on: day, quantity: 5, order: 1)
        ]
        #expect(stock.hasValidTransactionOrder)
        stock.transactions[1].quantity = 11
        #expect(!stock.hasValidTransactionOrder)
    }

    // AUDIT-016：只有日期的交易从北京日期零点起生效，与设备时区无关。
    @Test func auditDateOnlyTradeBecomesEffectiveAtBeijingMidnight() {
        let buy = trade(.buy, on: beijing(2026, 10, 14), quantity: 1)
        #expect(StockHolding.transactionIsEffective(buy, at: beijing(2026, 10, 14, 0, 0)))
        #expect(!StockHolding.transactionIsEffective(buy, at: beijing(2026, 10, 13, 23, 59)))
    }
#endif

    // AUDIT-022：DecimalTextParser 整串校验，带后缀的非法文本被拒绝（已修复）。
    @Test func auditDecimalParserRejectsTrailingText() {
        #expect(DecimalTextParser.decimal(from: "100元") == nil)
        #expect(DecimalTextParser.decimal(from: "12abc") == nil)
        #expect(DecimalTextParser.decimal(from: "1.2.3") == nil)
        #expect(DecimalTextParser.decimal(from: " 1,234.50 ") == Decimal(string: "1234.50"))
        #expect(DecimalTextParser.decimal(from: "-0.5") == Decimal(string: "-0.5"))
        #expect(DecimalTextParser.decimal(from: ".5") == Decimal(string: "0.5"))
        // 全角数字不是 ASCII 数字，不能只截取前缀解析（"1０0" → 1）。
        #expect(DecimalTextParser.decimal(from: "1０0") == nil)
        #expect(DecimalTextParser.decimal(from: "１００") == nil)
    }

#if MYTOOLS_FEATURE_DOCUMENTS
    // AUDIT-069：锁定状态下证照标题不显示持有人姓名。
    @Test func auditCredentialTitleMasksHolderWhenLocked() {
        var document = CredentialDocument()
        document.holderName = "张三"
        #expect(!document.displayTitle(revealsHolder: false).contains("张三"))
        #expect(document.displayTitle(revealsHolder: false).hasSuffix("-••••••"))
        #expect(document.displayTitle(revealsHolder: true).hasSuffix("-张三"))
        document.holderName = " "
        #expect(document.displayTitle(revealsHolder: false) == document.displayTitle(revealsHolder: true))
    }
#endif

    // AUDIT-089：表达式溢出得到 NaN 时视为无效输入。
    @Test func auditDecimalExpressionRejectsOverflow() {
        let big = String(repeating: "9", count: 40)
        let overflow = Array(repeating: big, count: 5).joined(separator: "*")
        #expect(DecimalTextParser.expression(from: overflow) == nil)
        #expect(DecimalTextParser.decimal(from: "1e999") == nil)
        #expect(DecimalTextParser.expression(from: "(1+2)×3") == 9)
    }

    // AUDIT-004：storedFileName 不可写出附件目录（已修复）。
    @Test func auditAttachmentStoreRejectsPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-attach-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("Attachments", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directoryURL: directory)
        var attachment = FileAttachment()
        attachment.storedFileName = "../escaped.bin"
        _ = try? store.write(Data([1, 2, 3]), to: attachment)
        let escaped = root.appendingPathComponent("escaped.bin")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }
}
