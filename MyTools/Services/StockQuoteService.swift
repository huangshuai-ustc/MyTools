import Foundation

struct StockQuote: Sendable {
    let symbol: String
    let name: String
    let latestPrice: Decimal
    let previousClose: Decimal?
    let changePercent: Decimal?
    let updatedAt: Date
    let source: String
}

enum StockQuoteError: LocalizedError, Sendable {
    case invalidSymbol
    case invalidResponse
    case quoteUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSymbol:
            return "股票代码无效。"
        case .invalidResponse:
            return "行情服务返回了无效数据。"
        case .quoteUnavailable:
            return "暂时无法取得该股票的行情。"
        }
    }
}

actor StockQuoteService {
    private struct ShenzhenEnvelope: Decodable {
        let data: ShenzhenQuote?
    }

    private struct ShenzhenQuote: Decodable {
        let name: String
        let close: String
        let now: String
        let deltaPercent: String
        let marketTime: String
    }

    private struct NasdaqEnvelope: Decodable {
        let data: NasdaqQuote?
    }

    private struct NasdaqQuote: Decodable {
        let symbol: String
        let companyName: String
        let primaryData: NasdaqPriceData?
        let secondaryData: NasdaqPriceData?
    }

    private struct NasdaqPriceData: Decodable {
        let lastSalePrice: String
        let netChange: String
        let percentageChange: String
        let lastTradeTimestamp: String
        let isRealTime: Bool
    }

    private struct YahooEnvelope: Decodable {
        let chart: YahooChart
    }

    private struct YahooChart: Decodable {
        let result: [YahooResult]?
    }

    private struct YahooResult: Decodable {
        let meta: YahooMeta
    }

    private struct YahooMeta: Decodable {
        let symbol: String
        let longName: String?
        let shortName: String?
        let regularMarketPrice: Double?
        let chartPreviousClose: Double?
        let regularMarketTime: TimeInterval?
    }

    private struct Envelope: Decodable {
        let data: QuotePayload?
    }

    private struct QuotePayload: Decodable {
        let latest: FlexibleNumber?
        let symbol: String?
        let name: String?
        let decimals: FlexibleNumber?
        let previousClose: FlexibleNumber?
        let changePercent: FlexibleNumber?

        private enum CodingKeys: String, CodingKey {
            case latest = "f43"
            case symbol = "f57"
            case name = "f58"
            case decimals = "f59"
            case previousClose = "f60"
            case changePercent = "f170"
        }
    }

    private struct FlexibleNumber: Decodable {
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

    func fetchQuote(for stock: StockHolding) async throws -> StockQuote {
        let symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        guard !symbol.isEmpty else { throw StockQuoteError.invalidSymbol }

        switch stock.market {
        case .aShare:
            if let officialQuote = await fetchOfficialAShareQuote(symbol: symbol) {
                return officialQuote
            }
            if let tencentQuote = try? await fetchTencentAShareQuote(symbol: symbol) {
                return tencentQuote
            }
            if let sinaQuote = try? await fetchSinaQuote(symbol: symbol, market: stock.market) {
                return sinaQuote
            }
        case .unitedStates:
            if let nasdaqQuote = try? await fetchNasdaqQuote(symbol: symbol) {
                return nasdaqQuote
            }
            if let yahooQuote = try? await fetchYahooQuote(symbol: symbol) {
                return yahooQuote
            }
            if let sinaQuote = try? await fetchSinaQuote(symbol: symbol, market: stock.market) {
                return sinaQuote
            }
        }

        for identifier in marketIdentifiers(for: symbol, market: stock.market) {
            do {
                if let quote = try await fetchEastmoneyQuote(identifier: identifier, fallbackSymbol: symbol) {
                    return quote
                }
            } catch {
                // 美股代码可能属于不同市场编号，需要继续尝试其余编号。
            }
        }
        throw StockQuoteError.quoteUnavailable
    }

    private func fetchOfficialAShareQuote(symbol: String) async -> StockQuote? {
        if symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9") {
            return try? await fetchShanghaiQuote(symbol: symbol)
        }
        if symbol.hasPrefix("4") || symbol.hasPrefix("8") {
            return nil
        }
        return try? await fetchShenzhenQuote(symbol: symbol)
    }

    private func fetchShanghaiQuote(symbol: String) async throws -> StockQuote? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "yunhq.sse.com.cn"
        components.port = 32042
        components.path = "/v1/sh1/snap/\(symbol)"
        components.queryItems = [
            URLQueryItem(name: "select", value: "name,last,prev_close,chg_rate,date,time")
        ]
        guard let url = components.url else { throw StockQuoteError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.sse.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard isSuccessful(response),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["snap"] as? [Any],
              values.count > 5,
              let name = values[0] as? String,
              let latestPrice = decimal(values[1]),
              latestPrice > 0 else {
            throw StockQuoteError.invalidResponse
        }

        let previousClose = decimal(values[2])
        let changePercent = decimal(values[3]).map { $0 / 100 }
        let updatedAt = exchangeDate(date: values[4], time: values[5], timeZoneIdentifier: "Asia/Shanghai") ?? Date()
        return StockQuote(
            symbol: symbol,
            name: name,
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: changePercent,
            updatedAt: updatedAt,
            source: "上海证券交易所"
        )
    }

    private func fetchShenzhenQuote(symbol: String) async throws -> StockQuote? {
        var components = URLComponents(string: "https://www.szse.cn/api/market/ssjjhq/getTimeData")
        components?.queryItems = [
            URLQueryItem(name: "marketId", value: "1"),
            URLQueryItem(name: "code", value: symbol)
        ]
        guard let url = components?.url else { throw StockQuoteError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.szse.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard isSuccessful(response),
              let quote = try JSONDecoder().decode(ShenzhenEnvelope.self, from: data).data,
              let latestPrice = decimal(quote.now),
              latestPrice > 0 else {
            throw StockQuoteError.invalidResponse
        }

        return StockQuote(
            symbol: symbol,
            name: quote.name,
            latestPrice: latestPrice,
            previousClose: decimal(quote.close),
            changePercent: decimal(quote.deltaPercent).map { $0 / 100 },
            updatedAt: quoteDate(quote.marketTime, timeZoneIdentifier: "Asia/Shanghai") ?? Date(),
            source: "深圳证券交易所"
        )
    }

    private func fetchTencentAShareQuote(symbol: String) async throws -> StockQuote? {
        let identifier = sinaIdentifier(for: symbol, market: .aShare)
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(identifier)") else {
            throw StockQuoteError.invalidResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://stockapp.finance.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard isSuccessful(response),
              let body = decodeGB18030(data),
              let firstQuote = body.firstIndex(of: "\""),
              let lastQuote = body.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            throw StockQuoteError.invalidResponse
        }

        let payload = body[body.index(after: firstQuote)..<lastQuote]
        let fields = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > 32,
              let latestPrice = decimal(fields[3]),
              latestPrice > 0 else { return nil }

        return StockQuote(
            symbol: fields[2].isEmpty ? symbol : fields[2],
            name: fields[1],
            latestPrice: latestPrice,
            previousClose: decimal(fields[4]),
            changePercent: decimal(fields[32]).map { $0 / 100 },
            updatedAt: compactQuoteDate(fields[30], timeZoneIdentifier: "Asia/Shanghai") ?? Date(),
            source: "腾讯证券"
        )
    }

    private func fetchNasdaqQuote(symbol: String) async throws -> StockQuote? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.nasdaq.com"
        components.path = "/api/quote/\(symbol)/info"
        components.queryItems = [URLQueryItem(name: "assetclass", value: "stocks")]
        guard let url = components.url else { throw StockQuoteError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.nasdaq.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.nasdaq.com/market-activity/stocks/\(symbol.lowercased())", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard isSuccessful(response),
              let quote = try JSONDecoder().decode(NasdaqEnvelope.self, from: data).data else {
            throw StockQuoteError.invalidResponse
        }

        let priceData: NasdaqPriceData?
        if quote.primaryData?.isRealTime == true {
            priceData = quote.primaryData
        } else {
            priceData = quote.secondaryData ?? quote.primaryData
        }
        guard let priceData, let latestPrice = decimal(priceData.lastSalePrice), latestPrice > 0 else { return nil }
        let netChange = decimal(priceData.netChange)
        return StockQuote(
            symbol: quote.symbol,
            name: quote.companyName,
            latestPrice: latestPrice,
            previousClose: netChange.map { latestPrice - $0 },
            changePercent: decimal(priceData.percentageChange).map { $0 / 100 },
            updatedAt: nasdaqDate(priceData.lastTradeTimestamp) ?? Date(),
            source: "Nasdaq"
        )
    }

    private func fetchYahooQuote(symbol: String) async throws -> StockQuote? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.path = "/v8/finance/chart/\(symbol)"
        components.queryItems = [
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "range", value: "1d")
        ]
        guard let url = components.url else { throw StockQuoteError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard isSuccessful(response),
              let meta = try JSONDecoder().decode(YahooEnvelope.self, from: data).chart.result?.first?.meta,
              let rawLatestPrice = meta.regularMarketPrice,
              rawLatestPrice > 0 else {
            throw StockQuoteError.invalidResponse
        }

        let latestPrice = Decimal(rawLatestPrice)
        let previousClose = meta.chartPreviousClose.map { Decimal($0) }
        let changePercent = previousClose.flatMap { close in close > 0 ? (latestPrice - close) / close : nil }
        return StockQuote(
            symbol: meta.symbol,
            name: meta.longName ?? meta.shortName ?? "",
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: changePercent,
            updatedAt: meta.regularMarketTime.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            source: "Yahoo Finance"
        )
    }

    private func fetchSinaQuote(symbol: String, market: StockMarket) async throws -> StockQuote? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "hq.sinajs.cn"
        components.path = "/list=\(sinaIdentifier(for: symbol, market: market))"
        guard let url = components.url else { throw StockQuoteError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let body = decodeSinaResponse(data),
              let firstQuote = body.firstIndex(of: "\""),
              let lastQuote = body.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            throw StockQuoteError.invalidResponse
        }

        let payload = body[body.index(after: firstQuote)..<lastQuote]
        guard !payload.isEmpty else { return nil }
        let fields = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        switch market {
        case .aShare:
            return parseSinaAShare(fields: fields, fallbackSymbol: symbol)
        case .unitedStates:
            return parseSinaUnitedStates(fields: fields, fallbackSymbol: symbol)
        }
    }

    private func parseSinaAShare(fields: [String], fallbackSymbol: String) -> StockQuote? {
        guard fields.count > 31,
              let latestPrice = decimal(fields[3]),
              latestPrice > 0 else { return nil }

        let previousClose = decimal(fields[2])
        let changePercent = previousClose.flatMap { close in
            close > 0 ? (latestPrice - close) / close : nil
        }
        let updatedAt = quoteDate(
            "\(fields[30]) \(fields[31])",
            timeZoneIdentifier: "Asia/Shanghai"
        ) ?? Date()

        return StockQuote(
            symbol: fallbackSymbol,
            name: fields[0],
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: changePercent,
            updatedAt: updatedAt,
            source: "新浪财经"
        )
    }

    private func parseSinaUnitedStates(fields: [String], fallbackSymbol: String) -> StockQuote? {
        guard fields.count > 4,
              let latestPrice = decimal(fields[1]),
              latestPrice > 0 else { return nil }

        let changeAmount = decimal(fields[4])
        let previousClose = changeAmount.map { latestPrice - $0 }
        let changePercent = decimal(fields[2]).map { $0 / 100 }
        let updatedAt = quoteDate(
            fields[3],
            timeZoneIdentifier: "America/New_York"
        ) ?? Date()

        return StockQuote(
            symbol: fallbackSymbol,
            name: fields[0],
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: changePercent,
            updatedAt: updatedAt,
            source: "新浪财经"
        )
    }

    private func fetchEastmoneyQuote(identifier: String, fallbackSymbol: String) async throws -> StockQuote? {
        var components = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/get")
        components?.queryItems = [
            URLQueryItem(name: "secid", value: identifier),
            URLQueryItem(name: "fields", value: "f43,f57,f58,f59,f60,f170")
        ]
        guard let url = components?.url else { throw StockQuoteError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw StockQuoteError.invalidResponse
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = envelope.data,
              let rawLatest = payload.latest?.value,
              rawLatest >= 0 else {
            return nil
        }

        let decimalPlaces = Int(payload.decimals?.value ?? 2)
        let divisor = pow(10.0, Double(decimalPlaces))
        let latestPrice = Decimal(rawLatest / divisor)
        let previousClose = payload.previousClose?.value.map { Decimal($0 / divisor) }
        let percent = payload.changePercent?.value.map { Decimal($0 / 100) }

        return StockQuote(
            symbol: payload.symbol ?? fallbackSymbol,
            name: payload.name ?? "",
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: percent,
            updatedAt: Date(),
            source: "东方财富"
        )
    }

    private func sinaIdentifier(for symbol: String, market: StockMarket) -> String {
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
        case .unitedStates:
            return "gb_" + symbol.lowercased()
        }
    }

    private func decimal(_ value: String) -> Decimal? {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func decimal(_ value: Any) -> Decimal? {
        if let value = value as? NSNumber { return value.decimalValue }
        if let value = value as? String { return decimal(value) }
        return nil
    }

    private func isSuccessful(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(response.statusCode)
    }

    private func quoteDate(_ value: String, timeZoneIdentifier: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func compactQuoteDate(_ value: String, timeZoneIdentifier: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: value)
    }

    private func exchangeDate(date: Any, time: Any, timeZoneIdentifier: String) -> Date? {
        let rawDate = String(describing: date)
        guard let timeValue = decimal(time) else { return nil }
        let rawTime = String(format: "%06d", NSDecimalNumber(decimal: timeValue).intValue)
        return compactQuoteDate(rawDate + rawTime, timeZoneIdentifier: timeZoneIdentifier)
    }

    private func nasdaqDate(_ value: String) -> Date? {
        let normalized = value
            .replacingOccurrences(of: "Closed at ", with: "")
            .replacingOccurrences(of: " ET", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.date(from: normalized)
    }

    private func decodeSinaResponse(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? decodeGB18030(data)
    }

    private func decodeGB18030(_ data: Data) -> String? {
        String(
            data: data,
            encoding: .init(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        )
    }

    private func marketIdentifiers(for symbol: String, market: StockMarket) -> [String] {
        switch market {
        case .aShare:
            let marketNumber: String
            if symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9") {
                marketNumber = "1"
            } else if symbol.hasPrefix("4") || symbol.hasPrefix("8") {
                marketNumber = "0"
            } else {
                marketNumber = "0"
            }
            return ["\(marketNumber).\(symbol)"]
        case .unitedStates:
            return ["105.\(symbol)", "106.\(symbol)", "107.\(symbol)"]
        }
    }
}

struct ForeignExchangeRate: Sendable {
    let currencyCode: String
    let renminbiPerUnit: Decimal
    let updatedAt: Date
}

enum ForeignExchangeRateError: LocalizedError, Sendable {
    case invalidResponse
    case rateUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "中国银行外汇牌价返回了无效数据。"
        case .rateUnavailable: return "暂时无法取得中国银行美元现汇买入价。"
        }
    }
}

actor ForeignExchangeRateService {
    func fetchUSDBuyingRate() async throws -> ForeignExchangeRate {
        guard let url = URL(string: "https://www.boc.cn/sourcedb/whpj/") else {
            throw ForeignExchangeRateError.invalidResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("MyTools/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let html = decodeHTML(data) else {
            throw ForeignExchangeRateError.invalidResponse
        }

        let pattern = #"<tr[^>]*data-currency=['\"]美元['\"][^>]*>.*?<td[^>]*>\s*美元\s*</td>\s*<td[^>]*>\s*([0-9.]+)\s*</td>.*?<td[^>]*class=['\"]pjrq['\"][^>]*>\s*([^<]+)\s*</td>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let rateRange = Range(match.range(at: 1), in: html),
              let rawRate = Decimal(string: String(html[rateRange]), locale: Locale(identifier: "en_US_POSIX")) else {
            throw ForeignExchangeRateError.rateUnavailable
        }

        let updatedAt: Date
        if let dateRange = Range(match.range(at: 2), in: html) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
            updatedAt = formatter.date(from: String(html[dateRange]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date()
        } else {
            updatedAt = Date()
        }

        return ForeignExchangeRate(currencyCode: "USD", renminbiPerUnit: rawRate / 100, updatedAt: updatedAt)
    }

    private func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
    }
}
