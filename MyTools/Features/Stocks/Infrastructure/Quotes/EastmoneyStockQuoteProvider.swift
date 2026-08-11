#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct EastmoneyStockQuoteProvider: StockQuoteProviding {
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

    private let httpClient: any StockQuoteHTTPClient

    init(httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
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
            URLQueryItem(name: "fields", value: "f43,f57,f58,f59,f60,f170")
        ]
        guard let url = components?.url else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 6,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://quote.eastmoney.com/"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = envelope.data,
              let rawLatest = payload.latest?.value,
              rawLatest >= 0 else { return nil }

        let decimalPlaces = Int(payload.decimals?.value ?? 2)
        let divisor = pow(10.0, Double(decimalPlaces))
        return StockQuote(
            symbol: payload.symbol ?? symbol,
            name: payload.name ?? "",
            latestPrice: Decimal(rawLatest / divisor),
            previousClose: payload.previousClose?.value.map { Decimal($0 / divisor) },
            changePercent: payload.changePercent?.value.map { Decimal($0 / 100) },
            updatedAt: Date(),
            source: "东方财富"
        )
    }
}

#endif
