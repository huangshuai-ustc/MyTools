import Foundation

enum PriceAlertDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case below
    case above

    var id: Self { self }

    var title: String {
        switch self {
        case .below: return "低于"
        case .above: return "高于"
        }
    }

    var symbol: String {
        switch self {
        case .below: return "<"
        case .above: return ">"
        }
    }

    func matches(_ value: Decimal, threshold: Decimal) -> Bool {
        switch self {
        case .below: return value < threshold
        case .above: return value > threshold
        }
    }
}

struct CurrencyRateAlert: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var currency: CurrencyCode = .usd
    var amount: Decimal = 100
    var direction: PriceAlertDirection = .below
    var threshold: Decimal = 0
    var isEnabled = true

    init(
        id: UUID = UUID(),
        currency: CurrencyCode = .usd,
        amount: Decimal = 100,
        direction: PriceAlertDirection = .below,
        threshold: Decimal = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.currency = currency
        self.amount = amount
        self.direction = direction
        self.threshold = threshold
        self.isEnabled = isEnabled
    }

    func convertedValue(using rates: [CurrencyCode: Decimal]) -> Decimal? {
        guard amount > 0,
              let rate = rates[currency],
              rate > 0 else { return nil }
        return amount * rate
    }
}

struct StockPriceAlert: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var stockID: UUID?
    var direction: PriceAlertDirection = .below
    var threshold: Decimal = 0
    var isEnabled = true

    init(
        id: UUID = UUID(),
        stockID: UUID? = nil,
        direction: PriceAlertDirection = .below,
        threshold: Decimal = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.stockID = stockID
        self.direction = direction
        self.threshold = threshold
        self.isEnabled = isEnabled
    }
}
