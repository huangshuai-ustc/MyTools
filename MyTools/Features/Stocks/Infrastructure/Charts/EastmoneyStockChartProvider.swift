#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct EastmoneyStockChartProvider: StockChartProvider {
    private struct Envelope: Decodable {
        let data: Payload?
    }

    private struct Payload: Decodable {
        let code: String?
        let name: String?
        let preKPrice: FlexibleDouble?
        let klines: [String]?
    }

    private struct FlexibleDouble: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = Double(text)
            } else {
                value = nil
            }
        }
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
        guard let identifier = identifier(symbol, market: stock.market) else {
            throw StockChartError.invalidSymbol
        }
        var components = URLComponents(
            string: "https://push2his.eastmoney.com/api/qt/stock/kline/get"
        )
        components?.queryItems = [
            URLQueryItem(name: "secid", value: identifier),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57"),
            URLQueryItem(
                name: "klt",
                value: usesDailyTechnicalInterval ? "101" : range.eastmoneyInterval
            ),
            URLQueryItem(name: "fqt", value: "1"),
            URLQueryItem(name: "end", value: "20500101"),
            URLQueryItem(
                name: "lmt",
                value: String(
                    usesDailyTechnicalInterval
                        ? range.dailyTechnicalPointLimit
                        : range.providerPointLimit
                )
            )
        ]
        guard let url = components?.url else { throw StockChartError.invalidSymbol }

        let data = try await httpClient.data(
            for: url,
            referer: "https://quote.eastmoney.com/"
        )
        let payload = try JSONDecoder().decode(Envelope.self, from: data).data
        guard let payload, let rawLines = payload.klines else { throw StockChartError.noData }

        let parsedPoints = rawLines.compactMap { parsePoint($0, market: stock.market) }
        let points: [StockChartPoint]
        let fetchedIndicatorPoints: [StockChartPoint]?
        if !usesDailyTechnicalInterval && (range == .intraday || range == .fiveDays) {
            let prepared = StockChartSeriesProcessor.preparedMinuteChartPoints(
                parsedPoints,
                range: range,
                market: stock.market
            )
            points = prepared.visible
            fetchedIndicatorPoints = prepared.indicators
        } else {
            points = parsedPoints
            fetchedIndicatorPoints = nil
        }
        guard StockChartSeriesProcessor.hasRequiredCoverage(
            points,
            for: range,
            market: stock.market
        ), let latest = points.last else {
            throw StockChartError.noData
        }

        return StockChartSnapshot(
            symbol: payload.code ?? symbol,
            name: payload.name ?? stock.displayName,
            currencyCode: stock.market.currencyCode,
            previousClose: stock.previousClose.map {
                NSDecimalNumber(decimal: $0).doubleValue
            } ?? payload.preKPrice?.value,
            points: points,
            indicatorPoints: fetchedIndicatorPoints,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "东方财富",
            supportsCandlesticks: true
        )
    }

    private func identifier(_ symbol: String, market: StockMarket) -> String? {
        switch market {
        case .aShare:
            let marketID = symbol.hasPrefix("5") || symbol.hasPrefix("6")
                || symbol.hasPrefix("9") ? "1" : "0"
            return "\(marketID).\(symbol)"
        case .hongKong:
            return "116.\(symbol)"
        case .unitedStates:
            return nil
        }
    }

    private func parsePoint(_ line: String, market: StockMarket) -> StockChartPoint? {
        let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard values.count >= 6,
              let date = parseDate(values[0], market: market),
              let open = Double(values[1]),
              let close = Double(values[2]),
              let high = Double(values[3]),
              let low = Double(values[4]),
              close > 0 else { return nil }
        return StockChartPoint(
            date: date,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: Double(values[5])
        )
    }

    private func parseDate(_ text: String, market: StockMarket) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = StockChartSeriesProcessor.marketTimeZone(market)
        formatter.dateFormat = text.contains(":") ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

#endif
