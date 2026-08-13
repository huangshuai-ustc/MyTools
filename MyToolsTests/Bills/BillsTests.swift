#if MYTOOLS_FEATURE_BILLS
import CoreFoundation
import Foundation
import Testing
@testable import MyTools

@MainActor
struct BillsTests {
    @Test func storeNormalizesManualRecordsAndSortsNewestFirst() throws {
        let earlierDate = Date(timeIntervalSince1970: 1_000)
        let laterDate = Date(timeIntervalSince1970: 2_000)
        let store = BillsStore()
        store.upsert(BillRecord(
            occurredAt: earlierDate,
            amount: 12.5,
            merchant: "  咖啡店  ",
            tags: [" 餐饮 ", "餐饮", "  "]
        ))
        store.upsert(BillRecord(occurredAt: laterDate, amount: 8, merchant: "便利店"))

        #expect(store.records.map(\.merchant) == ["便利店", "咖啡店"])
        #expect(store.records.last?.tags == ["餐饮"])
        #expect(store.total(direction: .expense, in: earlierDate) == 20.5)
    }

    @Test func monthlyAnalyticsSeparatesCurrenciesAndExcludesCancelledTransactions() {
        let august = Self.date(year: 2026, month: 8, day: 15, hour: 12, minute: 0, second: 0)
        let records = [
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 2, hour: 8, minute: 0, second: 0),
                direction: .expense,
                amount: 100,
                merchant: "早餐店",
                paymentMethod: "支付宝",
                category: .dining
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 2, hour: 18, minute: 0, second: 0),
                direction: .expense,
                amount: 50,
                merchant: "地铁",
                paymentMethod: "微信支付",
                category: .transport
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 3, hour: 9, minute: 0, second: 0),
                direction: .refund,
                amount: 20,
                merchant: "早餐店",
                category: .refund
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 4, hour: 9, minute: 0, second: 0),
                direction: .income,
                amount: 300,
                category: .salary
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 5, hour: 9, minute: 0, second: 0),
                direction: .neutral,
                amount: 10,
                category: .transfer
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 6, hour: 9, minute: 0, second: 0),
                direction: .expense,
                amount: 999,
                status: .cancelled
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 7, hour: 9, minute: 0, second: 0),
                direction: .expense,
                amount: 200,
                currency: .usd
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 8, hour: 9, minute: 0, second: 0),
                direction: .expense,
                amount: 0,
                merchant: "零元商户",
                paymentMethod: "优惠券",
                category: .shopping
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 7, day: 10, hour: 9, minute: 0, second: 0),
                direction: .expense,
                amount: 40,
                merchant: "上月商户"
            )
        ]

        let snapshot = BillAnalyticsCalculator.snapshot(
            records: records,
            month: august,
            currency: .cny,
            calendar: Self.calendar
        )

        #expect(snapshot.transactionCount == 6)
        #expect(snapshot.neutralCount == 1)
        #expect(snapshot.expense == 150)
        #expect(snapshot.income == 300)
        #expect(snapshot.refund == 20)
        #expect(snapshot.netExpense == 130)
        #expect(snapshot.balance == 170)
        #expect(snapshot.dailyTotals.count == 3)
        #expect(snapshot.categoryTotals.map(\.category) == [.dining, .transport])
        #expect(snapshot.merchantTotals.map(\.name) == ["早餐店", "地铁"])
        #expect(snapshot.paymentMethodTotals.map(\.name) == ["支付宝", "微信支付"])

        let previous = BillAnalyticsCalculator.snapshot(
            records: records,
            month: BillAnalyticsCalculator.previousMonth(before: august, calendar: Self.calendar),
            currency: .cny,
            calendar: Self.calendar
        )
        #expect(previous.expense == 40)
    }

    @Test func analyticsPeriodsBuildExpectedIntervalsAndComparisons() {
        let calendar = Self.calendar
        let date = Self.date(year: 2026, month: 8, day: 12, hour: 10, minute: 20, second: 30)

        let week = BillAnalyticsCalculator.interval(for: .week, containing: date, calendar: calendar)
        #expect(week.duration == 7 * 24 * 60 * 60)

        let month = BillAnalyticsCalculator.interval(for: .month, containing: date, calendar: calendar)
        #expect(calendar.component(.day, from: month.start) == 1)
        #expect(calendar.component(.month, from: month.end) == 9)

        let quarter = BillAnalyticsCalculator.interval(for: .quarter, containing: date, calendar: calendar)
        #expect(calendar.component(.month, from: quarter.start) == 7)
        #expect(calendar.component(.month, from: quarter.end) == 10)

        let year = BillAnalyticsCalculator.interval(for: .year, containing: date, calendar: calendar)
        #expect(calendar.component(.month, from: year.start) == 1)
        #expect(calendar.component(.month, from: year.end) == 1)
        #expect(calendar.component(.year, from: year.end) == 2027)

        let custom = BillAnalyticsCalculator.customInterval(
            start: Self.date(year: 2026, month: 8, day: 10, hour: 18, minute: 0, second: 0),
            end: Self.date(year: 2026, month: 8, day: 12, hour: 8, minute: 0, second: 0),
            calendar: calendar
        )
        #expect(calendar.component(.day, from: custom.start) == 10)
        #expect(calendar.component(.day, from: custom.end) == 13)
        #expect(BillAnalyticsCalculator.previousInterval(before: custom, period: .custom, calendar: calendar) == nil)

        let previousQuarter = BillAnalyticsCalculator.previousInterval(
            before: quarter,
            period: .quarter,
            calendar: calendar
        )
        #expect(previousQuarter.map { calendar.component(.month, from: $0.start) } == 4)
        #expect(previousQuarter.map { calendar.component(.month, from: $0.end) } == 7)
    }

    @Test func ocrParserPrefersLabeledAmountAndExtractsPaymentDetails() throws {
        let result = OCRResult(lines: [
            Self.line("麦当劳北京王府井店", y: 0.1),
            Self.line("微信支付", y: 0.2),
            Self.line("订单金额 ¥48.00", y: 0.3),
            Self.line("优惠 ¥5.00", y: 0.4),
            Self.line("实付金额 ¥43.00", y: 0.5),
            Self.line("交易时间 2026-08-11 12:34:56", y: 0.6)
        ])

        let suggestion = BillOCRParser.parse(result, calendar: Self.calendar)

        #expect(suggestion.amountCandidates.first?.amount == 43)
        #expect(suggestion.merchant == "麦当劳北京王府井店")
        #expect(suggestion.paymentMethod == "微信支付")
        #expect(suggestion.direction == BillDirection.expense)
        #expect(suggestion.occurredAt == Self.date(year: 2026, month: 8, day: 11, hour: 12, minute: 34, second: 56))
    }

    @Test func ocrParserDoesNotTreatPaymentChannelOrPayeeLabelAsIncome() throws {
        let result = OCRResult(lines: [
            Self.line("微信支付", y: 0.1),
            Self.line("支付成功", y: 0.2),
            Self.line("收款方：星巴克咖啡", y: 0.3),
            Self.line("实付金额 ¥38.00", y: 0.4)
        ])

        let suggestion = BillOCRParser.parse(result, calendar: Self.calendar)

        #expect(suggestion.direction == BillDirection.expense)
        #expect(suggestion.merchant == "星巴克咖啡")
        #expect(suggestion.amountCandidates.first?.amount == 38)
    }

    @Test func exchangeJSONRoundTripsAndRepeatedExternalImportUpdates() throws {
        let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        var transaction = Self.exchangeTransaction(id: "wx-100", amount: 20, occurredAt: occurredAt)
        let source = BillExchangeSource(
            providerIdentifier: "wechat",
            providerName: "微信支付",
            schemaVersion: "sample-v1"
        )
        var document = BillExchangeDocument(source: source, transactions: [transaction])
        let data = try BillExchangeCoding.encoder(prettyPrinted: true).encode(document)
        let decoded = try BillImportAdapterRegistry().decode(data: data, fileName: "bills.json")
        let store = BillsStore()

        let first = try store.importExchange(decoded)
        transaction.amount = 25
        document.transactions = [transaction]
        let second = try store.importExchange(document)

        #expect(first == BillImportOutcome(insertedCount: 1, updatedCount: 0))
        #expect(second == BillImportOutcome(insertedCount: 0, updatedCount: 1))
        #expect(store.records.count == 1)
        #expect(store.records.first?.amount == 25)
        #expect(store.records.first?.origin.externalTransactionID == "wx-100")
        #expect(decoded.version == 2)
    }

    @Test func exportFilterSupportsPresetCustomSourceCategoryAndDirection() throws {
        let now = Self.date(year: 2026, month: 8, day: 12, hour: 12, minute: 0, second: 0)
        let wechat = BillOrigin(
            kind: .imported,
            providerIdentifier: "com.tencent.wechatpay",
            providerName: "微信支付",
            externalTransactionID: "wx-1",
            importedAt: now,
            rawFields: [:]
        )
        let records = [
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 8, day: 1, hour: 8, minute: 0, second: 0),
                direction: .expense,
                amount: 20,
                category: .dining,
                origin: wechat
            ),
            BillRecord(
                occurredAt: Self.date(year: 2026, month: 7, day: 1, hour: 8, minute: 0, second: 0),
                direction: .expense,
                amount: 30,
                category: .transport,
                origin: wechat
            ),
            BillRecord(
                occurredAt: Self.date(year: 2025, month: 7, day: 1, hour: 8, minute: 0, second: 0),
                direction: .income,
                amount: 100,
                category: .salary
            )
        ]

        let recent = BillExportFilter(
            period: .oneMonth,
            customStart: now,
            customEnd: now
        ).records(from: records, calendar: Self.calendar, now: now)
        #expect(recent.count == 1)
        #expect(recent.first?.category == .dining)

        let filtered = BillExportFilter(
            period: .custom,
            customStart: Self.date(year: 2026, month: 6, day: 1, hour: 0, minute: 0, second: 0),
            customEnd: now,
            providerName: "微信支付",
            category: .transport,
            direction: .expense
        ).records(from: records, calendar: Self.calendar, now: now)
        #expect(filtered.count == 1)
        #expect(filtered.first?.amount == 30)

        let invalidRange = BillExportFilter(
            period: .custom,
            customStart: now,
            customEnd: Self.date(year: 2026, month: 7, day: 1, hour: 0, minute: 0, second: 0)
        ).records(from: records, calendar: Self.calendar, now: now)
        #expect(invalidRange.isEmpty)
    }

    @Test func alipayGB18030CSVSkipsSummaryAndMapsPlatformFields() throws {
        let csv = """
        导出信息：
        姓名：测试用户
        共3笔记录
        交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注
        2026-08-11 17:37:37,餐饮美食,测试餐厅,/,"咖啡,大杯",支出,31.80,银行卡(1234),交易成功,ali-001\t,merchant-001\t,
        2026-08-10 10:20:30,退款,测试餐厅,/,退款,不计收支,12.50,账户余额,退款成功,ali-002\t,,原路退回
        2026-08-09 12:00:00,家居家装,测试商户,/,优惠券全额抵扣商品,支出,0.00,,支付成功,ali-003\t,merchant-003\t,
        """
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        // Alipay currently uses CRLF before the table and LF for transaction rows.
        let mixedLineEndings = csv
            .split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
            .joined(separator: "\r\n")
        let data = try #require(mixedLineEndings.data(using: encoding))
        let document = try BillImportAdapterRegistry().decode(data: data, fileName: "支付宝交易明细.csv")
        let records = try BillExchangeMapper.records(from: document)

        #expect(document.source.providerIdentifier == "com.alipay")
        #expect(document.transactions.count == 3)
        #expect(document.transactions.first?.itemDescription == "咖啡,大杯")
        #expect(records.first?.direction == .expense)
        #expect(records.first?.category == .dining)
        #expect(records.first?.counterparty == "测试餐厅")
        #expect(records.first?.counterpartyAccount.isEmpty == true)
        #expect(records.first?.merchantTransactionID == "merchant-001")
        let refund = records.first { $0.origin.externalTransactionID == "ali-002" }
        #expect(refund?.direction == .refund)
        #expect(refund?.status == .refunded)
        #expect(records.contains { $0.origin.externalTransactionID == "ali-003" && $0.amount == 0 })
        #expect(records.allSatisfy { $0.origin.rawFields["姓名"] == nil })
    }

    @Test func wechatXLSXSkipsSummaryAndMapsNeutralTransaction() throws {
        let headers = [
            "交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)",
            "支付方式", "当前状态", "交易单号", "商户单号", "备注"
        ]
        let values = [
            "", "零钱提现", "测试银行", "/", "/", "", "零钱", "提现已到账",
            "wx-001", "merchant-001", "/"
        ]
        let data = Self.makeStoredXLSX(headers: headers, values: values, excelDate: "46245.43351851852", amount: "2500")
        let document = try BillImportAdapterRegistry().decode(data: data, fileName: "微信支付账单.xlsx")
        let records = try BillExchangeMapper.records(from: document)
        let record = try #require(records.first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: record.occurredAt)

        #expect(document.source.providerIdentifier == "com.tencent.wechatpay")
        #expect(records.count == 1)
        #expect(record.direction == .neutral)
        #expect(record.category == .transfer)
        #expect(record.amount == 2500)
        #expect(record.providerTransactionType == "零钱提现")
        #expect(record.accountHint == "零钱")
        #expect(record.origin.rawFields["共1笔记录"] == nil)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 11)
        #expect(components.hour == 10)
        #expect(components.minute == 24)
        #expect(components.second == 16)
    }

    @Test func bankCSVStillWaitsForProviderSpecificSchema() throws {
        let registry = BillImportAdapterRegistry()

        #expect(throws: BillImportError.schemaSampleRequired("银行卡 CSV")) {
            try registry.decode(
                data: Data("记账日期,交易金额,摘要".utf8),
                fileName: "bank.csv"
            )
        }
    }

    @Test func providedPlatformSamplesDecodeWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let wechatPath = environment["MYTOOLS_WECHAT_BILL_SAMPLE"],
              let alipayPath = environment["MYTOOLS_ALIPAY_BILL_SAMPLE"] else { return }
        let wechat = try BillImportAdapterRegistry().decode(
            data: Data(contentsOf: URL(fileURLWithPath: wechatPath)),
            fileName: URL(fileURLWithPath: wechatPath).lastPathComponent
        )
        let alipay = try BillImportAdapterRegistry().decode(
            data: Data(contentsOf: URL(fileURLWithPath: alipayPath)),
            fileName: URL(fileURLWithPath: alipayPath).lastPathComponent
        )

        #expect(wechat.transactions.count == 39)
        #expect(alipay.transactions.count == 173)
        #expect(wechat.transactions.count { $0.direction == BillDirection.expense.rawValue } == 22)
        #expect(wechat.transactions.count { $0.direction == BillDirection.income.rawValue } == 4)
        #expect(wechat.transactions.count { $0.direction == BillDirection.refund.rawValue } == 1)
        #expect(wechat.transactions.count { $0.direction == BillDirection.neutral.rawValue } == 12)
        #expect(alipay.transactions.count { $0.direction == BillDirection.expense.rawValue } == 93)
        #expect(alipay.transactions.count { $0.direction == BillDirection.income.rawValue } == 3)
        #expect(alipay.transactions.count { $0.direction == BillDirection.refund.rawValue } == 11)
        #expect(alipay.transactions.count { $0.direction == BillDirection.neutral.rawValue } == 66)
        #expect(wechat.transactions.allSatisfy { !$0.id.isEmpty && $0.rawFields["微信昵称"] == nil })
        #expect(alipay.transactions.allSatisfy { !$0.id.isEmpty && $0.rawFields["支付宝账户"] == nil })
    }

    @Test func vaultBackupAndCloudRespectBillsModuleBoundary() throws {
        let local = BillRecord(amount: 10, merchant: "本地")
        let imported = BillRecord(amount: 20, merchant: "导入")
        let payload = VaultBackupPayload(
            vault: VaultData(billRecords: [imported]),
            secrets: [],
            includedModules: [.bills]
        )

        let disabledMerge = AppStoreBackupMerger.merge(
            localVault: VaultData(billRecords: [local]),
            localSecrets: [],
            imported: payload,
            enabledModules: [.personalFinance]
        )
        #expect(disabledMerge.vault.billRecords == [local])

        let enabledMerge = AppStoreBackupMerger.merge(
            localVault: VaultData(billRecords: [local]),
            localSecrets: [],
            imported: payload,
            enabledModules: [.bills]
        )
        #expect(Set(enabledMerge.vault.billRecords.map(\.id)) == Set([local.id, imported.id]))

        let attachmentStore = AttachmentStore()
        let excludedSnapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(billRecords: [local]),
            secrets: [],
            attachmentStore: attachmentStore,
            enabledModules: [.personalFinance]
        )
        #expect(excludedSnapshot.items.allSatisfy { $0.kind != .billRecord })

        let includedSnapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(billRecords: [local]),
            secrets: [],
            attachmentStore: attachmentStore,
            enabledModules: [.bills]
        )
        #expect(includedSnapshot.items.contains { $0.kind == .billRecord && $0.module == .bills })

        var remote = local
        remote.amount = 99
        let remotePayload = try CloudSyncCoding.encoder().encode(remote)
        let ignored = try CloudSyncMerger.apply(
            [.upsert(kind: .billRecord, id: remote.id, payload: remotePayload)],
            to: VaultData(billRecords: [local]),
            secrets: [],
            enabledModules: [.personalFinance]
        )
        #expect(ignored.vault.billRecords == [local])
    }

    @Test func emptyVaultDecodesBillsAsEmpty() throws {
        let vault = try JSONDecoder().decode(VaultData.self, from: Data("{}".utf8))
        #expect(vault.billRecords.isEmpty)
        #expect(ToolModule.bills.definition.participatesInBackup)
        #expect(ToolModule.bills.definition.participatesInCloudSync)
    }

    @Test func billTimeDisplayDefaultsToMinutePrecision() {
        let date = Self.date(year: 2026, month: 8, day: 15, hour: 12, minute: 34, second: 56)
        #expect(AppDateFormatter.dateTimeWithoutSecondsString(from: date).hasSuffix("12:34"))
        #expect(AppDateFormatter.dateTimeString(from: date).hasSuffix("12:34:56"))
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    private static func line(_ text: String, y: CGFloat) -> OCRRecognizedLine {
        OCRRecognizedLine(
            text: text,
            confidence: 1,
            boundingBox: OCRNormalizedRegion(x: 0.1, y: y, width: 0.8, height: 0.05)
        )
    }

    private static func exchangeTransaction(
        id: String,
        amount: Decimal,
        occurredAt: Date
    ) -> BillExchangeTransaction {
        BillExchangeTransaction(
            id: id,
            occurredAt: occurredAt,
            direction: BillDirection.expense.rawValue,
            amount: amount,
            currency: CurrencyCode.cny.rawValue,
            transactionType: "商户消费",
            merchant: "测试商户",
            counterparty: nil,
            counterpartyAccount: nil,
            itemDescription: nil,
            paymentMethod: "微信支付",
            accountHint: nil,
            category: BillCategory.shopping.rawValue,
            providerCategory: nil,
            tags: [],
            note: nil,
            status: BillTransactionStatus.completed.rawValue,
            providerStatus: "支付成功",
            merchantTransactionID: nil,
            relatedTransactionID: nil,
            rawFields: [:]
        )
    }

    private static func makeStoredXLSX(
        headers: [String],
        values: [String],
        excelDate: String,
        amount: String
    ) -> Data {
        var sharedStrings: [String] = []
        for value in ["共1笔记录"] + headers + values where !value.isEmpty && !sharedStrings.contains(value) {
            sharedStrings.append(value)
        }
        let indices = Dictionary(uniqueKeysWithValues: sharedStrings.enumerated().map { ($0.element, $0.offset) })
        let sharedXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">\(sharedStrings.map { "<si><t>\($0)</t></si>" }.joined())</sst>
        """
        let headerCells = headers.enumerated().map { index, value in
            "<c r=\"\(columnName(index))2\" t=\"s\"><v>\(indices[value]!)</v></c>"
        }.joined()
        let valueCells = values.enumerated().map { index, value -> String in
            if index == 0 { return "<c r=\"A3\"><v>\(excelDate)</v></c>" }
            if index == 5 { return "<c r=\"F3\"><v>\(amount)</v></c>" }
            guard !value.isEmpty else { return "" }
            return "<c r=\"\(columnName(index))3\" t=\"s\"><v>\(indices[value]!)</v></c>"
        }.joined()
        let worksheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c></row>
        <row r="2">\(headerCells)</row>
        <row r="3">\(valueCells)</row>
        </sheetData></worksheet>
        """
        return makeStoredZIP(entries: [
            ("xl/sharedStrings.xml", Data(sharedXML.utf8)),
            ("xl/worksheets/sheet1.xml", Data(worksheetXML.utf8))
        ])
    }

    private static func makeStoredZIP(entries: [(String, Data)]) -> Data {
        var archive = Data()
        var directory: [(name: Data, size: UInt32, offset: UInt32)] = []
        for (name, contents) in entries {
            let nameData = Data(name.utf8)
            let offset = UInt32(archive.count)
            append(UInt32(0x04034B50), to: &archive)
            append(UInt16(20), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt32(0), to: &archive)
            append(UInt32(contents.count), to: &archive)
            append(UInt32(contents.count), to: &archive)
            append(UInt16(nameData.count), to: &archive)
            append(UInt16(0), to: &archive)
            archive.append(nameData)
            archive.append(contents)
            directory.append((nameData, UInt32(contents.count), offset))
        }
        let directoryOffset = UInt32(archive.count)
        for entry in directory {
            append(UInt32(0x02014B50), to: &archive)
            append(UInt16(20), to: &archive)
            append(UInt16(20), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt32(0), to: &archive)
            append(entry.size, to: &archive)
            append(entry.size, to: &archive)
            append(UInt16(entry.name.count), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt32(0), to: &archive)
            append(entry.offset, to: &archive)
            archive.append(entry.name)
        }
        let directorySize = UInt32(archive.count) - directoryOffset
        append(UInt32(0x06054B50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(directory.count), to: &archive)
        append(UInt16(directory.count), to: &archive)
        append(directorySize, to: &archive)
        append(directoryOffset, to: &archive)
        append(UInt16(0), to: &archive)
        return archive
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func columnName(_ index: Int) -> String {
        var value = index + 1
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }
}

#endif
