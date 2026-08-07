import Foundation

struct OfficialAShareStockQuoteProvider: StockQuoteProviding {
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

    private let httpClient: any StockQuoteHTTPClient

    init(httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
        guard stock.market == .aShare else { return nil }
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty else { return nil }
        if symbol.hasPrefix("5") || symbol.hasPrefix("6") || symbol.hasPrefix("9") {
            return await fetchShanghaiQuote(symbol: symbol)
        }
        if symbol.hasPrefix("4") || symbol.hasPrefix("8") {
            return nil
        }
        return await fetchShenzhenQuote(symbol: symbol)
    }

    private func fetchShanghaiQuote(symbol: String) async -> StockQuote? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "yunhq.sse.com.cn"
        components.port = 32042
        components.path = "/v1/sh1/snap/\(symbol)"
        components.queryItems = [
            URLQueryItem(name: "select", value: "name,last,prev_close,chg_rate,date,time")
        ]
        guard let url = components.url else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 8,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://www.sse.com.cn/"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["snap"] as? [Any],
              values.count > 5,
              let name = values[0] as? String,
              let latestPrice = StockQuoteProviderSupport.decimal(values[1]),
              latestPrice > 0 else { return nil }

        return StockQuote(
            symbol: symbol,
            name: name,
            latestPrice: latestPrice,
            previousClose: StockQuoteProviderSupport.decimal(values[2]),
            changePercent: StockQuoteProviderSupport.decimal(values[3]).map { $0 / 100 },
            updatedAt: StockQuoteProviderSupport.exchangeDate(
                date: values[4],
                time: values[5],
                timeZoneIdentifier: "Asia/Shanghai"
            ) ?? Date(),
            source: "上海证券交易所"
        )
    }

    private func fetchShenzhenQuote(symbol: String) async -> StockQuote? {
        var components = URLComponents(
            string: "https://www.szse.cn/api/market/ssjjhq/getTimeData"
        )
        components?.queryItems = [
            URLQueryItem(name: "marketId", value: "1"),
            URLQueryItem(name: "code", value: symbol)
        ]
        guard let url = components?.url else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 8,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://www.szse.cn/"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let quote = try? JSONDecoder().decode(ShenzhenEnvelope.self, from: data).data,
              let latestPrice = StockQuoteProviderSupport.decimal(quote.now),
              latestPrice > 0 else { return nil }

        return StockQuote(
            symbol: symbol,
            name: quote.name,
            latestPrice: latestPrice,
            previousClose: StockQuoteProviderSupport.decimal(quote.close),
            changePercent: StockQuoteProviderSupport.decimal(quote.deltaPercent).map { $0 / 100 },
            updatedAt: StockQuoteProviderSupport.quoteDate(
                quote.marketTime,
                timeZoneIdentifier: "Asia/Shanghai"
            ) ?? Date(),
            source: "深圳证券交易所"
        )
    }
}
