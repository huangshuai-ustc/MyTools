import Foundation

struct ExchangeRateSnapshot: Sendable {
    let renminbiBuyingRates: [CurrencyCode: Decimal]
    let renminbiSellingRates: [CurrencyCode: Decimal]
    let updatedAt: Date?
}

actor ExchangeRateRepository {
    private enum DefaultsKey {
        static let buyingRates = "boc-currency-buying-rates-v1"
        static let sellingRates = "boc-currency-selling-rates-v1"
        static let updatedAt = "boc-currency-rates-date-v1"
        static let legacyUSDBuyingRate = "stock-usd-cny-buying-rate-v1"
        static let legacyUpdatedAt = "stock-usd-cny-buying-rate-date-v1"
    }

    private let service = ForeignExchangeRateService()

    static func loadCachedSnapshot(defaults: UserDefaults = .standard) -> ExchangeRateSnapshot {
        var buyingRates = decimalRates(
            from: defaults.dictionary(forKey: DefaultsKey.buyingRates) as? [String: String]
        )
        let sellingRates = decimalRates(
            from: defaults.dictionary(forKey: DefaultsKey.sellingRates) as? [String: String]
        )
        var migratedLegacyValue = false
        if buyingRates[.usd] == nil,
           let legacyUSD = defaults.string(forKey: DefaultsKey.legacyUSDBuyingRate)
            .flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }) {
            buyingRates[.usd] = legacyUSD
            migratedLegacyValue = true
        }
        var updatedAt = defaults.object(forKey: DefaultsKey.updatedAt) as? Date
        if updatedAt == nil,
           let legacyUpdatedAt = defaults.object(forKey: DefaultsKey.legacyUpdatedAt) as? Date {
            updatedAt = legacyUpdatedAt
            migratedLegacyValue = true
        }
        if migratedLegacyValue {
            defaults.set(stringRates(buyingRates), forKey: DefaultsKey.buyingRates)
            defaults.set(updatedAt, forKey: DefaultsKey.updatedAt)
        }
        defaults.removeObject(forKey: DefaultsKey.legacyUSDBuyingRate)
        defaults.removeObject(forKey: DefaultsKey.legacyUpdatedAt)

        return ExchangeRateSnapshot(
            renminbiBuyingRates: buyingRates,
            renminbiSellingRates: sellingRates,
            updatedAt: updatedAt
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
        guard buyingRates[.usd] != nil else {
            throw ForeignExchangeRateError.rateUnavailable
        }
        return ExchangeRateSnapshot(
            renminbiBuyingRates: buyingRates,
            renminbiSellingRates: sellingRates,
            updatedAt: rates.map(\.updatedAt).max()
        )
    }

    func save(_ snapshot: ExchangeRateSnapshot, defaults: UserDefaults = .standard) {
        defaults.set(snapshot.updatedAt, forKey: DefaultsKey.updatedAt)
        defaults.set(
            Self.stringRates(snapshot.renminbiBuyingRates),
            forKey: DefaultsKey.buyingRates
        )
        defaults.set(
            Self.stringRates(snapshot.renminbiSellingRates),
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

    private static func stringRates(_ rates: [CurrencyCode: Decimal]) -> [String: String] {
        rates.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = NSDecimalNumber(decimal: entry.value).stringValue
        }
    }
}
