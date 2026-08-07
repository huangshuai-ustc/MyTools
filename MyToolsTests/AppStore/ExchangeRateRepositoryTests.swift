import Foundation
import Testing
@testable import MyTools

struct ExchangeRateRepositoryTests {
    @Test func legacyUSDRateIsPersistedBeforeLegacyKeysAreRemoved() throws {
        let suiteName = "MyToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        defaults.set("7.1234", forKey: "stock-usd-cny-buying-rate-v1")
        defaults.set(date, forKey: "stock-usd-cny-buying-rate-date-v1")

        let migrated = ExchangeRateRepository.loadCachedSnapshot(defaults: defaults)
        let reloaded = ExchangeRateRepository.loadCachedSnapshot(defaults: defaults)

        #expect(migrated.renminbiBuyingRates[.usd] == Decimal(string: "7.1234"))
        #expect(migrated.updatedAt == date)
        #expect(reloaded.renminbiBuyingRates[.usd] == Decimal(string: "7.1234"))
        #expect(reloaded.updatedAt == date)
        #expect(defaults.object(forKey: "stock-usd-cny-buying-rate-v1") == nil)
        #expect(defaults.object(forKey: "stock-usd-cny-buying-rate-date-v1") == nil)
    }

    @Test func currentCurrencyDictionaryTakesPriorityOverLegacyUSDValue() throws {
        let suiteName = "MyToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [CurrencyCode.usd.rawValue: "7.2000", CurrencyCode.hkd.rawValue: "0.9200"],
            forKey: "boc-currency-buying-rates-v1"
        )
        defaults.set("6.8000", forKey: "stock-usd-cny-buying-rate-v1")

        let snapshot = ExchangeRateRepository.loadCachedSnapshot(defaults: defaults)

        #expect(snapshot.renminbiBuyingRates[.usd] == Decimal(string: "7.2000"))
        #expect(snapshot.renminbiBuyingRates[.hkd] == Decimal(string: "0.9200"))
        #expect(defaults.object(forKey: "stock-usd-cny-buying-rate-v1") == nil)
    }
}
