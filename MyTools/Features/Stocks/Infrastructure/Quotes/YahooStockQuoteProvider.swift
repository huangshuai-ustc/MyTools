#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct YahooStockQuoteProvider: StockQuoteProviding {
    private struct Envelope: Decodable {
        let chart: Chart
    }

    private struct Chart: Decodable {
        let result: [Result]?
    }

    private struct Result: Decodable {
        let meta: Meta
    }

    private struct Meta: Decodable {
        let symbol: String
        let longName: String?
        let shortName: String?
        let regularMarketPrice: Double?
        let chartPreviousClose: Double?
        let previousClose: Double?
        let regularMarketTime: TimeInterval?
    }

    private let httpClient: any StockQuoteHTTPClient

    init(httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty,
              let identifier = StockQuoteProviderSupport.yahooIdentifier(
                symbol: symbol,
                market: stock.market
              ) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.path = "/v8/finance/chart/\(identifier)"
        components.queryItems = [
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "range", value: "1d")
        ]
        guard let url = components.url else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 10,
            headers: ["User-Agent": "Mozilla/5.0"]
        )
        guard let data = try? await httpClient.data(for: request),
              let meta = try? JSONDecoder().decode(Envelope.self, from: data)
                .chart.result?.first?.meta,
              let rawLatestPrice = meta.regularMarketPrice,
              rawLatestPrice > 0 else { return nil }

        let latestPrice = Decimal(rawLatestPrice)
        let previousClose = (meta.previousClose ?? meta.chartPreviousClose).map { Decimal($0) }
        return StockQuote(
            symbol: symbol,
            name: meta.longName ?? meta.shortName ?? "",
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: StockQuoteProviderSupport.percentageChange(
                latestPrice: latestPrice,
                previousClose: previousClose
            ),
            updatedAt: meta.regularMarketTime.map {
                Date(timeIntervalSince1970: $0)
            } ?? Date(),
            source: "Yahoo Finance"
        )
    }
}

#endif
