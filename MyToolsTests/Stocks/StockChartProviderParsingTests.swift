import Foundation
import Testing
@testable import MyTools

struct StockChartProviderParsingTests {
    @Test func tencentProviderParsesMinuteOHLCAndQuoteMetadata() async throws {
        let payload: [String: Any] = [
            "code": 0,
            "data": [
                "usVOO": [
                    "m5": [["202608031000", "10", "11", "12", "9", "100"]],
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

    @Test func yahooProviderParsesParallelQuoteArrays() async throws {
        let dates = dailyDates()
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
                            "open": [100, 101, 102, 103, 104, 105],
                            "high": [102, 103, 104, 105, 106, 107],
                            "low": [99, 100, 101, 102, 103, 104],
                            "close": [101, 102, 103, 104, 105, 106],
                            "volume": [10, 20, 30, 40, 50, 60]
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
            range: .oneMonth
        ))

        #expect(snapshot.source == "Yahoo Finance")
        #expect(snapshot.name == "Vanguard ETF")
        #expect(snapshot.points.count == 6)
        #expect(snapshot.points.last?.close == 106)
        #expect(snapshot.points.last?.volume == 60)
    }

    @Test func eastmoneyProviderParsesKlineRowsAndFlexiblePreviousClose() async throws {
        let lines = (1...6).map { day in
            "2026-08-0\(day),\(99 + day),\(100 + day),\(101 + day),\(98 + day),\(day * 100)"
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
            range: .oneMonth
        ))

        #expect(snapshot.source == "东方财富")
        #expect(snapshot.name == "示例股票")
        #expect(snapshot.previousClose == 98.5)
        #expect(snapshot.points.count == 6)
        #expect(snapshot.points.last?.close == 106)
        #expect(snapshot.points.last?.volume == 600)
    }

    @Test func nasdaqProviderCleansFormattedHistoricalNumbers() async throws {
        let rows = (1...6).map { day -> [String: Any] in
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
            range: .oneMonth
        ))

        #expect(snapshot.source == "Nasdaq")
        #expect(snapshot.points.count == 6)
        #expect(snapshot.points.last?.close == 106)
        #expect(snapshot.points.last?.volume == 6_000)
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
        (1...6).map { day in
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
