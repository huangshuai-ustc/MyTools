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

    // AUDIT-088：无读取方的牌价历史不再写入，读取缓存时顺带清掉旧数据。
    @Test func unusedRateHistoryIsNoLongerWrittenAndLegacyCopyIsRemoved() async throws {
        let suiteName = "MyToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("[]".utf8), forKey: "boc-currency-rates-history-v1")
        _ = ExchangeRateRepository.loadCachedSnapshot(defaults: defaults)
        #expect(defaults.object(forKey: "boc-currency-rates-history-v1") == nil)

        let snapshot = ExchangeRateSnapshot(renminbiBuyingRates: [.usd: 7], renminbiSellingRates: [.usd: 7.1], updatedAt: Date())
        // 同一 suite 的新实例：UserDefaults 不是 Sendable，不能把上面的实例送进 actor。
        await ExchangeRateRepository().save(snapshot, defaults: UserDefaults(suiteName: suiteName)!)
        #expect(defaults.object(forKey: "boc-currency-rates-history-v1") == nil)
        #expect(ExchangeRateRepository.loadCachedSnapshot(defaults: defaults).renminbiBuyingRates[.usd] == 7)
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
        defaults.set(Data("[]".utf8), forKey: "boc-currency-rates-history-v1")

        ExchangeRateRepository.clearCachedSnapshot(defaults: defaults)

        #expect(defaults.object(forKey: "boc-currency-buying-rates-v1") == nil)
        #expect(defaults.object(forKey: "boc-currency-selling-rates-v1") == nil)
        #expect(defaults.object(forKey: "boc-currency-rates-date-v1") == nil)
        #expect(defaults.object(forKey: "stock-usd-cny-buying-rate-v1") == nil)
        #expect(defaults.object(forKey: "stock-usd-cny-buying-rate-date-v1") == nil)
        #expect(defaults.object(forKey: "boc-currency-rates-history-v1") == nil)
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

// AUDIT-045：中行页面币种名与现钞回退、部分缺价时的合计口径。
struct BankOfChinaRateParsingTests {
    private static let html = """
    <tr data-currency='以色列谢克尔'>
        <td>以色列谢克尔</td> <td></td> <td>195.3</td> <td></td> <td>238.7</td> <td>217.98</td>
        <td class="pjrq">2026/10/14 20:35:14</td> <td>20:35:14</td>
    </tr>
    <tr data-currency='美元'>
        <td>美元</td> <td>668.43</td> <td>668.43</td> <td>671.24</td> <td>671.24</td> <td>672.49</td>
        <td class="pjrq">2026/10/14 20:35:14</td> <td>20:35:14</td>
    </tr>
    """

    @Test func spotPricesWinAndCashPricesFillMissingSpotColumns() throws {
        let rates = ForeignExchangeRateService.parseRates(from: Self.html)
        let usd = try #require(rates.first { $0.currencyCode == "USD" })
        #expect(usd.renminbiBuyingPerUnit == Decimal(string: "6.6843"))
        #expect(usd.renminbiSellingPerUnit == Decimal(string: "6.7124"))
        let ils = try #require(rates.first { $0.currencyCode == "ILS" })
        #expect(ils.renminbiBuyingPerUnit == Decimal(string: "1.953"))
        #expect(ils.renminbiSellingPerUnit == Decimal(string: "2.387"))
        #expect(CurrencyCode.ugx.bankOfChinaName == nil)
    }

#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
    @Test func lossSummaryKeepsPricedTotalAndCountsMissingRates() {
        let priced = CurrencyExchangeRecord(soldCurrency: .cny, boughtCurrency: .usd, soldAmount: 700, boughtAmount: 100)
        let unpriced = CurrencyExchangeRecord(soldCurrency: .cny, boughtCurrency: .ugx, soldAmount: 10, boughtAmount: 5_000)
        let rates: [CurrencyCode: Decimal] = [.cny: 1, .usd: 7]

        let summary = CurrencyExchangeLossSummary(records: [priced, unpriced], buyingRates: rates)
        #expect(summary.total == 0)
        #expect(summary.missingCount == 1)
        #expect(CurrencyExchangeLossSummary(records: [unpriced], buyingRates: rates).total == nil)
        #expect(CurrencyExchangeLossSummary(records: [], buyingRates: rates).total == 0)
    }

    // AUDIT-077：缺键与旧 `oneSoldToBought` 口径的记录仍可解码，且日期归一到中午。
    @Test func legacyExchangeRecordsDecodeWithDefaultsAndConvertedConvention() throws {
        let legacy = Data(#"{"soldCurrency":"CNY","boughtCurrency":"USD","quoteConvention":"oneSoldToBought","quotedRate":0.14,"soldAmount":700,"boughtAmount":98,"exchangedAt":0}"#.utf8)
        let record = try JSONDecoder().decode(CurrencyExchangeRecord.self, from: legacy)
        #expect(record.quoteConvention == .hundredSoldToBought)
        #expect(record.quotedRate == 14)
        #expect(record.expectedBoughtAmount == 98)
        #expect(record.fee == 0)
        #expect(Calendar.autoupdatingCurrent.component(.hour, from: record.exchangedAt) == 12)

        let minimal = try JSONDecoder().decode(CurrencyExchangeRecord.self, from: Data(#"{"soldAmount":1}"#.utf8))
        #expect(minimal.quoteConvention == .hundredSoldToBought)
        let roundTrip = try JSONDecoder().decode(CurrencyExchangeRecord.self, from: JSONEncoder().encode(record))
        #expect(roundTrip == record)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CurrencyExchangeRecord.self, from: Data(#"{"quoteConvention":"bogus"}"#.utf8))
        }
    }

    // AUDIT-076：存储、分组用同一日历，月末记录不会被分到下个月。
    @Test(arguments: ["America/Los_Angeles", "Asia/Shanghai", "Pacific/Auckland"])
    func monthGroupingUsesStorageCalendar(timeZoneID: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZoneID))
        for (month, day) in [(10, 31), (12, 31)] {
            let picked = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 23)))
            let stored = CurrencyExchangeRecord.noon(on: picked, calendar: calendar)
            let group = CurrencyExchangeRecord.monthStart(of: stored, calendar: calendar)
            #expect(calendar.dateComponents([.year, .month, .day], from: stored) == DateComponents(year: 2026, month: month, day: day))
            #expect(calendar.dateComponents([.year, .month], from: group) == DateComponents(year: 2026, month: month))
        }
    }
#endif
}
