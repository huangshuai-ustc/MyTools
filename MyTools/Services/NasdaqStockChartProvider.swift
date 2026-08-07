import Foundation

struct NasdaqStockChartProvider: StockChartProvider {
    private let httpClient: any StockChartHTTPClient

    init(httpClient: any StockChartHTTPClient = URLSessionStockChartHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchChart(for request: StockChartRequest) async throws -> StockChartSnapshot {
        if request.range == .intraday {
            return try await fetchIntradayChart(for: request)
        }
        return try await fetchHistoricalChart(for: request)
    }

    private func fetchIntradayChart(
        for request: StockChartRequest
    ) async throws -> StockChartSnapshot {
        let stock = request.stock
        let symbol = request.symbol
        let payload = try await fetchPayload(
            symbol: symbol,
            endpoint: "chart",
            queryItems: []
        )
        guard let rawChart = payload["chart"] as? [[String: Any]] else {
            throw StockChartError.noData
        }
        let rawPoints = rawChart.compactMap { item -> StockChartPoint? in
            guard let milliseconds = cleanedDouble(item["x"]),
                  let price = cleanedDouble(item["y"]),
                  price > 0 else { return nil }
            return StockChartPoint(
                date: Date(timeIntervalSince1970: milliseconds / 1_000),
                open: price,
                high: price,
                low: price,
                close: price,
                volume: nil
            )
        }
        let points = StockChartSeriesProcessor.resampledIntradayPoints(
            StockChartSeriesProcessor.pointsOnLatestTradingDay(
                StockChartSeriesProcessor.regularUnitedStatesSessionPoints(rawPoints),
                market: .unitedStates
            ),
            targetMinutes: 3
        )
        guard points.count >= StockChartSeriesProcessor.minimumPointCount(for: .intraday),
              let latest = points.last else { throw StockChartError.noData }

        return StockChartSnapshot(
            symbol: payload["symbol"] as? String ?? symbol,
            name: payload["company"] as? String ?? stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: cleanedDouble(payload["previousClose"])
                ?? stock.previousClose.map { NSDecimalNumber(decimal: $0).doubleValue },
            points: points,
            indicatorPoints: points,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "Nasdaq",
            supportsCandlesticks: false
        )
    }

    private func fetchHistoricalChart(
        for request: StockChartRequest
    ) async throws -> StockChartSnapshot {
        let stock = request.stock
        let symbol = request.symbol
        let range = request.range
        let calendar = StockChartSeriesProcessor.marketCalendar(.unitedStates)
        let endDate = Date()
        let startDate = StockChartSeriesProcessor.historicalStartDate(
            for: range,
            endingAt: endDate,
            calendar: calendar
        )

        let payload = try await fetchPayload(
            symbol: symbol,
            endpoint: "historical",
            queryItems: [
                URLQueryItem(name: "fromdate", value: isoDate(startDate, calendar: calendar)),
                URLQueryItem(name: "todate", value: isoDate(endDate, calendar: calendar)),
                URLQueryItem(name: "limit", value: "5000")
            ]
        )
        guard let table = payload["tradesTable"] as? [String: Any],
              let rows = table["rows"] as? [[String: Any]] else {
            throw StockChartError.noData
        }
        var points = rows.compactMap { row -> StockChartPoint? in
            guard let dateText = row["date"] as? String,
                  let date = historicalDate(dateText),
                  let open = cleanedDouble(row["open"]),
                  let high = cleanedDouble(row["high"]),
                  let low = cleanedDouble(row["low"]),
                  let close = cleanedDouble(row["close"]),
                  close > 0 else { return nil }
            return StockChartPoint(
                date: date,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: cleanedDouble(row["volume"])
            )
        }
        points.sort { $0.date < $1.date }
        if range == .fiveDays, points.count > 5 {
            points = Array(points.suffix(5))
        } else if range == .fiveYears || range == .tenYears {
            points = StockChartSeriesProcessor.weeklyPoints(from: points, calendar: calendar)
        }
        guard StockChartSeriesProcessor.hasRequiredCoverage(
            points,
            for: range,
            market: stock.market
        ), let latest = points.last else {
            throw StockChartError.noData
        }

        return StockChartSnapshot(
            symbol: symbol,
            name: stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: stock.previousClose.map {
                NSDecimalNumber(decimal: $0).doubleValue
            },
            points: points,
            indicatorPoints: nil,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "Nasdaq",
            supportsCandlesticks: true
        )
    }

    private func fetchPayload(
        symbol: String,
        endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> [String: Any] {
        var lastError: Error = StockChartError.noData
        for assetClass in ["stocks", "etf"] {
            var components = URLComponents(
                string: "https://api.nasdaq.com/api/quote/\(symbol)/\(endpoint)"
            )
            components?.queryItems = [
                URLQueryItem(name: "assetclass", value: assetClass)
            ] + queryItems
            guard let url = components?.url else { throw StockChartError.invalidSymbol }

            do {
                let data = try await httpClient.data(
                    for: url,
                    referer: "https://www.nasdaq.com/"
                )
                guard let envelope = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                      let payload = envelope["data"] as? [String: Any] else {
                    lastError = StockChartError.noData
                    continue
                }
                return payload
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func cleanedDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = value as? String else { return nil }
        return Double(
            text
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func historicalDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = StockChartSeriesProcessor.marketTimeZone(.unitedStates)
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.date(from: text)
    }

    private func isoDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
