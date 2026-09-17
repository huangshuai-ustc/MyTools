#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockValueFormatter {
    static func exchangeRate(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "--"
    }

    static func money(_ value: Decimal, currencyCode: String) -> String {
        guard let currency = CurrencyCode(rawValue: currencyCode.uppercased()) else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currencyCode
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter.string(from: value as NSDecimalNumber) ?? "--"
        }
        return AppCurrencyFormatter.money(value, currency: currency)
    }

    static func moneyMagnitude(_ value: Decimal, currencyCode: String) -> String {
        money(value < 0 ? -value : value, currencyCode: currencyCode)
    }

    /// Money with an explicit sign on both directions, matching how brokerage
    /// apps present gains and losses. `money(_:currencyCode:)` only renders the
    /// minus sign, and `moneyMagnitude(_:currencyCode:)` strips the sign
    /// entirely, so neither can produce `+2.01`.
    static func signedMoney(_ value: Decimal, currencyCode: String) -> String {
        let magnitude = moneyMagnitude(value, currencyCode: currencyCode)
        return (value < 0 ? "-" : "+") + magnitude
    }

    static func price(_ value: Decimal, currencyCode: String) -> String {
        guard let currency = CurrencyCode(rawValue: currencyCode.uppercased()) else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currencyCode
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 4
            return formatter.string(from: value as NSDecimalNumber) ?? "--"
        }
        return AppCurrencyFormatter.price(value, currency: currency)
    }

    static func quantity(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    static func integerQuantity(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    static func percent(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = "+"
        return formatter.string(from: value as NSDecimalNumber) ?? "0.00%"
    }

    static func signedPercent(_ value: Decimal) -> String {
        let magnitude = value < 0 ? -value : value
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: magnitude as NSDecimalNumber) ?? "0.00%"
        return (value < 0 ? "-" : "+") + number
    }

    static func allocationPercent(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "0.00%"
    }
}

#endif
