#if MYTOOLS_FEATURE_BILLS
import Foundation

enum BillDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case expense
    case income
    case refund
    case neutral

    var id: Self { self }

    var title: String {
        switch self {
        case .expense: return "支出"
        case .income: return "收入"
        case .refund: return "退款"
        case .neutral: return "不计收支"
        }
    }

    var systemImage: String {
        switch self {
        case .expense: return "arrow.up.right"
        case .income: return "arrow.down.left"
        case .refund: return "arrow.uturn.backward"
        case .neutral: return "minus"
        }
    }

    var amountSign: String {
        switch self {
        case .expense: return "-"
        case .income, .refund: return "+"
        case .neutral: return ""
        }
    }
}

enum BillTransactionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case completed
    case pending
    case refunded
    case cancelled

    var id: Self { self }

    var title: String {
        switch self {
        case .completed: return "已完成"
        case .pending: return "处理中"
        case .refunded: return "已退款"
        case .cancelled: return "已取消"
        }
    }
}

enum BillCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case dining
    case groceries
    case transport
    case shopping
    case housing
    case utilities
    case medical
    case education
    case travel
    case entertainment
    case transfer
    case salary
    case refund
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .dining: return "餐饮"
        case .groceries: return "日用"
        case .transport: return "交通"
        case .shopping: return "购物"
        case .housing: return "住房"
        case .utilities: return "缴费"
        case .medical: return "医疗"
        case .education: return "教育"
        case .travel: return "旅行"
        case .entertainment: return "娱乐"
        case .transfer: return "转账"
        case .salary: return "工资"
        case .refund: return "退款"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .dining: return "fork.knife"
        case .groceries: return "basket.fill"
        case .transport: return "car.fill"
        case .shopping: return "bag.fill"
        case .housing: return "house.fill"
        case .utilities: return "bolt.fill"
        case .medical: return "cross.case.fill"
        case .education: return "book.fill"
        case .travel: return "airplane"
        case .entertainment: return "gamecontroller.fill"
        case .transfer: return "arrow.left.arrow.right"
        case .salary: return "banknote.fill"
        case .refund: return "arrow.uturn.backward.circle.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

enum BillOriginKind: String, Codable, Sendable {
    case manual
    case ocr
    case imported

    var title: String {
        switch self {
        case .manual: return "手工录入"
        case .ocr: return "图片识别"
        case .imported: return "文件导入"
        }
    }
}

struct BillOrigin: Codable, Equatable, Sendable {
    var kind: BillOriginKind
    var providerIdentifier: String
    var providerName: String
    var externalTransactionID: String?
    var importedAt: Date?
    var rawFields: [String: String]

    static let manual = BillOrigin(
        kind: .manual,
        providerIdentifier: "manual",
        providerName: "手工录入",
        externalTransactionID: nil,
        importedAt: nil,
        rawFields: [:]
    )

    static func ocr(fileName: String?) -> BillOrigin {
        var rawFields: [String: String] = [:]
        if let fileName, !fileName.isEmpty {
            rawFields["fileName"] = fileName
        }
        return BillOrigin(
            kind: .ocr,
            providerIdentifier: "apple.vision",
            providerName: "图片文字识别",
            externalTransactionID: nil,
            importedAt: Date(),
            rawFields: rawFields
        )
    }
}

struct BillRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var occurredAt: Date
    var direction: BillDirection
    var amount: Decimal
    var currency: CurrencyCode
    var merchant: String
    var counterparty: String
    var itemDescription: String
    var paymentMethod: String
    var accountHint: String
    var category: BillCategory
    var providerTransactionType: String
    var providerCategory: String
    var counterpartyAccount: String
    var merchantTransactionID: String
    var providerStatus: String
    var tags: [String]
    var note: String
    var status: BillTransactionStatus
    var relatedTransactionID: String?
    var origin: BillOrigin
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        direction: BillDirection = .expense,
        amount: Decimal = 0,
        currency: CurrencyCode = .cny,
        merchant: String = "",
        counterparty: String = "",
        itemDescription: String = "",
        paymentMethod: String = "",
        accountHint: String = "",
        category: BillCategory = .other,
        providerTransactionType: String = "",
        providerCategory: String = "",
        counterpartyAccount: String = "",
        merchantTransactionID: String = "",
        providerStatus: String = "",
        tags: [String] = [],
        note: String = "",
        status: BillTransactionStatus = .completed,
        relatedTransactionID: String? = nil,
        origin: BillOrigin = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.direction = direction
        self.amount = amount
        self.currency = currency
        self.merchant = merchant
        self.counterparty = counterparty
        self.itemDescription = itemDescription
        self.paymentMethod = paymentMethod
        self.accountHint = accountHint
        self.category = category
        self.providerTransactionType = providerTransactionType
        self.providerCategory = providerCategory
        self.counterpartyAccount = counterpartyAccount
        self.merchantTransactionID = merchantTransactionID
        self.providerStatus = providerStatus
        self.tags = tags
        self.note = note
        self.status = status
        self.relatedTransactionID = relatedTransactionID
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        for value in [merchant, counterparty, itemDescription] {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }
        return category.title
    }

    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.locale = .autoupdatingCurrent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let value = formatter.string(from: NSDecimalNumber(decimal: amount))
            ?? "\(currency.rawValue) \(amount)"
        return direction.amountSign + value
    }

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return merchant.localizedCaseInsensitiveContains(term)
            || counterparty.localizedCaseInsensitiveContains(term)
            || itemDescription.localizedCaseInsensitiveContains(term)
            || paymentMethod.localizedCaseInsensitiveContains(term)
            || accountHint.localizedCaseInsensitiveContains(term)
            || providerTransactionType.localizedCaseInsensitiveContains(term)
            || providerCategory.localizedCaseInsensitiveContains(term)
            || counterpartyAccount.localizedCaseInsensitiveContains(term)
            || merchantTransactionID.localizedCaseInsensitiveContains(term)
            || providerStatus.localizedCaseInsensitiveContains(term)
            || category.title.localizedCaseInsensitiveContains(term)
            || note.localizedCaseInsensitiveContains(term)
            || tags.contains { $0.localizedCaseInsensitiveContains(term) }
    }
}

#endif
