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
        let usesDailyTechnicalInterval = request.usesDailyTechnicalInterval
        let path = "/v8/finance/chart/\(identifier(symbol, market: stock.market))"
        var queryItems = [
            URLQueryItem(
                name: "interval",
                value: usesDailyTechnicalInterval ? "1d" : range.yahooInterval
            ),
            URLQueryItem(name: "includePrePost", value: "true"),
            URLQueryItem(name: "events", value: "div,splits")
        ]
        if range == .yearK && !usesDailyTechnicalInterval {
            // `max` is Yahoo's complete-history mode. It avoids relying on a
            // guessed start date that can be interpreted as a finite window.
            queryItems.append(URLQueryItem(name: "range", value: range.yahooRange))
        } else if range == .sinceInception {
            // Yahoo accepts pre-Unix timestamps, so old listings are not truncated at 1970.
            queryItems.append(URLQueryItem(name: "period1", value: "-2208988800"))
            queryItems.append(URLQueryItem(
                name: "period2",
                value: String(Int(Date().timeIntervalSince1970))
            ))
        } else if usesDailyTechnicalInterval || (range != .intraday && range != .fiveDays) {
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
        let rawPreMarketPoints = !usesDailyTechnicalInterval
            && stock.market == .unitedStates && range == .intraday
            ? StockChartSeriesProcessor.preMarketUnitedStatesSessionPoints(parsedPoints)
                .sorted { $0.date < $1.date }
            : []
        let rawPostMarketPoints = !usesDailyTechnicalInterval
            && stock.market == .unitedStates && range == .intraday
            ? StockChartSeriesProcessor.postMarketSessionPoints(parsedPoints, market: .unitedStates)
                .sorted { $0.date < $1.date }
            : []
        let regularPoints = !usesDailyTechnicalInterval
            && stock.market == .unitedStates
            && (range == .intraday || range == .fiveDays)
            ? StockChartSeriesProcessor.regularUnitedStatesSessionPoints(parsedPoints)
            : parsedPoints
        guard !regularPoints.isEmpty else { throw StockChartError.noData }
        let points: [StockChartPoint]
        let fetchedIndicatorPoints: [StockChartPoint]?
        if !usesDailyTechnicalInterval && (range == .intraday || range == .fiveDays) {
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
            previousClose: result.meta.chartPreviousClose ?? result.meta.previousClose,
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
}

#endif
