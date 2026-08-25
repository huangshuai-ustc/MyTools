#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct TencentStockChartProvider: StockChartProvider {
    private let httpClient: any StockChartHTTPClient

    init(httpClient: any StockChartHTTPClient = URLSessionStockChartHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchChart(for request: StockChartRequest) async throws -> StockChartSnapshot {
        let stock = request.stock
        let symbol = request.symbol
        let range = request.range
        let identifier = identifier(symbol, market: stock.market)
        let isMinuteChart = range == .intraday || range == .fiveDays
        let requestedInterval = "m1"
        let historicalInterval = "day"
        let pointLimit = range.providerPointLimit
        let endpoint = isMinuteChart
            ? "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/kline/mkline"
            : "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/fqkline/get"
        var components = URLComponents(string: endpoint)
        let parameter = isMinuteChart
            ? "\(identifier),\(requestedInterval),,\(pointLimit)"
            : "\(identifier),\(historicalInterval),,,\(pointLimit),qfq"
        components?.queryItems = [URLQueryItem(name: "param", value: parameter)]
        guard let url = components?.url else { throw StockChartError.invalidSymbol }

        let data = try await httpClient.data(
            for: url,
            referer: "https://stockapp.finance.qq.com/"
        )
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = envelope["code"] as? NSNumber,
              code.intValue == 0,
              let dataPayload = envelope["data"] as? [String: Any],
              let payload = dataPayload[identifier] as? [String: Any] else {
            throw StockChartError.noData
        }

        let rawPoints: [[Any]]?
        if isMinuteChart {
            // Some US symbols are returned by Tencent at a coarser interval
            // despite an m1 request. Keep the smallest interval actually
            // returned; never synthesize missing minute bars locally.
            rawPoints = minutePayload(in: payload, requestedInterval: requestedInterval)
        } else {
            rawPoints = (payload["qfq\(historicalInterval)"] as? [[Any]])
                ?? (payload[historicalInterval] as? [[Any]])
        }
        guard let rawPoints else { throw StockChartError.noData }

        let parsedPoints = rawPoints.compactMap { parsePoint($0, market: stock.market) }
        let points: [StockChartPoint]
        let preMarketPoints: [StockChartPoint]
        let postMarketPoints: [StockChartPoint]
        let fetchedIndicatorPoints: [StockChartPoint]?
        if isMinuteChart {
            let prepared = StockChartSeriesProcessor.preparedMinuteChartPoints(
                parsedPoints,
                range: range,
                market: stock.market
            )
            points = prepared.visible
            preMarketPoints = range == .intraday && stock.market.supportsExtendedHoursChart
                ? StockChartSeriesProcessor.preMarketSessionPoints(
                    prepared.indicators,
                    market: stock.market
                )
                : []
            postMarketPoints = range == .intraday && stock.market.supportsExtendedHoursChart
                ? StockChartSeriesProcessor.postMarketSessionPoints(
                    prepared.indicators,
                    market: stock.market
                )
                : []
            fetchedIndicatorPoints = prepared.indicators
        } else {
            points = parsedPoints
            preMarketPoints = []
            postMarketPoints = []
            fetchedIndicatorPoints = nil
        }
        guard let latest = points.last else { throw StockChartError.noData }
        guard StockChartSeriesProcessor.hasRequiredCoverage(
            points,
            for: range,
            market: stock.market
        ) else {
            throw StockChartError.noData
        }

        let quoteValues = (payload["qt"] as? [String: Any])?[identifier] as? [Any]
        let quoteName = stringValue(in: quoteValues, at: 1)
        let previousClose = doubleValue(in: quoteValues, at: 4)
            ?? stock.previousClose.map { NSDecimalNumber(decimal: $0).doubleValue }
        let resolvedName = quoteName.flatMap { $0.isEmpty ? nil : $0 } ?? stock.displayName

        return StockChartSnapshot(
            symbol: symbol,
            name: resolvedName,
            currencyCode: stock.market.currencyCode,
            previousClose: previousClose,
            points: points,
            preMarketPoints: preMarketPoints,
            postMarketPoints: postMarketPoints,
            indicatorPoints: fetchedIndicatorPoints,
            quoteUpdatedAt: latest.date,
            fetchedAt: Date(),
            source: "腾讯证券",
            supportsCandlesticks: true
        )
    }

    private func identifier(_ symbol: String, market: StockMarket) -> String {
        switch market {
        case .aShare:
            let prefix: String
            if symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9") {
                prefix = "sh"
            } else if symbol.hasPrefix("4") || symbol.hasPrefix("8") {
                prefix = "bj"
            } else {
                prefix = "sz"
            }
            return prefix + symbol.lowercased()
        case .hongKong:
            return "hk" + symbol
        case .unitedStates:
            return "us" + symbol.uppercased()
        }
    }

    private func parsePoint(_ values: [Any], market: StockMarket) -> StockChartPoint? {
        guard values.count >= 6,
              let dateText = values[0] as? String,
              let date = parseDate(dateText, market: market),
              let open = double(values[1]),
              let close = double(values[2]),
              let high = double(values[3]),
              let low = double(values[4]),
              close > 0 else { return nil }
        return StockChartPoint(
            date: date,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: double(values[5])
        )
    }

    private func parseDate(_ text: String, market: StockMarket) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = StockChartSeriesProcessor.marketTimeZone(market)
        formatter.dateFormat = text.contains("-") ? "yyyy-MM-dd" : "yyyyMMddHHmm"
        return formatter.date(from: text)
    }

    private func double(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func doubleValue(in values: [Any]?, at index: Int) -> Double? {
        guard let values, index < values.count else { return nil }
        return double(values[index])
    }

    private func stringValue(in values: [Any]?, at index: Int) -> String? {
        guard let values, index < values.count else { return nil }
        return values[index] as? String
    }

    private func minutePayload(
        in payload: [String: Any],
        requestedInterval: String
    ) -> [[Any]]? {
        if let requested = payload[requestedInterval] as? [[Any]] {
            return requested
        }
        let candidates = payload.keys.compactMap { key -> (minutes: Int, key: String)? in
            guard key.first == "m",
                  let minutes = Int(String(key.dropFirst())),
                  minutes >= 1 else { return nil }
            return (minutes, key)
        }
        guard let selected = candidates.min(by: { $0.minutes < $1.minutes }) else {
            return nil
        }
        return payload[selected.key] as? [[Any]]
    }
}

#endif
