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

    @Test func clearCachedSnapshotRemovesCurrentAndLegacyKeys() throws {
        let suiteName = "MyToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([CurrencyCode.usd.rawValue: "7.1"], forKey: "boc-currency-buying-rates-v1")
        defaults.set([CurrencyCode.usd.rawValue: "7.2"], forKey: "boc-currency-selling-rates-v1")
        defaults.set(Date(), forKey: "boc-currency-rates-date-v1")
        defaults.set("7.3", forKey: "stock-usd-cny-buying-rate-v1")
        defaults.set(Date(), forKey: "stock-usd-cny-buying-rate-date-v1")

        ExchangeRateRepository.clearCachedSnapshot(defaults: defaults)

        #expect(defaults.object(forKey: "boc-currency-buying-rates-v1") == nil)
        #expect(defaults.object(forKey: "boc-currency-selling-rates-v1") == nil)
        #expect(defaults.object(forKey: "boc-currency-rates-date-v1") == nil)
        #expect(defaults.object(forKey: "stock-usd-cny-buying-rate-v1") == nil)
        #expect(defaults.object(forKey: "stock-usd-cny-buying-rate-date-v1") == nil)
    }
}

struct HistoricalReferenceRateTests {
    @Test func filtersPrecedingBusinessDayAndPreservesDecimalRates() throws {
        let formatter = HistoricalExchangeRateService.formatter()
        let start = try #require(formatter.date(from: "2024-01-01"))
        let end = try #require(formatter.date(from: "2024-01-08"))
        let fixture = Data(#"{"base":"CNY","rates":{"2023-12-29":{"USD":0.125,"HKD":1},"2024-01-02":{"USD":0.125,"HKD":1}}}"#.utf8)
        let points = try HistoricalExchangeRateService.decodeResponse(fixture, from: start, through: end)
        #expect(points.count == 1)
        #expect(points[0].renminbiPerUnit[.usd] == 8)
        #expect(points[0].renminbiPerUnit[.hkd] == 1)
        #expect(points[0].renminbiPerUnit[.cny] == 1)
        let cache = HistoricalExchangeRateService.MonthCache(fetchedAt: end, through: end, points: points)
        #expect(try HistoricalExchangeRateService.decodeCache(JSONEncoder().encode(cache)) == cache)
        var future = cache
        future.version = 2
        #expect(throws: (any Error).self) { try HistoricalExchangeRateService.decodeCache(JSONEncoder().encode(future)) }
    }

    @Test func rejectsEmptyInvalidAndWrongBaseResponses() throws {
        let day = Date(timeIntervalSince1970: 1704153600)
        for fixture in [
            #"{"base":"CNY","rates":{}}"#,
            #"{"base":"USD","rates":{"2024-01-02":{"USD":1}}}"#,
            #"{"base":"CNY","rates":{"2024-01-02":{"USD":0}}}"#,
            #"{"base":"CNY","rates":{"2024-01-02":{"USD":"bad"}}}"#
        ] {
            #expect(throws: (any Error).self) { try HistoricalExchangeRateService.decodeResponse(Data(fixture.utf8), from: day, through: day) }
        }
    }
}
