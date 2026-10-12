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
    case mop = "MOP"
    case huf = "HUF"
    case php = "PHP"
    case aed = "AED"
    case czk = "CZK"
    case dkk = "DKK"
    case ils = "ILS"
    case nok = "NOK"
    case pln = "PLN"
    case sek = "SEK"
    case ugx = "UGX"
    case zar = "ZAR"

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
        case .mop: return "澳门元 MOP"
        case .huf: return "匈牙利福林 HUF"
        case .php: return "菲律宾比索 PHP"
        case .aed: return "阿联酋迪拉姆 AED"
        case .czk: return "捷克克朗 CZK"
        case .dkk: return "丹麦克朗 DKK"
        case .ils: return "以色列新谢克尔 ILS"
        case .nok: return "挪威克朗 NOK"
        case .pln: return "波兰兹罗提 PLN"
        case .sek: return "瑞典克朗 SEK"
        case .ugx: return "乌干达先令 UGX"
        case .zar: return "南非兰特 ZAR"
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
        case .mop: return "澳门元"
        case .huf: return "匈牙利福林"
        case .php: return "菲律宾比索"
        case .aed: return "阿联酋迪拉姆"
        case .czk: return "捷克克朗"
        case .dkk: return "丹麦克朗"
        case .ils: return "以色列新谢克尔"
        case .nok: return "挪威克朗"
        case .pln: return "波兰兹罗提"
        case .sek: return "瑞典克朗"
        case .ugx: return "乌干达先令"
        case .zar: return "南非兰特"
        }
    }

    static func selectableCases(including current: Self) -> [Self] {
        displayOrdered(supportedCases.union([current]))
    }

    static func selectableCases(including current: Set<Self>) -> [Self] {
        displayOrdered(supportedCases.union(current))
    }

    /// Stable finance ordering used for account lists and rate-facing UI. It
    /// follows the major-currency order used by the bank-rate surface; less
    /// common currencies remain available and are placed afterward.
    static let financialPriority: [Self] = [
        .cny, .hkd, .usd, .eur, .gbp, .jpy, .aud, .nzd, .cad, .chf, .sgd,
        .aed, .thb, .sek, .dkk, .nok, .pln, .czk, .huf, .ils, .php, .zar,
        .ugx, .mop
    ]

    static func financialOrdered(_ currencies: Set<Self>) -> [Self] {
        let rank = Dictionary(uniqueKeysWithValues: financialPriority.enumerated().map { ($1, $0) })
        return currencies.sorted {
            let lhsRank = rank[$0] ?? Int.max
            let rhsRank = rank[$1] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return $0.rawValue < $1.rawValue
        }
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
