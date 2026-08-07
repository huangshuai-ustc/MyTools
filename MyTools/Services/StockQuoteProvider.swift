import Foundation

protocol StockQuoteProviding: Sendable {
    func fetchQuote(for stock: StockHolding) async -> StockQuote?
}

protocol StockQuoteBatchProviding: StockQuoteProviding {
    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote]
}

struct StockQuoteProviders: Sendable {
    let tencent: any StockQuoteBatchProviding
    let sina: any StockQuoteBatchProviding
    let officialAShare: any StockQuoteProviding
    let eastmoney: any StockQuoteProviding
    let nasdaq: any StockQuoteProviding
    let yahoo: any StockQuoteProviding

    init(
        tencent: any StockQuoteBatchProviding = TencentStockQuoteProvider(),
        sina: any StockQuoteBatchProviding = SinaStockQuoteProvider(),
        officialAShare: any StockQuoteProviding = OfficialAShareStockQuoteProvider(),
        eastmoney: any StockQuoteProviding = EastmoneyStockQuoteProvider(),
        nasdaq: any StockQuoteProviding = NasdaqStockQuoteProvider(),
        yahoo: any StockQuoteProviding = YahooStockQuoteProvider()
    ) {
        self.tencent = tencent
        self.sina = sina
        self.officialAShare = officialAShare
        self.eastmoney = eastmoney
        self.nasdaq = nasdaq
        self.yahoo = yahoo
    }
}

protocol StockQuoteHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> Data
}

struct URLSessionStockQuoteHTTPClient: StockQuoteHTTPClient {
    func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw StockQuoteError.invalidResponse
        }
        return data
    }
}

enum StockQuoteProviderSupport {
    static let batchSize = 40

    static func request(
        url: URL,
        timeout: TimeInterval,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    static func symbol(for stock: StockHolding) -> String {
        StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
    }

    static func sinaIdentifier(for stock: StockHolding) -> String {
        sinaIdentifier(symbol: symbol(for: stock), market: stock.market)
    }

    static func sinaIdentifier(symbol: String, market: StockMarket) -> String {
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
            return "gb_" + symbol.lowercased()
        }
    }

    static func tencentIdentifier(for stock: StockHolding) -> String? {
        let symbol = symbol(for: stock)
        guard !symbol.isEmpty else { return nil }
        switch stock.market {
        case .aShare:
            return sinaIdentifier(symbol: symbol, market: .aShare)
        case .hongKong:
            return "r_hk\(symbol)"
        case .unitedStates:
            return "us\(symbol.uppercased())"
        }
    }

    static func eastmoneyIdentifier(symbol: String, market: StockMarket) -> String? {
        switch market {
        case .aShare:
            if symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9") {
                return "1.\(symbol)"
            }
            return "0.\(symbol)"
        case .hongKong:
            return "116.\(symbol)"
        case .unitedStates:
            // The exchange cannot be inferred safely from a US ticker alone.
            return nil
        }
    }

    static func yahooIdentifier(symbol: String, market: StockMarket) -> String? {
        switch market {
        case .hongKong:
            return "\(symbol).HK"
        case .unitedStates:
            return symbol
        case .aShare:
            return nil
        }
    }

    static func decimal(_ value: String) -> Decimal? {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func decimal(_ value: Any) -> Decimal? {
        if let value = value as? NSNumber { return value.decimalValue }
        if let value = value as? String { return decimal(value) }
        return nil
    }

    static func percentageChange(
        latestPrice: Decimal,
        previousClose: Decimal?
    ) -> Decimal? {
        previousClose.flatMap { $0 > 0 ? (latestPrice - $0) / $0 : nil }
    }

    static func quoteDate(_ value: String, timeZoneIdentifier: String) -> Date? {
        date(
            value,
            format: "yyyy-MM-dd HH:mm:ss",
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    static func compactQuoteDate(_ value: String, timeZoneIdentifier: String) -> Date? {
        date(
            value,
            format: "yyyyMMddHHmmss",
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    static func slashQuoteDate(_ value: String, timeZoneIdentifier: String) -> Date? {
        for format in ["yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm"] {
            if let date = date(value, format: format, timeZoneIdentifier: timeZoneIdentifier) {
                return date
            }
        }
        return nil
    }

    static func exchangeDate(
        date: Any,
        time: Any,
        timeZoneIdentifier: String
    ) -> Date? {
        let rawDate = String(describing: date)
        guard let timeValue = decimal(time) else { return nil }
        let rawTime = String(format: "%06d", NSDecimalNumber(decimal: timeValue).intValue)
        return compactQuoteDate(
            rawDate + rawTime,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    static func nasdaqDate(_ value: String) -> Date? {
        let normalized = value
            .replacingOccurrences(of: "Closed at ", with: "")
            .replacingOccurrences(of: " ET", with: "")
        return date(
            normalized,
            format: "MMM d, yyyy h:mm a",
            timeZoneIdentifier: "America/New_York"
        )
    }

    static func decodeSinaResponse(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? decodeGB18030(data)
    }

    static func decodeGB18030(_ data: Data) -> String? {
        String(
            data: data,
            encoding: .init(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        )
    }

    static func chunks<Element>(_ values: [Element], maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [] }
        return stride(from: 0, to: values.count, by: maxCount).map { start in
            Array(values[start..<Swift.min(start + maxCount, values.count)])
        }
    }

    private static func date(
        _ value: String,
        format: String,
        timeZoneIdentifier: String
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = format
        return formatter.date(from: value)
    }
}
