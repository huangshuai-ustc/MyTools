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

    @Test func eastmoneyFundamentalsApplyRatioScaleFromPayload() async throws {
        let fetchedAt = StockChartFixtures.date(2026, 8, 10)
        let data = try json([
            "data": [
                "f162": "1547",
                "f167": 715
            ]
        ])
        let client = StubStockQuoteHTTPClient(responseData: data)
        let provider = EastmoneyStockFundamentalProvider(
            httpClient: client,
            now: { fetchedAt }
        )

        let snapshot = await provider.fetchFundamentals(
            for: makeStock(market: .aShare, symbol: "600519")
        )

        #expect(snapshot?.priceEarningsRatioTTM == 15.47)
        #expect(snapshot?.priceBookRatioMRQ == 7.15)
        #expect(snapshot?.source == "东方财富")
        #expect(snapshot?.asOfDate == fetchedAt)
        let request = await client.recordedRequests().first
        #expect(request?.url?.query?.contains("f162") == true)
        #expect(request?.url?.query?.contains("f167") == true)
    }

    @Test func yahooFundamentalsParseTimeseriesAndDeriveFinancialMetrics() async throws {
        let data = try json([
            "timeseries": [
                "result": [
                    timeSeries(
                        type: "trailingPeRatio",
                        values: [("2026-08-07", 24.5)]
                    ),
                    timeSeries(
                        type: "trailingPbRatio",
                        values: [("2026-08-07", 4.25)]
                    ),
                    directTimeSeries(
                        type: "trailingDividendYield",
                        values: [("2026-07-31", 0.012)]
                    ),
                    timeSeries(
                        type: "annualTotalRevenue",
                        values: [("2024-12-31", 1_000), ("2025-12-31", 1_200)]
                    ),
                    timeSeries(
                        type: "annualNetIncome",
                        values: [("2024-12-31", 100), ("2025-12-31", 120)]
                    ),
                    timeSeries(
                        type: "annualStockholdersEquity",
                        values: [("2025-12-31", 600)]
                    )
                ]
            ]
        ])
        let client = StubStockQuoteHTTPClient(responseData: data)
        let provider = YahooStockFundamentalProvider(
            httpClient: client,
            now: { StockChartFixtures.date(2026, 8, 10) }
        )

        let snapshot = await provider.fetchFundamentals(
            for: makeStock(market: .unitedStates, symbol: "AAPL")
        )

        #expect(snapshot?.priceEarningsRatioTTM == 24.5)
        #expect(snapshot?.priceBookRatioMRQ == 4.25)
        #expect(snapshot?.dividendYield == 0.012)
        #expect(snapshot?.returnOnEquity == 0.2)
        #expect(snapshot?.netProfitMargin == 0.1)
        #expect(snapshot.map { abs($0.revenueGrowth! - 0.2) < 0.000_001 } == true)
        #expect(snapshot.map { abs($0.earningsGrowth! - 0.2) < 0.000_001 } == true)
        #expect(snapshot?.availableMetricCount == 7)
        let request = await client.recordedRequests().first
        #expect(request?.url?.host == "query2.finance.yahoo.com")
        #expect(request?.url?.path.contains("fundamentals-timeseries") == true)
    }

    @Test func fundamentalServiceMergesProvidersAndHonorsCache() async throws {
        let fetchedAt = StockChartFixtures.date(2026, 8, 10)
        let eastmoney = StubStockFundamentalProvider(snapshot: StockFundamentalSnapshot(
            asOfDate: fetchedAt,
            source: "东方财富",
            priceEarningsRatioTTM: 15,
            priceBookRatioMRQ: 2
        ))
        let yahoo = StubStockFundamentalProvider(snapshot: StockFundamentalSnapshot(
            asOfDate: fetchedAt,
            source: "Yahoo Finance",
            dividendYield: 0.03,
            returnOnEquity: 0.18
        ))
        let service = StockFundamentalService(
            providers: StockFundamentalProviders(eastmoney: eastmoney, yahoo: yahoo),
            now: { fetchedAt },
            cacheLifetime: 24 * 60 * 60
        )
        let stock = makeStock(market: .aShare, symbol: "600519")

        let first = await service.fundamentals(for: stock, forceRefresh: false)
        _ = await service.fundamentals(for: stock, forceRefresh: false)

        #expect(first?.priceEarningsRatioTTM == 15)
        #expect(first?.priceBookRatioMRQ == 2)
        #expect(first?.dividendYield == 0.03)
        #expect(first?.returnOnEquity == 0.18)
        #expect(first?.source.contains("东方财富") == true)
        #expect(first?.source.contains("Yahoo Finance") == true)
        #expect(await eastmoney.requestCount() == 1)
        #expect(await yahoo.requestCount() == 1)

        _ = await service.fundamentals(for: stock, forceRefresh: true)

        #expect(await eastmoney.requestCount() == 2)
        #expect(await yahoo.requestCount() == 2)
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

    @Test func stockSearchParsesTencentCandidatesAcrossMarkets() {
        let response = #"v_hint="sh~600519~\u8d35\u5dde\u8305\u53f0~gzmt~GP^hk~700~\u817e\u8baf\u63a7\u80a1~txkg~GP^us~ko.n~\u53ef\u53e3\u53ef\u4e50~kkkl~GP^us~coke.oq~\u53ef\u53e3\u53ef\u4e50\u88c5\u74f6~kkklzp~GP";"#
        let results = StockSearchProviderSupport.parseTencent(response)

        #expect(results.contains(StockSearchResult(market: .aShare, symbol: "600519", name: "贵州茅台")))
        #expect(results.contains(StockSearchResult(market: .hongKong, symbol: "00700", name: "腾讯控股")))
        #expect(results.contains(StockSearchResult(
            market: .unitedStates,
            symbol: "KO",
            name: "可口可乐",
            detail: "NYSE · 普通股"
        )))
        #expect(results.contains(StockSearchResult(
            market: .unitedStates,
            symbol: "COKE",
            name: "可口可乐装瓶",
            detail: "NASDAQ · 普通股"
        )))
        #expect(!results.contains(where: { $0.name == "sh" || $0.name == "GP" }))
        #expect(!results.contains(where: { $0.name.contains("\\u") }))
    }

    @Test func stockSearchPreservesUnitedStatesShareClassSuffix() {
        #expect(
            StockSearchProviderSupport.normalizedTencentSymbol("brk.b", market: .unitedStates)
                == "BRK.B"
        )
    }

    @Test func stockSearchUsesTencentQuoteNameForOfficialAShareAbbreviation() async {
        var quoteFields = Array(repeating: "", count: 47)
        quoteFields[1] = "C宇树-W"
        quoteFields[2] = "688836"
        quoteFields[3] = "717"
        quoteFields[4] = "700"
        quoteFields[30] = "20260820103045"
        quoteFields[32] = "2.43"
        let client = StockSearchRoutingHTTPClient(
            tencentSearchData: Data(
                #"v_hint="sh~688836~\u5b87\u6811\u79d1\u6280W~yskjw~GP-A-KCB";"#.utf8
            ),
            tencentQuoteData: gb18030Data(
                "v_sh688836=\"\(quoteFields.joined(separator: "~"))\";"
            ),
            yahooSearchData: Data(#"{"quotes":[]}"#.utf8)
        )

        let results = await StockSearchService(httpClient: client)
            .search(query: "宇树", market: .aShare, limit: 8)

        #expect(results == [
            StockSearchResult(
                market: .aShare,
                symbol: "688836",
                name: "C宇树-W",
                alias: "宇树科技W",
                detail: "普通股 · 科创板"
            )
        ])
    }

    @Test func stockSearchRanksPrimaryPDDAndUsesShortChineseAlias() async throws {
        var pddFields = Array(repeating: "", count: 47)
        pddFields[1] = "拼多多"
        pddFields[2] = "PDD.OQ"
        pddFields[3] = "90.20"
        pddFields[4] = "87.27"
        pddFields[30] = "2026-08-19 16:00:01"
        pddFields[32] = "3.36"
        pddFields[46] = "Pdd Holdings Inc"

        var pddlFields = Array(repeating: "", count: 47)
        pddlFields[1] = "2倍做多拼多多ETF-GraniteShares"
        pddlFields[2] = "PDDL.OQ"
        pddlFields[3] = "14.85"
        pddlFields[4] = "13.91"
        pddlFields[30] = "2026-08-19 16:00:01"
        pddlFields[32] = "6.80"
        pddlFields[46] = "Graniteshares 2X Long Pdd Daily Etf"

        let yahooData = try json([
            "quotes": [
                [
                    "symbol": "PDD",
                    "shortname": "PDD Holdings Inc.",
                    "longname": "PDD Holdings Inc.",
                    "quoteType": "EQUITY",
                    "exchange": "NMS",
                    "exchDisp": "NASDAQ",
                    "typeDisp": "Equity"
                ],
                [
                    "symbol": "PDDL",
                    "shortname": "GraniteShares 2x Long PDD Daily",
                    "quoteType": "ETF",
                    "exchange": "NGM",
                    "exchDisp": "NASDAQ",
                    "typeDisp": "ETF"
                ],
                [
                    "symbol": "0A2S.L",
                    "shortname": "PDD Holdings Inc.",
                    "quoteType": "EQUITY",
                    "exchange": "LSE",
                    "exchDisp": "London"
                ]
            ]
        ])
        let client = StockSearchRoutingHTTPClient(
            tencentSearchData: Data(
                #"v_hint="us~pdd.oq~Pdd~pdd~GP^us~pddl.oq~2\u500d\u505a\u591a\u62fc\u591a\u591aetfgraniteshares~2bzdpddetfgraniteshares~GP";"#.utf8
            ),
            tencentQuoteData: gb18030Data(
                "v_usPDD=\"\(pddFields.joined(separator: "~"))\";" +
                "v_usPDDL=\"\(pddlFields.joined(separator: "~"))\";"
            ),
            yahooSearchData: yahooData
        )

        let results = await StockSearchService(httpClient: client)
            .search(query: "拼多多", market: .unitedStates, limit: 8)

        #expect(results == [
            StockSearchResult(
                market: .unitedStates,
                symbol: "PDD",
                name: "PDD Holdings Inc.",
                alias: "拼多多",
                detail: "NASDAQ · 普通股",
                source: .yahoo
            ),
            StockSearchResult(
                market: .unitedStates,
                symbol: "PDDL",
                name: "GraniteShares 2x Long PDD Daily",
                detail: "NASDAQ · ETF",
                source: .yahoo
            )
        ])
    }

    @Test func stockSearchUsesBrokerShortNameInsteadOfQueryForMicron() async {
        var quoteFields = Array(repeating: "", count: 47)
        quoteFields[1] = "美光科技"
        quoteFields[2] = "MU.OQ"
        quoteFields[3] = "100"
        quoteFields[4] = "99"
        quoteFields[30] = "2026-08-20 16:00:01"
        quoteFields[32] = "1.01"
        quoteFields[46] = "Micron Technology, Inc."
        let client = StockSearchRoutingHTTPClient(
            tencentSearchData: Data(
                #"v_hint="us~mu.oq~美光~mg~GP";"#.utf8
            ),
            tencentQuoteData: gb18030Data(
                "v_usMU=\"\(quoteFields.joined(separator: "~"))\";"
            ),
            yahooSearchData: Data(#"{"quotes":[]}"#.utf8)
        )

        let results = await StockSearchService(httpClient: client)
            .search(query: "美光", market: .unitedStates, limit: 8)

        #expect(results == [
            StockSearchResult(
                market: .unitedStates,
                symbol: "MU",
                name: "Micron Technology, Inc.",
                alias: "美光科技",
                detail: "NASDAQ · 普通股"
            )
        ])
    }

    @Test func stockSearchKeepsProviderRelevanceForCocaColaFamily() async {
        let client = StockSearchRoutingHTTPClient(
            tencentSearchData: Data(
                #"v_hint="us~ko.n~\u53ef\u53e3\u53ef\u4e50~kkkl~GP^us~ccep.oq~\u53ef\u53e3\u53ef\u4e50\u6b27\u6d32\u592a\u5e73\u6d0b~kkkloztpy~GP^us~ccojy.ps~\u53ef\u53e3\u53ef\u4e50\u74f6\u88c5\u65e5\u672c~kkklpzrb~GP^us~coke.oq~\u53ef\u53e3\u53ef\u4e50\u88c5\u74f6~kkklzp~GP^us~kof.n~\u53ef\u53e3\u53ef\u4e50\u51e1\u8428\u74f6\u88c5~kkklfspz~GP";"#.utf8
            ),
            tencentQuoteData: Data(),
            yahooSearchData: Data(#"{"quotes":[]}"#.utf8)
        )

        let results = await StockSearchService(httpClient: client)
            .search(query: "可口可乐", market: .unitedStates, limit: 8)

        #expect(Array(results.map(\.symbol).prefix(5)) == ["KO", "COKE", "CCEP", "KOF", "CCOJY"])
    }

    @Test func stockSearchPromotesShortChineseCompanyNameForColaQuery() async {
        let client = StockSearchRoutingHTTPClient(
            tencentSearchData: Data(
                #"v_hint="us~ccep.oq~\u53ef\u53e3\u53ef\u4e50\u6b27\u6d32\u592a\u5e73\u6d0b~kkkloztpy~GP^us~ccojy.ps~\u53ef\u53e3\u53ef\u4e50\u74f6\u88c5\u65e5\u672c~kkklpzrb~GP^us~coke.oq~\u53ef\u53e3\u53ef\u4e50\u88c5\u74f6~kkklzp~GP^us~ko.n~\u53ef\u53e3\u53ef\u4e50~kkkl~GP^us~kof.n~\u53ef\u53e3\u53ef\u4e50\u51e1\u8428\u74f6\u88c5~kkklfspz~GP^us~pep.oq~\u767e\u4e8b\u53ef\u4e50~bskl~GP";"#.utf8
            ),
            tencentQuoteData: Data(),
            yahooSearchData: Data(#"{"quotes":[]}"#.utf8)
        )

        let results = await StockSearchService(httpClient: client)
            .search(query: "可乐", market: .unitedStates, limit: 8)

        #expect(Array(results.map(\.symbol).prefix(6)) == ["KO", "PEP", "COKE", "CCEP", "KOF", "CCOJY"])
    }

    @Test func stockSearchNormalizesYahooHongKongSymbol() {
        let quote = StockSearchProviderSupport.YahooQuote(
            symbol: "700.HK",
            shortname: "腾讯控股",
            longname: nil,
            quoteType: "EQUITY"
        )
        #expect(
            StockSearchProviderSupport.yahooResult(quote, market: .hongKong)
                == StockSearchResult(
                    market: .hongKong,
                    symbol: "00700",
                    name: "腾讯控股",
                    source: .yahoo
                )
        )
    }

    @Test func stockSearchNormalizesYahooAShareSymbol() {
        let quote = StockSearchProviderSupport.YahooQuote(
            symbol: "600519.SS",
            shortname: "Kweichow Moutai",
            longname: nil,
            quoteType: "EQUITY"
        )
        #expect(
            StockSearchProviderSupport.yahooResult(quote, market: .aShare)
                == StockSearchResult(
                    market: .aShare,
                    symbol: "600519",
                    name: "Kweichow Moutai",
                    source: .yahoo
                )
        )
    }

    @Test func stockSearchFiltersForeignPDDListingsAndLabelsUSCandidates() {
        let pdd = StockSearchProviderSupport.yahooResult(
            StockSearchProviderSupport.YahooQuote(
                symbol: "PDD",
                shortname: "PDD Holdings Inc.",
                longname: "PDD Holdings Inc.",
                quoteType: "EQUITY",
                exchange: "NMS",
                exchDisp: "NASDAQ",
                typeDisp: "Equity"
            ),
            market: .unitedStates
        )
        let london = StockSearchProviderSupport.yahooResult(
            StockSearchProviderSupport.YahooQuote(
                symbol: "0A2S.L",
                shortname: "PDD Holdings Inc.",
                longname: nil,
                quoteType: "EQUITY",
                exchange: "LSE",
                exchDisp: "London"
            ),
            market: .unitedStates
        )
        let frankfurt = StockSearchProviderSupport.yahooResult(
            StockSearchProviderSupport.YahooQuote(
                symbol: "9PDA.F",
                shortname: "PDD Holdings Inc.",
                longname: nil,
                quoteType: "EQUITY",
                exchange: "FRA",
                exchDisp: "Frankfurt"
            ),
            market: .unitedStates
        )

        #expect(pdd == StockSearchResult(
            market: .unitedStates,
            symbol: "PDD",
            name: "PDD Holdings Inc.",
            detail: "NASDAQ · 普通股",
            source: .yahoo
        ))
        #expect(london == nil)
        #expect(frankfurt == nil)
    }

    @Test(arguments: [
        (StockMarket.aShare, "600519", "600519", "600519"),
        (StockMarket.aShare, "贵州茅台", "600519", "贵州茅台"),
        (StockMarket.aShare, "茅台", "600519", "贵州茅台"),
        (StockMarket.aShare, "moutai", "600519", "Kweichow Moutai"),
        (StockMarket.aShare, "000858", "000858", "000858"),
        (StockMarket.aShare, "五粮液", "000858", "五粮液"),
        (StockMarket.hongKong, "700", "00700", "700"),
        (StockMarket.hongKong, "00700", "00700", "00700"),
        (StockMarket.hongKong, "腾讯", "00700", "腾讯"),
        (StockMarket.hongKong, "Tencent", "00700", "tencent"),
        (StockMarket.unitedStates, "KO", "KO", "KO"),
        (StockMarket.unitedStates, "ko", "KO", "ko"),
        (StockMarket.unitedStates, "可口可乐", "KO", "可口可乐"),
        (StockMarket.unitedStates, "可乐", "KO", "可乐"),
        (StockMarket.unitedStates, "Coca-Cola", "KO", "coca-cola"),
        (StockMarket.unitedStates, "MU", "MU", "MU"),
        (StockMarket.unitedStates, "micron", "MU", "micron"),
        (StockMarket.unitedStates, "美光科技", "MU", "美光科技"),
        (StockMarket.unitedStates, "PDD", "PDD", "PDD"),
        (StockMarket.unitedStates, "pdd", "PDD", "pdd"),
        (StockMarket.unitedStates, "拼多多", "PDD", "拼多多")
    ])
    func stockSearchSupportsQueryMatrix(
        market: StockMarket,
        query: String,
        expectedSymbol: String,
        _ queryLabel: String
    ) async {
        let results = await StockSearchService(httpClient: makeSearchMatrixClient())
            .search(query: query, market: market, limit: 8)

        #expect(!results.isEmpty, "query=\(queryLabel) should return candidates")
        #expect(results.first?.symbol == expectedSymbol, "query=\(queryLabel)")
        #expect(results.allSatisfy { !$0.name.contains("\\u") })
        #expect(results.allSatisfy { !$0.symbol.contains(".") || market == .unitedStates })
    }

    @Test func stockSearchReturnsEmptyForUnknownQuery() async {
        let client = StockSearchRoutingHTTPClient(
            tencentSearchData: Data(#"v_hint="";"#.utf8),
            tencentQuoteData: Data(),
            yahooSearchData: Data(#"{"quotes":[]}"#.utf8)
        )
        let results = await StockSearchService(httpClient: client)
            .search(query: "完全不存在的证券名称", market: .unitedStates, limit: 8)

        #expect(results.isEmpty)
    }

    @Test func stockSearchMatrixKeepsUSFormalNamesAndDetails() async {
        let results = await StockSearchService(httpClient: makeSearchMatrixClient())
            .search(query: "美光", market: .unitedStates, limit: 8)

        #expect(results.first?.symbol == "MU")
        #expect(results.first?.name == "Micron Technology, Inc.")
        #expect(results.first?.alias == "美光科技")
        #expect(results.first?.detail == "NASDAQ · 普通股")
    }

    private func makeSearchMatrixClient() -> StockSearchRoutingHTTPClient {
        let tencentSearch = #"v_hint="sh~600519~贵州茅台~gzmt~GP^sz~000858~五粮液~wly~GP^sh~601318~中国平安~zgpa~GP^hk~700~腾讯控股~txkg~GP^hk~9988~阿里巴巴-SW~albb~GP^us~aapl.n~苹果~pg~GP^us~msft.oq~微软~wr~GP^us~mu.oq~美光科技~mg~GP^us~pdd.oq~拼多多~pdd~GP^us~ko.n~可口可乐~kkkl~GP^us~pep.oq~百事可乐~bskl~GP^us~coke.oq~可口可乐装瓶~kkklzp~GP^us~pddl.oq~2倍做多拼多多ETF~pddetf~ETF";"#
        let yahooObject: [String: Any] = [
            "quotes": [
                yahooSearchQuote(
                    symbol: "600519.SS", shortname: "Kweichow Moutai", longname: "Kweichow Moutai Co., Ltd.",
                    quoteType: "EQUITY", exchange: "SHC", exchDisp: "Shanghai", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "000858.SZ", shortname: "Wuliangye Yibin", longname: "Wuliangye Yibin Co., Ltd.",
                    quoteType: "EQUITY", exchange: "SHC", exchDisp: "Shenzhen", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "700.HK", shortname: "Tencent", longname: "Tencent Holdings Limited",
                    quoteType: "EQUITY", exchange: "HKG", exchDisp: "Hong Kong", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "9988.HK", shortname: "Alibaba", longname: "Alibaba Group Holding Limited",
                    quoteType: "EQUITY", exchange: "HKG", exchDisp: "Hong Kong", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "AAPL", shortname: "Apple", longname: "Apple Inc.",
                    quoteType: "EQUITY", exchange: "NMS", exchDisp: "NASDAQ", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "MSFT", shortname: "Microsoft", longname: "Microsoft Corporation",
                    quoteType: "EQUITY", exchange: "NMS", exchDisp: "NASDAQ", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "MU", shortname: "美光科技", longname: "Micron Technology, Inc.",
                    quoteType: "EQUITY", exchange: "NMS", exchDisp: "NASDAQ", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "PDD", shortname: "PDD Holdings Inc.", longname: "PDD Holdings Inc.",
                    quoteType: "EQUITY", exchange: "NMS", exchDisp: "NASDAQ", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "KO", shortname: "Coca-Cola", longname: "The Coca-Cola Company",
                    quoteType: "EQUITY", exchange: "NYQ", exchDisp: "NYSE", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "PEP", shortname: "PepsiCo", longname: "PepsiCo, Inc.",
                    quoteType: "EQUITY", exchange: "NMS", exchDisp: "NASDAQ", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "COKE", shortname: "Coca-Cola Consolidated", longname: "Coca-Cola Consolidated, Inc.",
                    quoteType: "EQUITY", exchange: "NMS", exchDisp: "NASDAQ", typeDisp: "Equity"
                ),
                yahooSearchQuote(
                    symbol: "PDDL", shortname: "GraniteShares 2x Long PDD Daily", longname: nil,
                    quoteType: "ETF", exchange: "NGM", exchDisp: "NASDAQ", typeDisp: "ETF"
                )
            ]
        ]
        let yahooSearch = try! JSONSerialization.data(withJSONObject: yahooObject)
        return StockSearchRoutingHTTPClient(
            tencentSearchData: Data(tencentSearch.utf8),
            tencentQuoteData: Data(),
            yahooSearchData: yahooSearch
        )
    }

    private func yahooSearchQuote(
        symbol: String,
        shortname: String,
        longname: String?,
        quoteType: String,
        exchange: String,
        exchDisp: String,
        typeDisp: String
    ) -> [String: Any] {
        var value: [String: Any] = [
            "symbol": symbol,
            "shortname": shortname,
            "quoteType": quoteType,
            "exchange": exchange,
            "exchDisp": exchDisp,
            "typeDisp": typeDisp
        ]
        if let longname { value["longname"] = longname }
        return value
    }

    private func makeStock(market: StockMarket, symbol: String) -> StockHolding {
        StockHolding(market: market, symbol: symbol)
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func gb18030Data(_ value: String) -> Data {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return value.data(using: encoding) ?? Data()
    }

    private func timeSeries(
        type: String,
        values: [(String, Double)]
    ) -> [String: Any] {
        [
            "meta": ["type": [type]],
            type: values.map { date, value in
                [
                    "asOfDate": date,
                    "reportedValue": ["raw": value]
                ]
            }
        ]
    }

    private func directTimeSeries(
        type: String,
        values: [(String, Double)]
    ) -> [String: Any] {
        [
            "meta": ["type": [type]],
            type: values.map { date, value in
                [
                    "asOfDate": date,
                    "dataValue": value
                ]
            }
        ]
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

private actor StubStockFundamentalProvider: StockFundamentalProviding {
    private let snapshot: StockFundamentalSnapshot?
    private var requests = 0

    init(snapshot: StockFundamentalSnapshot?) {
        self.snapshot = snapshot
    }

    func fetchFundamentals(for stock: StockHolding) async -> StockFundamentalSnapshot? {
        requests += 1
        return snapshot
    }

    func requestCount() -> Int {
        requests
    }
}

private actor StockSearchRoutingHTTPClient: StockQuoteHTTPClient {
    private let tencentSearchData: Data
    private let tencentQuoteData: Data
    private let yahooSearchData: Data

    init(tencentSearchData: Data, tencentQuoteData: Data, yahooSearchData: Data) {
        self.tencentSearchData = tencentSearchData
        self.tencentQuoteData = tencentQuoteData
        self.yahooSearchData = yahooSearchData
    }

    func data(for request: URLRequest) async throws -> Data {
        switch request.url?.host {
        case "smartbox.gtimg.cn": tencentSearchData
        case "qt.gtimg.cn": tencentQuoteData
        case "query1.finance.yahoo.com": yahooSearchData
        default: Data()
        }
    }
}
