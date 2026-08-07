import Foundation
import Testing
@testable import MyTools

struct StockQuoteProviderParsingTests {
    @Test(arguments: [
        (StockMarket.aShare, "600519", "20260807103045", "A Share Name"),
        (StockMarket.hongKong, "00700", "2026/08/07 10:30:45", "HK Name"),
        (StockMarket.unitedStates, "VOO", "2026-08-07 10:30:45", "US English Name")
    ])
    func tencentParsesEachMarket(
        market: StockMarket,
        symbol: String,
        timestamp: String,
        expectedName: String
    ) async {
        let stock = makeStock(market: market, symbol: symbol)
        var fields = Array(repeating: "", count: 47)
        fields[1] = market == .unitedStates ? "US Local Name" : expectedName
        fields[2] = symbol
        fields[3] = "105"
        fields[4] = "100"
        fields[30] = timestamp
        fields[32] = "5"
        if market == .unitedStates { fields[46] = expectedName }
        let identifier = StockQuoteProviderSupport.tencentIdentifier(for: stock)!
        let data = Data("v_\(identifier)=\"\(fields.joined(separator: "~"))\";".utf8)
        let provider = TencentStockQuoteProvider(
            httpClient: StubStockQuoteHTTPClient(responseData: data)
        )

        let quote = await provider.fetchQuotes(for: [stock])[stock.id]

        #expect(quote?.symbol == symbol)
        #expect(quote?.name == expectedName)
        #expect(quote?.latestPrice == 105)
        #expect(quote?.previousClose == 100)
        #expect(quote?.changePercent == Decimal(string: "0.05"))
        #expect(quote?.source == "腾讯证券")
    }

    @Test(arguments: [
        (StockMarket.aShare, "600519"),
        (StockMarket.hongKong, "00700"),
        (StockMarket.unitedStates, "VOO")
    ])
    func sinaParsesEachMarket(market: StockMarket, symbol: String) async {
        let stock = makeStock(market: market, symbol: symbol)
        let fields: [String]
        switch market {
        case .aShare:
            var values = Array(repeating: "", count: 32)
            values[0] = "A Share Name"
            values[2] = "100"
            values[3] = "105"
            values[30] = "2026-08-07"
            values[31] = "10:30:45"
            fields = values
        case .hongKong:
            var values = Array(repeating: "", count: 19)
            values[0] = "HK Chinese Name"
            values[1] = "HK Name"
            values[3] = "100"
            values[6] = "105"
            values[17] = "2026/08/07"
            values[18] = "10:30:45"
            fields = values
        case .unitedStates:
            fields = ["US Name", "105", "5", "2026-08-07 22:30:45", "5"]
        }
        let identifier = StockQuoteProviderSupport.sinaIdentifier(for: stock)
        let data = Data("var hq_str_\(identifier)=\"\(fields.joined(separator: ","))\";".utf8)
        let provider = SinaStockQuoteProvider(
            httpClient: StubStockQuoteHTTPClient(responseData: data)
        )

        let quote = await provider.fetchQuotes(for: [stock])[stock.id]

        #expect(quote?.symbol == symbol)
        #expect(quote?.latestPrice == 105)
        #expect(quote?.previousClose == 100)
        #expect(quote?.changePercent == Decimal(string: "0.05"))
        #expect(quote?.source == "新浪财经")
    }

    @Test func eastmoneyAppliesPriceScaleFromPayload() async throws {
        let data = try json([
            "data": [
                "f43": "12345",
                "f57": "600519",
                "f58": "Example",
                "f59": 2,
                "f60": 12000,
                "f170": "288"
            ]
        ])
        let provider = EastmoneyStockQuoteProvider(
            httpClient: StubStockQuoteHTTPClient(responseData: data)
        )

        let quote = await provider.fetchQuote(
            for: makeStock(market: .aShare, symbol: "600519")
        )

        #expect(quote?.latestPrice == Decimal(string: "123.45"))
        #expect(quote?.previousClose == 120)
        #expect(quote?.changePercent == Decimal(string: "2.88"))
        #expect(quote?.source == "东方财富")
    }

    @Test func nasdaqPrefersRegularSessionOverExtendedSession() async throws {
        let primary = nasdaqPrice(
            price: "$105.00",
            change: "5.00",
            percent: "5.00%",
            timestamp: "Aug 7, 2026 4:00 PM"
        )
        let secondary = nasdaqPrice(
            price: "$99.00",
            change: "-1.00",
            percent: "-1.00%",
            timestamp: "Closed at Aug 7, 2026 6:00 PM ET"
        )
        let data = try json([
            "data": [
                "symbol": "VOO",
                "companyName": "Vanguard ETF",
                "primaryData": primary,
                "secondaryData": secondary
            ]
        ])
        let provider = NasdaqStockQuoteProvider(
            httpClient: StubStockQuoteHTTPClient(responseData: data)
        )

        let quote = await provider.fetchQuote(
            for: makeStock(market: .unitedStates, symbol: "VOO")
        )

        #expect(quote?.latestPrice == 105)
        #expect(quote?.previousClose == 100)
        #expect(quote?.changePercent == Decimal(string: "0.05"))
        #expect(quote?.source == "Nasdaq")
    }

    @Test func yahooUsesChartPreviousCloseForChange() async throws {
        let data = try json([
            "chart": [
                "result": [[
                    "meta": [
                        "symbol": "VOO",
                        "longName": "Vanguard ETF",
                        "regularMarketPrice": 105,
                        "chartPreviousClose": 100,
                        "regularMarketTime": 1_786_120_200
                    ]
                ]]
            ]
        ])
        let provider = YahooStockQuoteProvider(
            httpClient: StubStockQuoteHTTPClient(responseData: data)
        )

        let quote = await provider.fetchQuote(
            for: makeStock(market: .unitedStates, symbol: "VOO")
        )

        #expect(quote?.name == "Vanguard ETF")
        #expect(quote?.latestPrice == 105)
        #expect(quote?.previousClose == 100)
        #expect(quote?.changePercent == Decimal(string: "0.05"))
        #expect(quote?.updatedAt == Date(timeIntervalSince1970: 1_786_120_200))
    }

    @Test func officialShanghaiProviderParsesSnapshotArray() async throws {
        let data = try json([
            "snap": ["Example SSE", 105, 100, 5, 20260807, 103045]
        ])
        let provider = OfficialAShareStockQuoteProvider(
            httpClient: StubStockQuoteHTTPClient(responseData: data)
        )

        let quote = await provider.fetchQuote(
            for: makeStock(market: .aShare, symbol: "600519")
        )

        #expect(quote?.name == "Example SSE")
        #expect(quote?.latestPrice == 105)
        #expect(quote?.previousClose == 100)
        #expect(quote?.changePercent == Decimal(string: "0.05"))
        #expect(quote?.source == "上海证券交易所")
    }

    @Test func officialShenzhenProviderParsesNamedPayload() async throws {
        let data = try json([
            "data": [
                "name": "Example SZSE",
                "close": "100",
                "now": "105",
                "deltaPercent": "5",
                "marketTime": "2026-08-07 10:30:45"
            ]
        ])
        let provider = OfficialAShareStockQuoteProvider(
            httpClient: StubStockQuoteHTTPClient(responseData: data)
        )

        let quote = await provider.fetchQuote(
            for: makeStock(market: .aShare, symbol: "000001")
        )

        #expect(quote?.name == "Example SZSE")
        #expect(quote?.latestPrice == 105)
        #expect(quote?.previousClose == 100)
        #expect(quote?.changePercent == Decimal(string: "0.05"))
        #expect(quote?.source == "深圳证券交易所")
    }

    @Test func primaryProvidersSplitRequestsIntoFortyStockBatches() async {
        let stocks = (0..<81).map { index in
            makeStock(market: .aShare, symbol: String(format: "%06d", index))
        }
        let tencentClient = StubStockQuoteHTTPClient(responseData: Data())
        let sinaClient = StubStockQuoteHTTPClient(responseData: Data())

        _ = await TencentStockQuoteProvider(httpClient: tencentClient)
            .fetchQuotes(for: stocks)
        _ = await SinaStockQuoteProvider(httpClient: sinaClient)
            .fetchQuotes(for: stocks)

        #expect(await tencentClient.recordedRequests().count == 3)
        #expect(await sinaClient.recordedRequests().count == 3)
    }

    private func makeStock(market: StockMarket, symbol: String) -> StockHolding {
        StockHolding(market: market, symbol: symbol)
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func nasdaqPrice(
        price: String,
        change: String,
        percent: String,
        timestamp: String
    ) -> [String: Any] {
        [
            "lastSalePrice": price,
            "netChange": change,
            "percentageChange": percent,
            "lastTradeTimestamp": timestamp,
            "isRealTime": true
        ]
    }
}
