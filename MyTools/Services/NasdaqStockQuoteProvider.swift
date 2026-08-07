import Foundation

struct NasdaqStockQuoteProvider: StockQuoteProviding {
    private struct Envelope: Decodable {
        let data: Quote?
    }

    private struct Quote: Decodable {
        let symbol: String
        let companyName: String
        let primaryData: PriceData?
        let secondaryData: PriceData?
    }

    private struct PriceData: Decodable {
        let lastSalePrice: String
        let netChange: String
        let percentageChange: String
        let lastTradeTimestamp: String
        let isRealTime: Bool
    }

    private let httpClient: any StockQuoteHTTPClient

    init(httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
        guard stock.market == .unitedStates else { return nil }
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.nasdaq.com"
        components.path = "/api/quote/\(symbol)/info"
        components.queryItems = [URLQueryItem(name: "assetclass", value: "stocks")]
        guard let url = components.url else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 10,
            headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36",
                "Accept": "application/json, text/plain, */*",
                "Origin": "https://www.nasdaq.com",
                "Referer": "https://www.nasdaq.com/market-activity/stocks/\(symbol.lowercased())"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let quote = try? JSONDecoder().decode(Envelope.self, from: data).data else {
            return nil
        }

        // primaryData is the regular session. secondaryData may be pre/post-market.
        let priceData = quote.primaryData ?? quote.secondaryData
        guard let priceData,
              let latestPrice = StockQuoteProviderSupport.decimal(priceData.lastSalePrice),
              latestPrice > 0 else { return nil }
        let netChange = StockQuoteProviderSupport.decimal(priceData.netChange)
        return StockQuote(
            symbol: quote.symbol,
            name: quote.companyName,
            latestPrice: latestPrice,
            previousClose: netChange.map { latestPrice - $0 },
            changePercent: StockQuoteProviderSupport.decimal(
                priceData.percentageChange
            ).map { $0 / 100 },
            updatedAt: StockQuoteProviderSupport.nasdaqDate(
                priceData.lastTradeTimestamp
            ) ?? Date(),
            source: "Nasdaq"
        )
    }
}
