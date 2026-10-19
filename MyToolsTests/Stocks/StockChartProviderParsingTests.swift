import Foundation
import Testing
@testable import MyTools

struct StockChartProviderParsingTests {
    @Test func nasdaqIntradayPreservesPostMarketOnlyResponse() async throws {
        let date = StockChartFixtures.date(2026, 10, 8, hour: 17, timeZone: "America/New_York")
        let offset = TimeZone(identifier: "America/New_York")!.secondsFromGMT(for: Date())
        let payload: [String: Any] = ["data": ["chart": [
            ["x": (date.timeIntervalSince1970 + Double(offset)) * 1_000, "y": 101.0]
        ]]]
        let provider = NasdaqStockChartProvider(httpClient: StubStockChartHTTPClient(responseData: try json(payload)))
        let snapshot = try await provider.fetchChart(for: request(market: .unitedStates, range: .intraday))
        #expect(snapshot.points.isEmpty)
        #expect(snapshot.postMarketPoints.count == 1)
        #expect(snapshot.postMarketPoints.first?.date == date)
        #expect(snapshot.quoteUpdatedAt == date)
        let normalized = StockChartSeriesProcessor.normalizedSnapshot(
            snapshot, range: .intraday, market: .unitedStates, at: date
        )
        #expect(normalized?.postMarketPoints == snapshot.postMarketPoints)
        let store = StockChartDiskStore()
        let key = StockChartStoreKey(market: .unitedStates, symbol: snapshot.symbol)
        let merged = store.merging(snapshot, range: .intraday, for: key, into: nil)
        #expect(store.renderedSnapshot(from: merged, range: .intraday)?.postMarketPoints == snapshot.postMarketPoints)
    }

    // AUDIT-057：格式化器按“格式 + 时区”复用，不同时区不能串用。
    @Test func cachedDateParserKeepsFormatAndTimeZoneSeparate() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let a = StockDateParser.date("2026-08-07 09:30", format: "yyyy-MM-dd HH:mm", timeZone: shanghai)
        let b = StockDateParser.date("2026-08-07 09:30", format: "yyyy-MM-dd HH:mm", timeZone: newYork)
        #expect(a == StockChartFixtures.date(2026, 8, 7, hour: 9, minute: 30))
        #expect(b == StockChartFixtures.date(2026, 8, 7, hour: 9, minute: 30, timeZone: "America/New_York"))
        #expect(StockDateParser.date("20260807", format: "yyyy-MM-dd HH:mm", timeZone: shanghai) == nil)
    }

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

    @Test func yahooProviderKeepsFourPMBarInPostMarketAndUsesOfficialClose() async throws {
        let timeZone = "America/New_York"
        let regularStart = StockChartFixtures.date(
            2026,
            8,
            28,
            hour: 15,
            minute: 58,
            timeZone: timeZone
        )
        let regularEnd = StockChartFixtures.date(
            2026,
            8,
            28,
            hour: 15,
            minute: 59,
            timeZone: timeZone
        )
        let postMarketStart = StockChartFixtures.date(
            2026,
            8,
            28,
            hour: 16,
            timeZone: timeZone
        )
        let postMarketNext = StockChartFixtures.date(
            2026,
            8,
            28,
            hour: 16,
            minute: 1,
            timeZone: timeZone
        )
        let officialCloseTime = postMarketStart.addingTimeInterval(36)
        let payload: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": [
                        "currency": "USD",
                        "symbol": "BABA",
                        "longName": "Alibaba Group Holding Limited",
                        "chartPreviousClose": 108.48,
                        "previousClose": 116.31,
                        "regularMarketPrice": 118.90,
                        "regularMarketTime": officialCloseTime.timeIntervalSince1970
                    ],
                    "timestamp": [
                        regularStart,
                        regularEnd,
                        postMarketStart,
                        postMarketNext
                    ].map(\.timeIntervalSince1970),
                    "indicators": [
                        "quote": [[
                            "open": [118.70, 118.73, 118.89, 118.64],
                            "high": [118.82, 118.89, 118.89, 118.66],
                            "low": [118.69, 118.71, 118.01, 118.62],
                            "close": [118.80, 118.89, 118.64, 118.63],
                            "volume": [100_000, 236_798, 3_163, 0]
                        ]]
                    ]
                ]]
            ]
        ]
        let provider = YahooStockChartProvider(
            httpClient: StubStockChartHTTPClient(responseData: try json(payload))
        )

        let snapshot = try await provider.fetchChart(for: StockChartRequest(
            stock: StockHolding(
                market: .unitedStates,
                symbol: "BABA",
                name: "阿里巴巴"
            ),
            symbol: "BABA",
            range: .intraday
        ))

        #expect(snapshot.points.map(\.date) == [regularStart, regularEnd])
        #expect(snapshot.points.last?.close == 118.90)
        #expect(snapshot.points.last?.high == 118.90)
        #expect(snapshot.previousClose == 116.31)
        #expect(snapshot.postMarketPoints.map(\.date) == [postMarketStart, postMarketNext])
        #expect(snapshot.postMarketPoints.first?.close == 118.64)
        #expect(
            StockChartSeriesProcessor.currentSessionSummary(
                from: snapshot.points,
                market: .unitedStates,
                at: postMarketNext
            )?.close == 118.90
        )
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

    /// query2 握手卡住时不能串行等满 8 秒超时：对冲延迟一到就并行请求 query1。
    @Test func yahooProviderHedgesStalledPrimaryHost() async throws {
        let dates = dailyDates()
        let payload: [String: Any] = ["chart": ["result": [[
            "meta": ["currency": "USD", "symbol": "VOO"],
            "timestamp": dates.map(\.timeIntervalSince1970),
            "indicators": ["quote": [["close": dates.indices.map { Double(100 + $0) }]]]
        ]]]]
        let provider = YahooStockChartProvider(
            httpClient: HostRoutingHTTPClient(stalledHost: "query2.finance.yahoo.com", data: try json(payload))
        )

        let started = ContinuousClock.now
        let snapshot = try await provider.fetchChart(for: request(market: .unitedStates, range: .dayK))

        #expect(snapshot.points.count == 20)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    private struct HostRoutingHTTPClient: StockChartHTTPClient {
        let stalledHost: String
        let data: Data

        func data(for url: URL, referer: String) async throws -> Data {
            if url.host == stalledHost {
                try await Task.sleep(for: .seconds(30))
            }
            return data
        }
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

struct StockDataSourceCircuitBreakerTests {
    private final class Clock: @unchecked Sendable {
        var date = StockChartFixtures.date(2026, 8, 7, hour: 10)
    }

    @Test func consecutiveFailuresOpenAnEscalatingCooldownAndSuccessCloses() {
        let clock = Clock()
        let breaker = StockDataSourceCircuitBreaker(
            failureThreshold: 3, baseCooldown: 120, maximumCooldown: 300, now: { clock.date }
        )
        let host = "api.nasdaq.com"
        let timeout = URLError(.timedOut)
        for _ in 0..<2 { breaker.record(timeout, for: host, startedAt: clock.date) }
        #expect(breaker.rejectRequest(for: host) == nil)
        breaker.record(timeout, for: host, startedAt: clock.date)
        #expect(breaker.rejectRequest(for: host) == 120)
        #expect(breaker.rejectRequest(for: "query2.finance.yahoo.com") == nil)

        // In-flight failures do not extend an open breaker.
        breaker.record(timeout, for: host, startedAt: clock.date)
        clock.date.addTimeInterval(121)
        #expect(breaker.rejectRequest(for: host) == nil)

        // A failed probe re-opens with a doubled cooldown, capped at the maximum.
        breaker.record(timeout, for: host, startedAt: clock.date)
        #expect(breaker.rejectRequest(for: host) == 240)
        clock.date.addTimeInterval(241)
        breaker.record(status: 503, for: host, startedAt: clock.date)
        #expect(breaker.rejectRequest(for: host) == 300)

        clock.date.addTimeInterval(301)
        breaker.record(status: 200, for: host, startedAt: clock.date)
        for _ in 0..<2 { breaker.record(timeout, for: host, startedAt: clock.date) }
        #expect(breaker.rejectRequest(for: host) == nil)
    }

    @Test func cancellationOfflineAndSuspendedRequestsAreNotHeldAgainstTheHost() {
        let clock = Clock()
        let breaker = StockDataSourceCircuitBreaker(failureThreshold: 1, now: { clock.date })
        let host = "qt.gtimg.cn"
        breaker.record(URLError(.cancelled), for: host, startedAt: clock.date)
        breaker.record(CancellationError(), for: host, startedAt: clock.date)
        breaker.record(URLError(.notConnectedToInternet), for: host, startedAt: clock.date)
        breaker.record(StockChartError.noData, for: host, startedAt: clock.date)
        breaker.record(status: 404, for: host, startedAt: clock.date)
        breaker.record(URLError(.timedOut), for: host, startedAt: clock.date.addingTimeInterval(-300))
        #expect(breaker.rejectRequest(for: host) == nil)
        breaker.record(URLError(.secureConnectionFailed), for: host, startedAt: clock.date)
        #expect(breaker.rejectRequest(for: host) != nil)
        #expect(DiagnosticLogger.isCancellation(URLError(.cancelled)))
        #expect(!DiagnosticLogger.isCancellation(URLError(.timedOut)))
    }
}
