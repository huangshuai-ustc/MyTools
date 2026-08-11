#if MYTOOLS_FEATURE_BILLS
import Foundation
import SwiftUI
import UniformTypeIdentifiers

protocol BillImportAdapter: Sendable {
    var identifier: String { get }
    func canImport(data: Data, fileName: String) -> Bool
    func decode(data: Data, fileName: String) throws -> BillExchangeDocument
}

enum BillImportError: LocalizedError, Equatable {
    case unsupportedFile
    case missingFileData
    case schemaSampleRequired(String)
    case missingTransactionHeader(String)
    case invalidTransaction(provider: String, row: Int, field: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "无法识别该账单文件。当前支持方寸 JSON、微信支付 XLSX 和支付宝 CSV。"
        case .missingFileData:
            return "账单文件没有可读取的内容。"
        case .schemaSampleRequired(let provider):
            return "已识别为\(provider)账单，但尚未配置真实字段映射。提供一份脱敏样本后即可补充适配器。"
        case .missingTransactionHeader(let provider):
            return "没有在\(provider)账单中找到受支持的交易明细表头。"
        case .invalidTransaction(let provider, let row, let field):
            return "\(provider)账单第 \(row) 行的“\(field)”无效。"
        }
    }
}

struct BillImportAdapterRegistry: Sendable {
    private let adapters: [any BillImportAdapter]

    init(adapters: [any BillImportAdapter] = Self.defaultAdapters) {
        self.adapters = adapters
    }

    func decode(data: Data, fileName: String) throws -> BillExchangeDocument {
        guard !data.isEmpty else { throw BillImportError.missingFileData }
        guard let adapter = adapters.first(where: { $0.canImport(data: data, fileName: fileName) }) else {
            throw BillImportError.unsupportedFile
        }
        return try adapter.decode(data: data, fileName: fileName)
    }

    private static let defaultAdapters: [any BillImportAdapter] = [
        BillExchangeJSONImportAdapter(),
        WeChatBillImportAdapter(),
        AlipayBillImportAdapter(),
        PendingCSVBillImportAdapter(provider: .bank)
    ]
}

struct BillExchangeJSONImportAdapter: BillImportAdapter {
    let identifier = "mytools-json"

    func canImport(data: Data, fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".json")
            || data.first(where: { !Self.whitespace.contains($0) }) == 123
    }

    func decode(data: Data, fileName: String) throws -> BillExchangeDocument {
        let document = try BillExchangeCoding.decoder().decode(BillExchangeDocument.self, from: data)
        _ = try BillExchangeMapper.records(from: document)
        return document
    }

    private static let whitespace = Set(" \n\r\t".utf8)
}

struct WeChatBillImportAdapter: BillImportAdapter {
    let identifier = "wechat-xlsx"

    func canImport(data: Data, fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".xlsx")
            && data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    func decode(data: Data, fileName: String) throws -> BillExchangeDocument {
        let rows = try BillXLSXReader.worksheetRows(from: data)
        let table = try BillImportTable(
            rows: rows,
            provider: "微信支付",
            requiredHeaders: [
                "交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)",
                "支付方式", "当前状态", "交易单号", "商户单号", "备注"
            ],
            transactionIDHeader: "交易单号"
        )
        let formatter = PlatformBillParsing.dateFormatter()
        let transactions = try table.dataRows.map { row in
            let transactionID = row["交易单号"]
            let transactionType = row["交易类型"]
            let sourceDirection = row["收/支"]
            let providerStatus = row["当前状态"]
            guard let occurredAt = PlatformBillParsing.date(
                fromExcelValue: row["交易时间"],
                formatter: formatter
            ) else {
                throw BillImportError.invalidTransaction(provider: "微信支付", row: row.sourceRow, field: "交易时间")
            }
            guard let amount = PlatformBillParsing.amount(row["金额(元)"]), amount >= 0 else {
                throw BillImportError.invalidTransaction(provider: "微信支付", row: row.sourceRow, field: "金额(元)")
            }
            let direction = PlatformBillParsing.direction(
                sourceDirection: sourceDirection,
                categoryOrType: transactionType,
                providerStatus: providerStatus
            )
            return BillExchangeTransaction(
                id: transactionID,
                occurredAt: occurredAt,
                direction: direction.rawValue,
                amount: amount,
                currency: CurrencyCode.cny.rawValue,
                transactionType: PlatformBillParsing.nilIfPlaceholder(transactionType),
                merchant: nil,
                counterparty: PlatformBillParsing.nilIfPlaceholder(row["交易对方"]),
                counterpartyAccount: nil,
                itemDescription: PlatformBillParsing.nilIfPlaceholder(row["商品"]),
                paymentMethod: "微信支付",
                accountHint: PlatformBillParsing.nilIfPlaceholder(row["支付方式"]),
                category: PlatformBillParsing.weChatCategory(transactionType, direction: direction).rawValue,
                providerCategory: nil,
                tags: [],
                note: PlatformBillParsing.nilIfPlaceholder(row["备注"]),
                status: PlatformBillParsing.status(providerStatus).rawValue,
                providerStatus: PlatformBillParsing.nilIfPlaceholder(providerStatus),
                merchantTransactionID: PlatformBillParsing.nilIfPlaceholder(row["商户单号"]),
                relatedTransactionID: nil,
                rawFields: row.rawFields
            )
        }
        return BillExchangeDocument(
            source: BillExchangeSource(
                providerIdentifier: "com.tencent.wechatpay",
                providerName: "微信支付",
                schemaVersion: "xlsx-v1"
            ),
            transactions: transactions
        )
    }
}

struct AlipayBillImportAdapter: BillImportAdapter {
    let identifier = "alipay-csv"

    func canImport(data: Data, fileName: String) -> Bool {
        guard fileName.lowercased().hasSuffix(".csv"),
              let sample = try? BillDelimitedTextReader.decode(data) else {
            return false
        }
        return sample.contains("支付宝")
            || (sample.contains("交易订单号") && sample.contains("收/付款方式"))
    }

    func decode(data: Data, fileName: String) throws -> BillExchangeDocument {
        let text = try BillDelimitedTextReader.decode(data)
        let table = try BillImportTable(
            rows: BillDelimitedTextReader.rows(from: text),
            provider: "支付宝",
            requiredHeaders: [
                "交易时间", "交易分类", "交易对方", "对方账号", "商品说明", "收/支",
                "金额", "收/付款方式", "交易状态", "交易订单号", "商家订单号", "备注"
            ],
            transactionIDHeader: "交易订单号"
        )
        let formatter = PlatformBillParsing.dateFormatter()
        let transactions = try table.dataRows.map { row in
            let providerCategory = row["交易分类"]
            let sourceDirection = row["收/支"]
            let providerStatus = row["交易状态"]
            guard let occurredAt = formatter.date(from: row["交易时间"]) else {
                throw BillImportError.invalidTransaction(provider: "支付宝", row: row.sourceRow, field: "交易时间")
            }
            guard let amount = PlatformBillParsing.amount(row["金额"]), amount >= 0 else {
                throw BillImportError.invalidTransaction(provider: "支付宝", row: row.sourceRow, field: "金额")
            }
            let direction = PlatformBillParsing.direction(
                sourceDirection: sourceDirection,
                categoryOrType: providerCategory,
                providerStatus: providerStatus
            )
            return BillExchangeTransaction(
                id: row["交易订单号"],
                occurredAt: occurredAt,
                direction: direction.rawValue,
                amount: amount,
                currency: CurrencyCode.cny.rawValue,
                transactionType: nil,
                merchant: nil,
                counterparty: PlatformBillParsing.nilIfPlaceholder(row["交易对方"]),
                counterpartyAccount: PlatformBillParsing.nilIfPlaceholder(row["对方账号"]),
                itemDescription: PlatformBillParsing.nilIfPlaceholder(row["商品说明"]),
                paymentMethod: "支付宝",
                accountHint: PlatformBillParsing.nilIfPlaceholder(row["收/付款方式"]),
                category: PlatformBillParsing.alipayCategory(providerCategory, direction: direction).rawValue,
                providerCategory: PlatformBillParsing.nilIfPlaceholder(providerCategory),
                tags: [],
                note: PlatformBillParsing.nilIfPlaceholder(row["备注"]),
                status: PlatformBillParsing.status(providerStatus).rawValue,
                providerStatus: PlatformBillParsing.nilIfPlaceholder(providerStatus),
                merchantTransactionID: PlatformBillParsing.nilIfPlaceholder(row["商家订单号"]),
                relatedTransactionID: nil,
                rawFields: row.rawFields
            )
        }
        return BillExchangeDocument(
            source: BillExchangeSource(
                providerIdentifier: "com.alipay",
                providerName: "支付宝",
                schemaVersion: "csv-v1"
            ),
            transactions: transactions
        )
    }
}

struct PendingCSVBillImportAdapter: BillImportAdapter {
    enum Provider: Sendable {
        case bank

        var identifier: String {
            switch self {
            case .bank: return "bank-csv"
            }
        }

        var displayName: String {
            switch self {
            case .bank: return "银行卡 CSV"
            }
        }
    }

    let provider: Provider
    var identifier: String { provider.identifier }

    func canImport(data: Data, fileName: String) -> Bool {
        let lowercasedName = fileName.lowercased()
        switch provider {
        case .bank:
            return lowercasedName.hasSuffix(".csv")
        }
    }

    func decode(data: Data, fileName: String) throws -> BillExchangeDocument {
        throw BillImportError.schemaSampleRequired(provider.displayName)
    }
}

private struct BillImportTable {
    struct Row {
        let sourceRow: Int
        let headers: [String]
        let values: [String]

        subscript(header: String) -> String {
            guard let index = headers.firstIndex(of: header), values.indices.contains(index) else { return "" }
            return values[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var rawFields: [String: String] {
            Dictionary(uniqueKeysWithValues: headers.enumerated().compactMap { index, header in
                guard !header.isEmpty, values.indices.contains(index) else { return nil }
                let value = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return (header, value)
            })
        }
    }

    let dataRows: [Row]

    init(
        rows: [[String]],
        provider: String,
        requiredHeaders: Set<String>,
        transactionIDHeader: String
    ) throws {
        guard let headerIndex = rows.firstIndex(where: { row in
            requiredHeaders.isSubset(of: Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
        }) else {
            throw BillImportError.missingTransactionHeader(provider)
        }
        let headers = rows[headerIndex].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        dataRows = try rows.dropFirst(headerIndex + 1).enumerated().compactMap { offset, values in
            let row = Row(sourceRow: headerIndex + offset + 2, headers: headers, values: values)
            if values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return nil
            }
            let transactionID = row[transactionIDHeader]
            guard !transactionID.isEmpty else {
                throw BillImportError.invalidTransaction(
                    provider: provider,
                    row: row.sourceRow,
                    field: transactionIDHeader
                )
            }
            return row
        }
    }
}

private enum PlatformBillParsing {
    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    static func date(fromExcelValue value: String, formatter: DateFormatter) -> Date? {
        if let date = formatter.date(from: value) { return date }
        guard let serial = Double(value), serial >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        // Excel serial dates have no time-zone history. The provider declares UTC+08:00,
        // so use a fixed offset instead of Shanghai's pre-1901 local mean time.
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        guard let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30)) else {
            return nil
        }
        return calendar.date(byAdding: .second, value: Int((serial * 86_400).rounded()), to: base)
    }

    static func amount(_ value: String) -> Decimal? {
        DecimalTextParser.decimal(
            from: value
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "¥", with: "")
                .replacingOccurrences(of: "￥", with: "")
        )
    }

    static func direction(
        sourceDirection: String,
        categoryOrType: String,
        providerStatus: String
    ) -> BillDirection {
        let refund = categoryOrType.contains("退款") || providerStatus.contains("退款")
        switch sourceDirection.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "支出": return .expense
        case "收入": return refund ? .refund : .income
        case "不计收支", "/", "": return refund ? .refund : .neutral
        default: return refund ? .refund : .neutral
        }
    }

    static func status(_ value: String) -> BillTransactionStatus {
        if ["关闭", "取消", "失败"].contains(where: value.contains) { return .cancelled }
        if ["确认中", "处理中", "等待"].contains(where: value.contains) { return .pending }
        if value.contains("退款") { return .refunded }
        return .completed
    }

    static func weChatCategory(_ transactionType: String, direction: BillDirection) -> BillCategory {
        if direction == .refund { return .refund }
        if direction == .neutral || transactionType.contains("转账") || transactionType.contains("群收款") {
            return .transfer
        }
        return .other
    }

    static func alipayCategory(_ providerCategory: String, direction: BillDirection) -> BillCategory {
        if direction == .refund { return .refund }
        switch providerCategory {
        case "餐饮美食": return .dining
        case "交通出行": return .transport
        case "日用百货", "家居家装": return .shopping
        case "充值缴费", "生活服务": return .utilities
        case "文化休闲": return .entertainment
        case "转账红包", "亲友代付", "投资理财", "信用借还": return .transfer
        default: return direction == .neutral ? .transfer : .other
        }
    }

    static func nilIfPlaceholder(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "/" ? nil : value
    }
}

struct BillExchangeFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(document: BillExchangeDocument) throws {
        data = try BillExchangeCoding.encoder(prettyPrinted: true).encode(document)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BillImportError.missingFileData
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#endif
