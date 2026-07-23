import Foundation

struct StockQuote: Sendable {
    let symbol: String
    let name: String
    let latestPrice: Decimal
    let previousClose: Decimal?
    let changePercent: Decimal?
    let updatedAt: Date
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

        for identifier in marketIdentifiers(for: symbol, market: stock.market) {
            if let quote = try await fetchQuote(identifier: identifier, fallbackSymbol: symbol) {
                return quote
            }
        }
        throw StockQuoteError.quoteUnavailable
    }

    private func fetchQuote(identifier: String, fallbackSymbol: String) async throws -> StockQuote? {
        var components = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/get")
        components?.queryItems = [
            URLQueryItem(name: "secid", value: identifier),
            URLQueryItem(name: "fields", value: "f43,f57,f58,f59,f60,f170")
        ]
        guard let url = components?.url else { throw StockQuoteError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("MyTools/1.0", forHTTPHeaderField: "User-Agent")
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
            updatedAt: Date()
        )
    }

    private func marketIdentifiers(for symbol: String, market: StockMarket) -> [String] {
        switch market {
        case .aShare:
            let marketNumber = symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9") ? "1" : "0"
            return ["\(marketNumber).\(symbol)"]
        case .unitedStates:
            return ["105.\(symbol)", "106.\(symbol)", "107.\(symbol)"]
        }
    }
}
