#if MYTOOLS_FEATURE_FINANCE
import Foundation

enum BrokerageAccountType: String, Codable, CaseIterable, Identifiable {
    case cash, margin, portfolioMargin
    var id: Self { self }
    var title: String { switch self { case .cash: "现金账户"; case .margin: "保证金账户"; case .portfolioMargin: "投资组合保证金账户" } }
}
struct BrokerageAccountDetails: Codable, Equatable {
    var accountType: BrokerageAccountType = .cash
    var baseCurrency: CurrencyCode = .usd
    var legalEntity = ""
    var ownership = "个人"
    var openedAt: Date?
}
struct BrokerageInstitutionDetails: Codable, Equatable {
    var platform = "IBKR"
    var accounts: [BrokerageAccount] = []
    var fundingMethods: [FinanceReceivingMethod] = []
    init() {}

    private enum CodingKeys: String, CodingKey { case platform, accounts, fundingMethods }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "IBKR"
        fundingMethods = try c.decodeIfPresent([FinanceReceivingMethod].self, forKey: .fundingMethods) ?? []
        do {
            accounts = try c.decodeIfPresent([BrokerageAccount].self, forKey: .accounts) ?? []
        } catch {
            let legacy = try c.decodeIfPresent([FinancialAccount].self, forKey: .accounts) ?? []
            accounts = legacy.map { value in
                var result = BrokerageAccount()
                result.id = value.id; result.name = value.name; result.accountNumber = value.accountNumber
                result.holderName = value.holderName; result.baseCurrency = value.currencies.first ?? .usd
                result.legalEntity = value.legalEntity; result.openedAt = value.openedAt
                result.status = value.status; result.note = value.note
                if let details = value.brokerage { result.accountType = details.accountType; result.baseCurrency = details.baseCurrency; result.ownership = details.ownership }
                return result
            }
        }
    }
}
struct PaymentInstitutionDetails: Codable, Equatable {
    var platform = ""
    var profileType = "个人"
    var accounts: [PaymentAccount] = []
    var receivingMethods: [FinanceReceivingMethod] = []
    init() {}

    private enum CodingKeys: String, CodingKey { case platform, profileType, accounts, receivingMethods }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        profileType = try c.decodeIfPresent(String.self, forKey: .profileType) ?? "个人"
        receivingMethods = try c.decodeIfPresent([FinanceReceivingMethod].self, forKey: .receivingMethods) ?? []
        do {
            accounts = try c.decodeIfPresent([PaymentAccount].self, forKey: .accounts) ?? []
        } catch {
            let legacy = try c.decodeIfPresent([FinancialAccount].self, forKey: .accounts) ?? []
            accounts = legacy.map { value in
                var result = PaymentAccount()
                result.id = value.id; result.name = value.name; result.accountNumber = value.accountNumber
                result.currencies = value.currencies; result.status = value.status; result.note = value.note
                result.receivingProfile = value.receivingProfile
                return result
            }
        }
    }
}
struct BrokerageAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var accountNumber = ""
    var holderName = ""
    var accountType: BrokerageAccountType = .cash
    var baseCurrency: CurrencyCode = .usd
    var legalEntity = ""
    var ownership = "个人"
    var openedAt: Date?
    var status: AccountStatus = .normal
    var note = ""
    var fundingProfileIDs: [UUID] = []
    var displayName: String { name.isEmpty ? "IBKR 账户" : name }
    var maskedAccountNumber: String { AccountNumberFormatter.masked(accountNumber) }
}
struct PaymentAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var currencies: Set<CurrencyCode> = []
    var accountNumber = ""
    var status: AccountStatus = .normal
    var note = ""
    var receivingProfile: FinanceReceivingMethod?
    var displayName: String { name.isEmpty ? "币种账户" : name }
    var maskedAccountNumber: String { AccountNumberFormatter.masked(accountNumber) }
    var currencySummary: String { CurrencyCode.displayOrdered(currencies).map(\.rawValue).joined(separator: " · ") }
}
struct OtherFinancialInstitutionDetails: Codable, Equatable {
    var accounts: [FinancialAccount] = []
    var receivingMethods: [FinanceReceivingMethod] = []
}

enum FinanceReceivingTemplates {
    private static let wiseOverridesKey = "finance.wiseReceivingTemplateOverrides.v1"
    /// Wise currently supported receiving currencies in this app. Currency is
    /// deliberately selected after creating a blank receiving profile.
    /// Field families follow Wise Help Centre account-detail guidance:
    /// https://wise.com/help/articles/2978083/how-do-i-get-account-details
    /// and the currency-specific USD/EUR/GBP account-detail pages.
    static let wiseCurrencies: [CurrencyCode] = [.usd, .eur, .gbp, .aud, .nzd, .aed, .cad, .chf, .cny, .czk, .dkk, .hkd, .huf, .ils, .jpy, .nok, .php, .pln, .sek, .sgd, .ugx, .zar]
    static let wiseScreenshotCurrencies: [CurrencyCode] = [.usd, .eur, .gbp, .aud, .nzd, .cad, .hkd, .huf, .php, .sgd]
    static let wiseOtherCurrency = "通用"

    static func bankTransfer() -> [FinanceReceivingFieldKind] { [.beneficiary, .bankName, .bankAddress, .bankAccountNumber, .iban, .bic, .instructions] }
    static func brokerageDeposit() -> [FinanceReceivingFieldKind] { [.beneficiary, .bankName, .bankAddress, .bankAccountNumber, .iban, .bic, .aba, .ultimateAccountNumber, .reference, .instructions] }
    /// Wise currencies without local account details use this international
    /// transfer shape. The account owner enters the actual IBAN/SWIFT shown by
    /// Wise; no local routing fields are invented here.
    static let wiseSwiftOnly: [FinanceReceivingFieldKind] = [.beneficiary, .iban, .bic, .bankNameAndAddress]

    static func wise(currency: CurrencyCode) -> [FinanceReceivingFieldKind] {
        if let override = loadOverrides()[currency.rawValue], !override.isEmpty { return override }
        switch currency {
        case .usd: return [.beneficiary, .accountType, .aba, .bankAccountNumber, .bankNameAndAddress, .bic]
        case .eur: return [.beneficiary, .iban, .bic, .bankNameAndAddress]
        case .gbp: return [.beneficiary, .bankAccountNumber, .sortCode, .iban, .bic, .bankNameAndAddress]
        case .aud: return [.beneficiary, .bsb, .bankAccountNumber, .bic, .bankNameAndAddress]
        case .nzd: return [.beneficiary, .bankAccountNumber, .bic, .bankNameAndAddress]
        case .cad: return [.beneficiary, .bankAccountNumber, .institutionNumber, .branchCode, .bic, .bankNameAndAddress]
        case .hkd: return [.beneficiary, .bankAccountNumber, .bankCode, .branchCode, .bic, .bankNameAndAddress]
        case .huf: return [.beneficiary, .bankAccountNumber, .iban, .bic, .bankNameAndAddress]
        case .php: return [.beneficiary, .bankAccountNumber, .bankCode, .bankNameAndAddress]
        case .sgd: return [.beneficiary, .bankCode, .bankAccountNumber, .bic, .bankNameAndAddress]
        case .aed: return wiseOtherConfigured()
        default: return wiseOtherConfigured()
        }
    }
    static func wiseOther() -> [FinanceReceivingFieldKind] { wiseSwiftOnly }
    static func wiseTemplate(for currencies: Set<CurrencyCode>) -> [FinanceReceivingFieldKind] {
        guard let currency = CurrencyCode.financialOrdered(currencies).first else { return wiseOtherConfigured() }
        return wiseScreenshotCurrencies.contains(currency) ? wise(currency: currency) : wiseOtherConfigured()
    }

    static func saveWise(currency: CurrencyCode, fields: [FinanceReceivingFieldKind], defaults: UserDefaults = .standard) {
        var values = loadOverrides(defaults: defaults)
        if fields == wiseOtherConfigured(defaults: defaults) { values.removeValue(forKey: currency.rawValue) }
        else { values[currency.rawValue] = fields }
        let encoded = values.mapValues { $0.map(\.rawValue) }; defaults.set(encoded, forKey: wiseOverridesKey)
    }
    static func saveWiseOther(fields: [FinanceReceivingFieldKind], defaults: UserDefaults = .standard) {
        var values = loadOverrides(defaults: defaults); values[wiseOtherCurrency] = fields
        defaults.set(values.mapValues { $0.map(\.rawValue) }, forKey: wiseOverridesKey)
    }
    static func wiseOtherConfigured(defaults: UserDefaults = .standard) -> [FinanceReceivingFieldKind] {
        loadOverrides(defaults: defaults)[wiseOtherCurrency] ?? wiseSwiftOnly
    }
    static func loadOverrides(defaults: UserDefaults = .standard) -> [String: [FinanceReceivingFieldKind]] {
        guard let raw = defaults.dictionary(forKey: wiseOverridesKey) as? [String: [String]] else { return [:] }
        var result = raw.reduce(into: [:]) { result, item in result[item.key] = item.value.compactMap(FinanceReceivingFieldKind.init(rawValue:)) }
        if result[wiseOtherCurrency] == nil, let legacy = result.removeValue(forKey: "其他") { result[wiseOtherCurrency] = legacy }
        let generic = result[wiseOtherCurrency] ?? wiseSwiftOnly
        result = result.filter { $0.key == wiseOtherCurrency || $0.value != generic }
        return result
    }
}
#endif
