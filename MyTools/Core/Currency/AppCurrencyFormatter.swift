import Foundation

enum AppCurrencyFormatter {
    /// 标准货币金额，固定两位小数，使用货币符号前缀（¥/HK$/$ 等）。
    static func money(_ value: Decimal, currency: CurrencyCode) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.currencySymbol = currencySymbol(for: currency)
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber)
            ?? "\(currency.rawValue) \(value)"
    }

    /// 带正负号前缀的货币金额（收支/盈亏场景）。
    static func signedMoney(_ value: Decimal, currency: CurrencyCode, sign: String) -> String {
        sign + money(value < 0 ? -value : value, currency: currency)
    }

    /// 价格型，2~4 位小数（股价等需要更高精度的场景）。
    static func price(_ value: Decimal, currency: CurrencyCode) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.currencySymbol = currencySymbol(for: currency)
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber)
            ?? "\(currency.rawValue) \(value)"
    }

    static func currencySymbol(for currency: CurrencyCode) -> String {
        switch currency {
        case .cny: return "¥"
        case .hkd: return "HK$"
        case .usd: return "$"
        case .aud: return "A$"
        case .cad: return "CA$"
        case .sgd: return "S$"
        case .nzd: return "NZ$"
        case .eur: return "€"
        case .gbp: return "£"
        case .jpy: return "JP¥"
        case .chf: return "CHF "
        case .thb: return "฿"
        case .mop: return "MOP "
        }
    }
}
