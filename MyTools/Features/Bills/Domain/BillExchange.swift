#if MYTOOLS_FEATURE_BILLS
import Foundation

struct BillExchangeDocument: Codable, Equatable, Sendable {
    static let currentFormat = "com.fjwyz.mytools.bill-exchange"
    static let currentVersion = 2

    var format: String
    var version: Int
    var source: BillExchangeSource
    var exportedAt: Date
    var accounts: [BillExchangeAccount]
    var transactions: [BillExchangeTransaction]

    init(
        format: String = Self.currentFormat,
        version: Int = Self.currentVersion,
        source: BillExchangeSource,
        exportedAt: Date = Date(),
        accounts: [BillExchangeAccount] = [],
        transactions: [BillExchangeTransaction]
    ) {
        self.format = format
        self.version = version
        self.source = source
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.transactions = transactions
    }
}

struct BillExchangeSource: Codable, Equatable, Sendable {
    var providerIdentifier: String
    var providerName: String
    var schemaVersion: String?

    static let myTools = BillExchangeSource(
        providerIdentifier: "com.fjwyz.mytools",
        providerName: "方寸",
        schemaVersion: "2"
    )
}

struct BillExchangeAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var institutionName: String?
    var accountHint: String?
    var currency: String?
    var rawFields: [String: String]
}

struct BillExchangeTransaction: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var occurredAt: Date
    var direction: String
    var amount: Decimal
    var currency: String
    var transactionType: String?
    var merchant: String?
    var counterparty: String?
    var counterpartyAccount: String?
    var itemDescription: String?
    var paymentMethod: String?
    var accountHint: String?
    var category: String?
    var providerCategory: String?
    var tags: [String]
    var note: String?
    var status: String
    var providerStatus: String?
    var merchantTransactionID: String?
    var relatedTransactionID: String?
    var rawFields: [String: String]
}

enum BillExchangeError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case invalidTransactionID
    case invalidAmount(String)
    case unsupportedCurrency(String)
    case unsupportedDirection(String)
    case unsupportedStatus(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "不支持账单交换格式：\(format)"
        case .unsupportedVersion(let version):
            return "暂不支持账单交换协议版本 \(version)。"
        case .invalidTransactionID:
            return "账单中存在缺少交易标识的记录。"
        case .invalidAmount(let id):
            return "交易 \(id) 的金额无效。"
        case .unsupportedCurrency(let currency):
            return "暂不支持币种 \(currency)。"
        case .unsupportedDirection(let direction):
            return "暂不支持收支方向 \(direction)。"
        case .unsupportedStatus(let status):
            return "暂不支持交易状态 \(status)。"
        }
    }
}

enum BillExchangeCoding {
    static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum BillExchangeMapper {
    static func document(from records: [BillRecord]) -> BillExchangeDocument {
        BillExchangeDocument(
            source: .myTools,
            transactions: records.map { record in
                BillExchangeTransaction(
                    id: record.id.uuidString.lowercased(),
                    occurredAt: record.occurredAt,
                    direction: record.direction.rawValue,
                    amount: record.amount,
                    currency: record.currency.rawValue,
                    transactionType: nilIfEmpty(record.providerTransactionType),
                    merchant: nilIfEmpty(record.merchant),
                    counterparty: nilIfEmpty(record.counterparty),
                    counterpartyAccount: nilIfEmpty(record.counterpartyAccount),
                    itemDescription: nilIfEmpty(record.itemDescription),
                    paymentMethod: nilIfEmpty(record.paymentMethod),
                    accountHint: nilIfEmpty(record.accountHint),
                    category: record.category.rawValue,
                    providerCategory: nilIfEmpty(record.providerCategory),
                    tags: record.tags,
                    note: nilIfEmpty(record.note),
                    status: record.status.rawValue,
                    providerStatus: nilIfEmpty(record.providerStatus),
                    merchantTransactionID: nilIfEmpty(record.merchantTransactionID),
                    relatedTransactionID: record.relatedTransactionID,
                    rawFields: record.origin.rawFields
                )
            }
        )
    }

    static func records(from document: BillExchangeDocument) throws -> [BillRecord] {
        guard document.format == BillExchangeDocument.currentFormat else {
            throw BillExchangeError.unsupportedFormat(document.format)
        }
        guard document.version == BillExchangeDocument.currentVersion else {
            throw BillExchangeError.unsupportedVersion(document.version)
        }

        return try document.transactions.map { transaction in
            let externalID = transaction.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalID.isEmpty else { throw BillExchangeError.invalidTransactionID }
            guard transaction.amount >= 0 else {
                throw BillExchangeError.invalidAmount(externalID)
            }
            guard let currency = CurrencyCode(rawValue: transaction.currency.uppercased()) else {
                throw BillExchangeError.unsupportedCurrency(transaction.currency)
            }
            guard let direction = BillDirection(rawValue: transaction.direction) else {
                throw BillExchangeError.unsupportedDirection(transaction.direction)
            }
            guard let status = BillTransactionStatus(rawValue: transaction.status) else {
                throw BillExchangeError.unsupportedStatus(transaction.status)
            }
            let localID = document.source.providerIdentifier == BillExchangeSource.myTools.providerIdentifier
                ? UUID(uuidString: externalID) ?? UUID()
                : UUID()
            return BillRecord(
                id: localID,
                occurredAt: transaction.occurredAt,
                direction: direction,
                amount: transaction.amount,
                currency: currency,
                merchant: transaction.merchant ?? "",
                counterparty: transaction.counterparty ?? "",
                itemDescription: transaction.itemDescription ?? "",
                paymentMethod: transaction.paymentMethod ?? "",
                accountHint: transaction.accountHint ?? "",
                category: transaction.category.flatMap(BillCategory.init(rawValue:)) ?? .other,
                providerTransactionType: transaction.transactionType ?? "",
                providerCategory: transaction.providerCategory ?? "",
                counterpartyAccount: transaction.counterpartyAccount ?? "",
                merchantTransactionID: transaction.merchantTransactionID ?? "",
                providerStatus: transaction.providerStatus ?? "",
                tags: transaction.tags,
                note: transaction.note ?? "",
                status: status,
                relatedTransactionID: transaction.relatedTransactionID,
                origin: BillOrigin(
                    kind: .imported,
                    providerIdentifier: document.source.providerIdentifier,
                    providerName: document.source.providerName,
                    externalTransactionID: externalID,
                    importedAt: Date(),
                    rawFields: transaction.rawFields
                )
            )
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

#endif
