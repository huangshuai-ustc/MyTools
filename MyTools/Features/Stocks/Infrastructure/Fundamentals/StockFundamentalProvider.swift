#if MYTOOLS_FEATURE_STOCKS
import Foundation

protocol StockFundamentalProviding: Sendable {
    func fetchFundamentals(for stock: StockHolding) async -> StockFundamentalSnapshot?
}

struct StockFundamentalProviders: Sendable {
    let eastmoney: any StockFundamentalProviding
    let yahoo: any StockFundamentalProviding

    init(
        eastmoney: any StockFundamentalProviding = EastmoneyStockFundamentalProvider(),
        yahoo: any StockFundamentalProviding = YahooStockFundamentalProvider()
    ) {
        self.eastmoney = eastmoney
        self.yahoo = yahoo
    }
}

struct EastmoneyStockFundamentalProvider: StockFundamentalProviding {
    private struct Envelope: Decodable {
        let data: Payload?
    }

    private struct Payload: Decodable {
        let priceEarningsRatio: FlexibleNumber?
        let priceBookRatio: FlexibleNumber?

        private enum CodingKeys: String, CodingKey {
            case priceEarningsRatio = "f162"
            case priceBookRatio = "f167"
        }
    }

    private struct FlexibleNumber: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
            } else if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = Double(text)
            } else {
                value = nil
            }
        }
    }

    private let httpClient: any StockQuoteHTTPClient
    private let now: @Sendable () -> Date

    init(
        httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.now = now
    }

    func fetchFundamentals(for stock: StockHolding) async -> StockFundamentalSnapshot? {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty,
              let identifier = StockQuoteProviderSupport.eastmoneyIdentifier(
                  symbol: symbol,
                  market: stock.market
              ) else { return nil }

        var components = URLComponents(
            string: "https://push2.eastmoney.com/api/qt/stock/get"
        )
        components?.queryItems = [
            URLQueryItem(name: "secid", value: identifier),
            URLQueryItem(name: "fields", value: "f162,f167")
        ]
        guard let url = components?.url else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 8,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://quote.eastmoney.com/"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let payload = try? JSONDecoder().decode(Envelope.self, from: data).data else {
            return nil
        }
        let snapshot = StockFundamentalSnapshot(
            asOfDate: now(),
            source: "东方财富",
            priceEarningsRatioTTM: ratio(payload.priceEarningsRatio?.value),
            priceBookRatioMRQ: ratio(payload.priceBookRatio?.value)
        )
        return snapshot.availableMetricCount > 0 ? snapshot : nil
    }

    private func ratio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        // Eastmoney's f162/f167 ratio fields are encoded as hundredths.
        return value / 100
    }
}

struct YahooStockFundamentalProvider: StockFundamentalProviding {
    private struct Envelope: Decodable {
        let timeseries: TimeSeriesEnvelope
    }

    private struct TimeSeriesEnvelope: Decodable {
        let result: [TimeSeriesResult]?
    }

    private struct TimeSeriesResult: Decodable {
        let type: String
        let values: [TimeSeriesValue]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            let meta = try container.decode(Meta.self, forKey: DynamicCodingKey("meta"))
            type = meta.type.first ?? ""
            guard !type.isEmpty else {
                values = []
                return
            }
            values = (try? container.decode(
                [TimeSeriesValue].self,
                forKey: DynamicCodingKey(type)
            )) ?? []
        }
    }

    private struct Meta: Decodable {
        let type: [String]
    }

    private struct TimeSeriesValue: Decodable {
        let asOfDate: String?
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            asOfDate = try container.decodeIfPresent(String.self, forKey: .asOfDate)
            if let reportedValue = try? container.decode(
                RawValue.self,
                forKey: .reportedValue
            ) {
                value = reportedValue.raw
            } else if let dataValue = try? container.decode(
                NumberValue.self,
                forKey: .dataValue
            ) {
                value = dataValue.value
            } else {
                value = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case asOfDate
            case reportedValue
            case dataValue
        }
    }

    private struct RawValue: Decodable {
        let raw: Double?
    }

    private struct NumberValue: Decodable {
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

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private struct Metric {
        let value: Double
        let date: Date?
    }

    private let httpClient: any StockQuoteHTTPClient
    private let now: @Sendable () -> Date

    init(
        httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.now = now
    }

    func fetchFundamentals(for stock: StockHolding) async -> StockFundamentalSnapshot? {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query2.finance.yahoo.com"
        components.path = "/ws/fundamentals-timeseries/v1/finance/timeseries/\(identifier(symbol, market: stock.market))"
        components.queryItems = [
            URLQueryItem(name: "symbol", value: identifier(symbol, market: stock.market)),
            URLQueryItem(
                name: "type",
                value: [
                    "trailingPeRatio",
                    "trailingPbRatio",
                    "trailingDividendYield",
                    "annualTotalRevenue",
                    "annualNetIncome",
                    "annualStockholdersEquity"
                ].joined(separator: ",")
            ),
            URLQueryItem(name: "merge", value: "false"),
            URLQueryItem(
                name: "period1",
                value: String(Int(now().addingTimeInterval(-5 * 365 * 24 * 60 * 60).timeIntervalSince1970))
            ),
            URLQueryItem(
                name: "period2",
                value: String(Int(now().addingTimeInterval(24 * 60 * 60).timeIntervalSince1970))
            )
        ]
        guard let url = components.url else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 10,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://finance.yahoo.com/"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let results = try? JSONDecoder().decode(Envelope.self, from: data)
                .timeseries.result else {
            return nil
        }

        let trailingPE = latestMetric("trailingPeRatio", in: results)
        let trailingPB = latestMetric("trailingPbRatio", in: results)
        let dividendYield = latestMetric("trailingDividendYield", in: results)
        let revenue = annualMetrics("annualTotalRevenue", in: results)
        let netIncome = annualMetrics("annualNetIncome", in: results)
        let equity = latestMetric("annualStockholdersEquity", in: results)
        let asOfDate = [
            trailingPE?.date,
            trailingPB?.date,
            dividendYield?.date,
            revenue.last?.date,
            netIncome.last?.date,
            equity?.date
        ].compactMap { $0 }.max() ?? now()
        let snapshot = StockFundamentalSnapshot(
            asOfDate: asOfDate,
            source: "Yahoo Finance",
            priceEarningsRatioTTM: positiveValue(trailingPE?.value),
            priceBookRatioMRQ: positiveValue(trailingPB?.value),
            dividendYield: positiveValue(dividendYield?.value),
            returnOnEquity: ratio(
                numerator: latestValue(netIncome),
                denominator: equity?.value
            ),
            netProfitMargin: ratio(
                numerator: latestValue(netIncome),
                denominator: latestValue(revenue)
            ),
            revenueGrowth: growth(revenue),
            earningsGrowth: growth(netIncome)
        )
        return snapshot.availableMetricCount > 0 ? snapshot : nil
    }

    private func latestMetric(
        _ type: String,
        in results: [TimeSeriesResult]
    ) -> Metric? {
        results.first(where: { $0.type == type })?.values
            .compactMap(metric)
            .max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    private func annualMetrics(
        _ type: String,
        in results: [TimeSeriesResult]
    ) -> [Metric] {
        results.first(where: { $0.type == type })?.values
            .compactMap(metric)
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } ?? []
    }

    private func metric(_ value: TimeSeriesValue) -> Metric? {
        guard let number = value.value, number.isFinite else { return nil }
        return Metric(value: number, date: parseDate(value.asOfDate))
    }

    private func latestValue(_ values: [Metric]) -> Double? {
        values.last?.value
    }

    private func positiveValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func ratio(numerator: Double?, denominator: Double?) -> Double? {
        guard let numerator, let denominator, denominator != 0,
              numerator.isFinite, denominator.isFinite else { return nil }
        let value = numerator / denominator
        return value.isFinite ? value : nil
    }

    private func growth(_ values: [Metric]) -> Double? {
        guard values.count >= 2,
              let previous = values.dropLast().last?.value,
              let latest = values.last?.value,
              previous > 0,
              previous.isFinite,
              latest.isFinite else { return nil }
        let value = latest / previous - 1
        return value.isFinite ? value : nil
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func identifier(_ symbol: String, market: StockMarket) -> String {
        switch market {
        case .aShare:
            let suffix = symbol.hasPrefix("5") || symbol.hasPrefix("6")
                || symbol.hasPrefix("9") ? ".SS"
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
}

#endif
