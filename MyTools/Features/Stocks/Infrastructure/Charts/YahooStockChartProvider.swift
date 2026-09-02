#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct YahooStockChartProvider: StockChartProvider {
    private struct Envelope: Decodable {
        let chart: Chart
    }

    private struct Chart: Decodable {
        let result: [Result]?
    }

    private struct Result: Decodable {
        let meta: Meta
        let timestamp: [TimeInterval]?
        let indicators: Indicators
    }

    private struct Meta: Decodable {
        let currency: String?
        let symbol: String?
        let longName: String?
        let shortName: String?
        let chartPreviousClose: Double?
        let previousClose: Double?
        let regularMarketPrice: Double?
        let regularMarketTime: TimeInterval?
    }

    private struct Indicators: Decodable {
        let quote: [QuoteValues]
    }

    private struct QuoteValues: Decodable {
        let open: [Double?]?
        let high: [Double?]?
        let low: [Double?]?
        let close: [Double?]?
        let volume: [Double?]?
    }

    private let httpClient: any StockChartHTTPClient

    init(httpClient: any StockChartHTTPClient = URLSessionStockChartHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchChart(for request: StockChartRequest) async throws -> StockChartSnapshot {
        let stock = request.stock
        let symbol = request.symbol
        let range = request.range
        let path = "/v8/finance/chart/\(identifier(symbol, market: stock.market))"
        var queryItems = [
            URLQueryItem(
                name: "interval",
                value: range.isKLineRange ? "1d" : range.yahooInterval
            ),
            URLQueryItem(name: "includePrePost", value: "true"),
            URLQueryItem(name: "events", value: "div,splits")
        ]
        if range == .yearK {
            // `max` is Yahoo's complete-history mode. It avoids relying on a
            // guessed start date that can be interpreted as a finite window.
            queryItems.append(URLQueryItem(name: "range", value: range.yahooRange))
        } else if range.isKLineRange {
            let endDate = Date()
            let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
            let startDate = StockChartSeriesProcessor.historicalStartDate(
                for: range,
                endingAt: endDate,
                calendar: calendar
            )
            queryItems.append(URLQueryItem(
                name: "period1",
                value: String(Int(startDate.timeIntervalSince1970))
            ))
            queryItems.append(URLQueryItem(
                name: "period2",
                value: String(Int(endDate.timeIntervalSince1970))
            ))
        } else {
            queryItems.append(URLQueryItem(name: "range", value: range.yahooRange))
        }
        let data = try await chartData(path: path, queryItems: queryItems)
        let result = try JSONDecoder().decode(Envelope.self, from: data).chart.result?.first
        guard let result,
              let timestamps = result.timestamp,
              let values = result.indicators.quote.first,
              let closes = values.close else {
            throw StockChartError.noData
        }

        let parsedPoints = timestamps.indices.compactMap { index -> StockChartPoint? in
            guard index < closes.count, let close = closes[index], close > 0 else { return nil }
            let open = value(in: values.open, at: index) ?? close
            let high = value(in: values.high, at: index) ?? max(open, close)
            let low = value(in: values.low, at: index) ?? min(open, close)
            return StockChartPoint(
                date: Date(timeIntervalSince1970: timestamps[index]),
                open: open,
                high: max(high, open, close),
                low: min(low, open, close),
                close: close,
                volume: value(in: values.volume, at: index)
            )
        }
        let rawPreMarketPoints = stock.market == .unitedStates && range == .intraday
            ? StockChartSeriesProcessor.preMarketUnitedStatesSessionPoints(parsedPoints)
                .sorted { $0.date < $1.date }
            : []
        let rawPostMarketPoints = stock.market == .unitedStates && range == .intraday
            ? yahooUnitedStatesPostMarketPoints(parsedPoints)
                .sorted { $0.date < $1.date }
            : []
        var regularPoints = stock.market == .unitedStates
            && (range == .intraday || range == .fiveDays)
            ? yahooUnitedStatesRegularSessionPoints(parsedPoints)
            : parsedPoints
        if stock.market == .unitedStates,
           (range == .intraday || range == .fiveDays) {
            regularPoints = applyingOfficialRegularMarketClose(
                to: regularPoints,
                price: result.meta.regularMarketPrice,
                updatedAt: result.meta.regularMarketTime.map {
                    Date(timeIntervalSince1970: $0)
                }
            )
        }
        guard !regularPoints.isEmpty else { throw StockChartError.noData }
        let points: [StockChartPoint]
        let fetchedIndicatorPoints: [StockChartPoint]?
        if range == .intraday || range == .fiveDays {
            let prepared = StockChartSeriesProcessor.preparedMinuteChartPoints(
                regularPoints,
                range: range,
                market: stock.market
            )
            points = prepared.visible
            fetchedIndicatorPoints = prepared.indicators
        } else {
            points = regularPoints
            fetchedIndicatorPoints = nil
        }
        guard StockChartSeriesProcessor.hasRequiredCoverage(
            points,
            for: range,
            market: stock.market
        ), let latest = points.last else {
            throw StockChartError.noData
        }
        let preMarketPoints: [StockChartPoint]
        if range == .intraday,
           let latestPreMarketDate = rawPreMarketPoints.last?.date {
            let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
            let latestRegularDay = calendar.startOfDay(for: latest.date)
            let latestPreMarketDay = calendar.startOfDay(for: latestPreMarketDate)
            let targetDay = max(latestRegularDay, latestPreMarketDay)
            preMarketPoints = rawPreMarketPoints.filter {
                calendar.isDate($0.date, inSameDayAs: targetDay)
            }
        } else {
            preMarketPoints = []
        }
        let postMarketPoints: [StockChartPoint]
        if range == .intraday,
           let latestPostMarketDate = rawPostMarketPoints.last?.date {
            let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
            let latestRegularDay = calendar.startOfDay(for: latest.date)
            let latestPostMarketDay = calendar.startOfDay(for: latestPostMarketDate)
            let targetDay = max(latestRegularDay, latestPostMarketDay)
            postMarketPoints = rawPostMarketPoints.filter {
                calendar.isDate($0.date, inSameDayAs: targetDay)
            }
        } else {
            postMarketPoints = []
        }

        return StockChartSnapshot(
            symbol: result.meta.symbol ?? symbol,
            name: result.meta.longName ?? result.meta.shortName ?? stock.displayName,
            currencyCode: result.meta.currency ?? stock.market.currencyCode,
            // `chartPreviousClose` is the close immediately before the
            // requested chart range. For a five-day minute request it can be
            // several sessions old; `previousClose` is the current quote's
            // actual prior-session close.
            previousClose: result.meta.previousClose ?? result.meta.chartPreviousClose,
            points: points,
            preMarketPoints: preMarketPoints,
            postMarketPoints: postMarketPoints,
            indicatorPoints: fetchedIndicatorPoints,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "Yahoo Finance",
            supportsCandlesticks: true
        )
    }

    private func chartData(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        var lastError: Error = StockChartError.serviceUnavailable
        for host in ["query2.finance.yahoo.com", "query1.finance.yahoo.com"] {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            components.queryItems = queryItems
            guard let url = components.url else { throw StockChartError.invalidSymbol }

            do {
                return try await httpClient.data(
                    for: url,
                    referer: "https://finance.yahoo.com/"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func identifier(_ symbol: String, market: StockMarket) -> String {
        switch market {
        case .aShare:
            let suffix = symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9")
                ? ".SS"
                : symbol.hasPrefix("4") || symbol.hasPrefix("8") ? ".BJ" : ".SZ"
            return symbol + suffix
        case .hongKong:
            var compactSymbol = symbol
            while compactSymbol.hasPrefix("0"), compactSymbol.count > 4 {
                compactSymbol.removeFirst()
            }
            return compactSymbol + ".HK"
        case .unitedStates:
            return symbol.replacingOccurrences(of: ".", with: "-")
        }
    }

    private func value(in values: [Double?]?, at index: Int) -> Double? {
        guard let values, index < values.count else { return nil }
        return values[index]
    }

    /// Yahoo labels minute bars by their interval start. With extended-hours
    /// data enabled, the 16:00 bar is therefore the first post-market minute,
    /// not the final regular-session minute. Keep this provider-specific:
    /// other chart sources can use different timestamp conventions.
    private func yahooUnitedStatesRegularSessionPoints(
        _ points: [StockChartPoint]
    ) -> [StockChartPoint] {
        sessionPoints(points, minuteRange: 570..<960)
    }

    private func yahooUnitedStatesPostMarketPoints(
        _ points: [StockChartPoint]
    ) -> [StockChartPoint] {
        sessionPoints(points, minuteRange: 960..<1_201)
    }

    private func sessionPoints(
        _ points: [StockChartPoint],
        minuteRange: Range<Int>
    ) -> [StockChartPoint] {
        let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
        return points.filter { point in
            let components = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = components.hour, let minute = components.minute else {
                return false
            }
            return minuteRange.contains(hour * 60 + minute)
        }
    }

    /// The final 15:59 minute close can differ slightly from the exchange's
    /// official close, especially when a closing auction settles after that
    /// minute. Yahoo exposes the finalized value separately as
    /// `regularMarketPrice`; apply it only to the matching regular-session day
    /// and keep the original OHLC range valid.
    private func applyingOfficialRegularMarketClose(
        to points: [StockChartPoint],
        price: Double?,
        updatedAt: Date?
    ) -> [StockChartPoint] {
        guard let price, price > 0,
              let updatedAt,
              let latest = points.last else { return points }
        let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
        guard calendar.isDate(latest.date, inSameDayAs: updatedAt) else {
            return points
        }

        var updatedPoints = points
        updatedPoints[updatedPoints.count - 1] = StockChartPoint(
            date: latest.date,
            open: latest.open,
            high: max(latest.high, price),
            low: min(latest.low, price),
            close: price,
            volume: latest.volume
        )
        return updatedPoints
    }
}

#endif
