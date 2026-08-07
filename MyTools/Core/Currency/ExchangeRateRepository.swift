import Foundation

struct ExchangeRateSnapshot: Sendable {
    let usdRenminbiBuyingRate: Decimal?
    let renminbiBuyingRates: [CurrencyCode: Decimal]
    let renminbiSellingRates: [CurrencyCode: Decimal]
    let updatedAt: Date?
}

actor ExchangeRateRepository {
    private enum DefaultsKey {
        static let usdBuyingRate = "stock-usd-cny-buying-rate-v1"
        static let exchangeRateDate = "stock-usd-cny-buying-rate-date-v1"
        static let buyingRates = "boc-currency-buying-rates-v1"
        static let sellingRates = "boc-currency-selling-rates-v1"
    }

    private let service = ForeignExchangeRateService()

    static func loadCachedSnapshot(defaults: UserDefaults = .standard) -> ExchangeRateSnapshot {
        let usdRate = defaults.string(forKey: DefaultsKey.usdBuyingRate)
            .flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        var buyingRates = decimalRates(
            from: defaults.dictionary(forKey: DefaultsKey.buyingRates) as? [String: String]
        )
        let sellingRates = decimalRates(
            from: defaults.dictionary(forKey: DefaultsKey.sellingRates) as? [String: String]
        )
        if let usdRate { buyingRates[.usd] = usdRate }

        return ExchangeRateSnapshot(
            usdRenminbiBuyingRate: usdRate,
            renminbiBuyingRates: buyingRates,
            renminbiSellingRates: sellingRates,
            updatedAt: defaults.object(forKey: DefaultsKey.exchangeRateDate) as? Date
        )
    }

    func fetchSnapshot() async throws -> ExchangeRateSnapshot {
        let rates = try await service.fetchRates()
        var buyingRates: [CurrencyCode: Decimal] = [.cny: 1]
        var sellingRates: [CurrencyCode: Decimal] = [.cny: 1]
        for rate in rates {
            guard let currency = CurrencyCode(rawValue: rate.currencyCode) else { continue }
            buyingRates[currency] = rate.renminbiBuyingPerUnit
            sellingRates[currency] = rate.renminbiSellingPerUnit
        }
        guard let usdRate = buyingRates[.usd] else {
            throw ForeignExchangeRateError.rateUnavailable
        }
        return ExchangeRateSnapshot(
            usdRenminbiBuyingRate: usdRate,
            renminbiBuyingRates: buyingRates,
            renminbiSellingRates: sellingRates,
            updatedAt: rates.map(\.updatedAt).max()
        )
    }

    func save(_ snapshot: ExchangeRateSnapshot, defaults: UserDefaults = .standard) {
        if let usdRate = snapshot.usdRenminbiBuyingRate {
            defaults.set(
                NSDecimalNumber(decimal: usdRate).stringValue,
                forKey: DefaultsKey.usdBuyingRate
            )
        }
        defaults.set(snapshot.updatedAt, forKey: DefaultsKey.exchangeRateDate)
        defaults.set(
            stringRates(snapshot.renminbiBuyingRates),
            forKey: DefaultsKey.buyingRates
        )
        defaults.set(
            stringRates(snapshot.renminbiSellingRates),
            forKey: DefaultsKey.sellingRates
        )
    }

    private static func decimalRates(from values: [String: String]?) -> [CurrencyCode: Decimal] {
        guard let values else { return [:] }
        return values.reduce(into: [:]) { result, entry in
            guard let currency = CurrencyCode(rawValue: entry.key),
                  let rate = Decimal(
                    string: entry.value,
                    locale: Locale(identifier: "en_US_POSIX")
                  ) else { return }
            result[currency] = rate
        }
    }

    private func stringRates(_ rates: [CurrencyCode: Decimal]) -> [String: String] {
        rates.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = NSDecimalNumber(decimal: entry.value).stringValue
        }
    }
}
