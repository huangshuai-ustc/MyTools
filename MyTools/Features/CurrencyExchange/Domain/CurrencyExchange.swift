#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
import Foundation

enum CurrencyExchangeQuoteConvention: String, Codable, CaseIterable, Identifiable, Sendable {
    case hundredBoughtToSold
    case hundredSoldToBought

    var id: Self { self }

    func title(soldCurrency: CurrencyCode, boughtCurrency: CurrencyCode) -> String {
        switch self {
        case .hundredBoughtToSold:
            return "100 \(boughtCurrency.rawValue) = ? \(soldCurrency.rawValue)"
        case .hundredSoldToBought:
            return "100 \(soldCurrency.rawValue) = ? \(boughtCurrency.rawValue)"
        }
    }
}

struct CurrencyExchangeRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var exchangedAt = Date()
    var soldCurrency: CurrencyCode = .cny
    var boughtCurrency: CurrencyCode = .usd
    var quoteConvention: CurrencyExchangeQuoteConvention = .hundredBoughtToSold
    var quotedRate: Decimal = 0
    var soldAmount: Decimal = 0
    var boughtAmount: Decimal = 0
    var fee: Decimal = 0

    init(
        id: UUID = UUID(),
        exchangedAt: Date = Date(),
        soldCurrency: CurrencyCode = .cny,
        boughtCurrency: CurrencyCode = .usd,
        quoteConvention: CurrencyExchangeQuoteConvention = .hundredBoughtToSold,
        quotedRate: Decimal = 0,
        soldAmount: Decimal = 0,
        boughtAmount: Decimal = 0,
        fee: Decimal = 0
    ) {
        self.id = id
        self.exchangedAt = Self.noon(on: exchangedAt)
        self.soldCurrency = soldCurrency
        self.boughtCurrency = boughtCurrency
        self.quoteConvention = quoteConvention
        self.quotedRate = quotedRate
        self.soldAmount = soldAmount
        self.boughtAmount = boughtAmount
        self.fee = fee
    }

    /// 换汇只记录日期；统一存成当地中午，避免时区变化或夏令时把日期推到前后一天。
    static func noon(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    /// 统一换算为：1 单位卖出币种可买入多少单位买入币种。
    var boughtUnitsPerSoldUnit: Decimal {
        guard quotedRate > 0 else { return 0 }
        switch quoteConvention {
        case .hundredBoughtToSold:
            return 100 / quotedRate
        case .hundredSoldToBought:
            return quotedRate / 100
        }
    }

    var expectedBoughtAmount: Decimal {
        soldAmount * boughtUnitsPerSoldUnit
    }

    var effectiveRate: Decimal? {
        let totalSold = soldAmount + fee
        guard totalSold > 0 else { return nil }
        return boughtAmount / totalSold
    }

    /// 按当前中国银行现汇买入价，把交易前后的资产都折算成人民币。
    func renminbiLoss(using buyingRates: [CurrencyCode: Decimal]) -> Decimal? {
        guard let soldCurrencyRate = renminbiRate(for: soldCurrency, using: buyingRates),
              let boughtCurrencyRate = renminbiRate(for: boughtCurrency, using: buyingRates) else {
            return nil
        }
        let originalRenminbiValue = (soldAmount + fee) * soldCurrencyRate
        let currentRenminbiValue = boughtAmount * boughtCurrencyRate
        return originalRenminbiValue - currentRenminbiValue
    }

    func currentRenminbiValue(using buyingRates: [CurrencyCode: Decimal]) -> Decimal? {
        guard let rate = renminbiRate(for: boughtCurrency, using: buyingRates) else { return nil }
        return boughtAmount * rate
    }

    func renminbiLossRate(using buyingRates: [CurrencyCode: Decimal]) -> Decimal? {
        guard let soldCurrencyRate = renminbiRate(for: soldCurrency, using: buyingRates) else { return nil }
        let originalRenminbiValue = (soldAmount + fee) * soldCurrencyRate
        guard originalRenminbiValue > 0, let loss = renminbiLoss(using: buyingRates) else { return nil }
        return loss / originalRenminbiValue
    }

    private func renminbiRate(
        for currency: CurrencyCode,
        using buyingRates: [CurrencyCode: Decimal]
    ) -> Decimal? {
        currency == .cny ? 1 : buyingRates[currency]
    }
}

enum CurrencyExchangeValueFormatter {
    static func amount(_ value: Decimal, currency: CurrencyCode) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        let amount = formatter.string(from: value as NSDecimalNumber) ?? "--"
        return "\(amount) \(currency.rawValue)"
    }

    static func rate(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        return formatter.string(from: value as NSDecimalNumber) ?? "--"
    }

    static func price(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "--"
    }

    static func percent(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "--"
    }
}

enum CurrencyExchangeResult {
    case loss
    case profit
    case even

    init(amount: Decimal) {
        if amount > 0 {
            self = .loss
        } else if amount < 0 {
            self = .profit
        } else {
            self = .even
        }
    }

    var title: String {
        switch self {
        case .loss: return "亏损"
        case .profit: return "盈利"
        case .even: return "持平"
        }
    }

    func displayValue(_ value: Decimal) -> Decimal {
        switch self {
        case .profit: return -value
        case .loss, .even: return value
        }
    }
}

enum RenminbiExchangeDirection {
    case sell
    case buy
    case crossCurrency

    init(record: CurrencyExchangeRecord) {
        if record.soldCurrency == .cny, record.boughtCurrency != .cny {
            self = .sell
        } else if record.boughtCurrency == .cny, record.soldCurrency != .cny {
            self = .buy
        } else {
            self = .crossCurrency
        }
    }

    var title: String {
        switch self {
        case .sell: return "卖出人民币"
        case .buy: return "买入人民币"
        case .crossCurrency: return "外币兑换"
        }
    }

    var shortTitle: String {
        switch self {
        case .sell: return "卖"
        case .buy: return "买"
        case .crossCurrency: return "换"
        }
    }
}

#endif
