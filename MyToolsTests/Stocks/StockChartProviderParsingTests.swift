import Foundation
import Testing
@testable import MyTools

struct StockChartProviderParsingTests {
    @Test func minuteRangesUseOneMinuteProviderIntervals() {
        #expect(StockChartRange.intraday.yahooInterval == "1m")
        #expect(StockChartRange.fiveDays.yahooInterval == "1m")
        #expect(StockChartRange.intraday.eastmoneyInterval == "1")
        #expect(StockChartRange.fiveDays.eastmoneyInterval == "1")
        #expect(StockChartRange.weekK.yahooInterval == "1d")
        #expect(StockChartRange.monthK.yahooInterval == "1d")
        #expect(StockChartRange.weekK.eastmoneyInterval == "101")
        #expect(StockChartRange.monthK.eastmoneyInterval == "101")
        #expect(StockChartRange.fiveDays.yahooRange == "5d")
    }

    @Test func kLineRangesRequestCompleteDailyHistoryBoundary() {
        let endingAt = StockChartFixtures.date(2026, 8, 25)
        let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
        let expectedStart = Date(timeIntervalSince1970: -2_208_988_800)

        for range in [
            StockChartRange.dayK,
            .weekK,
            .monthK,
            .quarterK,
            .yearK
        ] {
            #expect(
                StockChartSeriesProcessor.historicalStartDate(
                    for: range,
                    endingAt: endingAt,
                    calendar: calendar
                ) == expectedStart
            )
        }
    }

    @Test func tencentProviderParsesMinuteOHLCAndQuoteMetadata() async throws {
        let payload: [String: Any] = [
            "code": 0,
            "data": [
                "usVOO": [
                    "m1": [["202608031000", "10", "11", "12", "9", "100"]],
                    "qt": ["usVOO": ["", "VOO Name", "", "", "9.5"]]
                ]
            ]
        ]
        let provider = TencentStockChartProvider(
            httpClient: StubStockChartHTTPClient(responseData: try json(payload))
        )

        let snapshot = try await provider.fetchChart(for: request(
            market: .unitedStates,
            range: .intraday
        ))

        #expect(snapshot.source == "腾讯证券")
        #expect(snapshot.name == "VOO Name")
        #expect(snapshot.previousClose == 9.5)
        #expect(snapshot.points.first?.open == 10)
        #expect(snapshot.points.first?.high == 12)
        #expect(snapshot.points.first?.low == 9)
        #expect(snapshot.points.first?.close == 11)
        #expect(snapshot.points.first?.volume == 100)
    }

    @Test func tencentProviderKeepsCoarserReturnedMinuteInterval() async throws {
        let payload: [String: Any] = [
            "code": 0,
            "data": [
                "usVOO": [
                    "m3": [
                        ["202608031000", "10", "11", "12", "9", "100"],
                        ["202608031003", "11", "12", "13", "10", "200"]
                    ],
                    "qt": ["usVOO": ["", "VOO", "", "", "9.5"]]
                ]
            ]
        ]
        let provider = TencentStockChartProvider(
            httpClient: StubStockChartHTTPClient(responseData: try json(payload))
        )

        let snapshot = try await provider.fetchChart(for: request(
            market: .unitedStates,
            range: .intraday
        ))

        #expect(snapshot.points.count == 2)
        #expect(
            snapshot.points[1].date.timeIntervalSince(snapshot.points[0].date) == 180
        )
    }

    @Test func yahooProviderParsesParallelQuoteArrays() async throws {
        let dates = dailyDates()
        let values = Array(1...20)
        let opens = values.map { 99 + $0 }
        let highs = values.map { 101 + $0 }
        let lows = values.map { 98 + $0 }
        let closes = values.map { 100 + $0 }
        let volumes = values.map { $0 * 10 }
        let payload: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": [
                        "currency": "USD",
                        "symbol": "VOO",
                        "longName": "Vanguard ETF",
                        "chartPreviousClose": 99
                    ],
                    "timestamp": dates.map(\.timeIntervalSince1970),
                    "indicators": [
                        "quote": [[
                            "open": opens,
                            "high": highs,
                            "low": lows,
                            "close": closes,
                            "volume": volumes
                        ]]
                    ]
                ]]
            ]
        ]
        let provider = YahooStockChartProvider(
            httpClient: StubStockChartHTTPClient(responseData: try json(payload))
        )

        let snapshot = try await provider.fetchChart(for: request(
            market: .unitedStates,
            range: .dayK
        ))

        #expect(snapshot.source == "Yahoo Finance")
        #expect(snapshot.name == "Vanguard ETF")
        #expect(snapshot.points.count == 20)
        #expect(snapshot.points.last?.close == 120)
        #expect(snapshot.points.last?.volume == 200)
    }

    @Test func eastmoneyProviderParsesKlineRowsAndFlexiblePreviousClose() async throws {
        let lines: [String] = (1...20).map { day in
            let dayText = day < 10 ? "0\(day)" : "\(day)"
            return "2026-08-\(dayText),\(99 + day),\(100 + day),\(101 + day),\(98 + day),\(day * 100)"
        }
        let payload: [String: Any] = [
            "data": [
                "code": "600519",
                "name": "示例股票",
                "preKPrice": "98.5",
                "klines": lines
            ]
        ]
        let provider = EastmoneyStockChartProvider(
            httpClient: StubStockChartHTTPClient(responseData: try json(payload))
        )

        let snapshot = try await provider.fetchChart(for: request(
            market: .aShare,
            range: .dayK
        ))

        #expect(snapshot.source == "东方财富")
        #expect(snapshot.name == "示例股票")
        #expect(snapshot.previousClose == 98.5)
        #expect(snapshot.points.count == 20)
        #expect(snapshot.points.last?.close == 120)
        #expect(snapshot.points.last?.volume == 2_000)
    }

    @Test func nasdaqProviderCleansFormattedHistoricalNumbers() async throws {
        let rows = (1...20).map { day -> [String: Any] in
            [
                "date": "08/0\(day)/2026",
                "open": "$\(99 + day).00",
                "high": "$\(101 + day).00",
                "low": "$\(98 + day).00",
                "close": "$\(100 + day).00",
                "volume": "\(day),000"
            ]
        }
        let payload: [String: Any] = [
            "data": [
                "tradesTable": ["rows": rows]
            ]
        ]
        let provider = NasdaqStockChartProvider(
            httpClient: StubStockChartHTTPClient(responseData: try json(payload))
        )

        let snapshot = try await provider.fetchChart(for: request(
            market: .unitedStates,
            range: .dayK
        ))

        #expect(snapshot.source == "Nasdaq")
        #expect(snapshot.points.count == 20)
        #expect(snapshot.points.last?.close == 120)
        #expect(snapshot.points.last?.volume == 20_000)
    }

    private func request(
        market: StockMarket,
        range: StockChartRange
    ) -> StockChartRequest {
        let stock = StockHolding(
            market: market,
            symbol: market == .unitedStates ? "VOO" : "600519",
            name: "Fallback Name"
        )
        return StockChartRequest(stock: stock, symbol: stock.symbol, range: range)
    }

    private func dailyDates() -> [Date] {
        (1...20).map { day in
            StockChartFixtures.date(
                2026,
                8,
                day,
                timeZone: "America/New_York"
            )
        }
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
