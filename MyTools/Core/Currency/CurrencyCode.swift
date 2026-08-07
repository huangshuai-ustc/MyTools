import Foundation

enum CurrencyCode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cny = "CNY"
    case hkd = "HKD"
    case cad = "CAD"
    case chf = "CHF"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case nzd = "NZD"
    case sgd = "SGD"
    case thb = "THB"
    case usd = "USD"
    case aud = "AUD"

    private static let supportedCases = Set(allCases)

    var id: Self { self }

    static var selectableCases: [Self] {
        displayOrdered(supportedCases)
    }

    var title: String {
        switch self {
        case .cny: return "人民币 CNY"
        case .hkd: return "港币 HKD"
        case .cad: return "加拿大元 CAD"
        case .chf: return "瑞士法郎 CHF"
        case .eur: return "欧元 EUR"
        case .gbp: return "英镑 GBP"
        case .jpy: return "日元 JPY"
        case .nzd: return "新西兰元 NZD"
        case .sgd: return "新加坡元 SGD"
        case .thb: return "泰国铢 THB"
        case .usd: return "美元 USD"
        case .aud: return "澳大利亚元 AUD"
        }
    }

    var bankOfChinaName: String? {
        switch self {
        case .cny: return nil
        case .hkd: return "港币"
        case .cad: return "加拿大元"
        case .chf: return "瑞士法郎"
        case .eur: return "欧元"
        case .gbp: return "英镑"
        case .jpy: return "日元"
        case .nzd: return "新西兰元"
        case .sgd: return "新加坡元"
        case .thb: return "泰国铢"
        case .usd: return "美元"
        case .aud: return "澳大利亚元"
        }
    }

    static func selectableCases(including current: Self) -> [Self] {
        displayOrdered(supportedCases.union([current]))
    }

    static func selectableCases(including current: Set<Self>) -> [Self] {
        displayOrdered(supportedCases.union(current))
    }

    static func displayOrdered(_ currencies: Set<Self>) -> [Self] {
        let fixedPriority: [Self: Int] = [.cny: 0, .hkd: 1, .usd: 2]
        let locale = Locale(identifier: "zh_Hans_CN")

        return currencies.sorted { lhs, rhs in
            let lhsPriority = fixedPriority[lhs] ?? Int.max
            let rhsPriority = fixedPriority[rhs] ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            let comparison = lhs.chineseName.compare(
                rhs.chineseName,
                options: [],
                range: nil,
                locale: locale
            )
            return comparison == .orderedSame
                ? lhs.rawValue < rhs.rawValue
                : comparison == .orderedAscending
        }
    }

    private var chineseName: String {
        title.replacingOccurrences(of: " \(rawValue)", with: "")
    }
}
