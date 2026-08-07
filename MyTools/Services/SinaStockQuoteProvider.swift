import Foundation

struct SinaStockQuoteProvider: StockQuoteBatchProviding {
    private let httpClient: any StockQuoteHTTPClient

    init(httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchQuotes(for stocks: [StockHolding]) async -> [UUID: StockQuote] {
        var result: [UUID: StockQuote] = [:]
        for stockBatch in StockQuoteProviderSupport.chunks(
            stocks,
            maxCount: StockQuoteProviderSupport.batchSize
        ) {
            let stocksByIdentifier = stockBatch.reduce(into: [String: [StockHolding]]()) {
                result, stock in
                result[StockQuoteProviderSupport.sinaIdentifier(for: stock), default: []]
                    .append(stock)
            }
            guard !stocksByIdentifier.isEmpty,
                  let url = URL(
                    string: "https://hq.sinajs.cn/list=\(stocksByIdentifier.keys.sorted().joined(separator: ","))"
                  ) else { continue }
            let request = StockQuoteProviderSupport.request(
                url: url,
                timeout: 2,
                headers: [
                    "User-Agent": "Mozilla/5.0",
                    "Referer": "https://finance.sina.com.cn/"
                ]
            )
            guard let data = try? await httpClient.data(for: request),
                  let body = StockQuoteProviderSupport.decodeSinaResponse(data) else { continue }
            merge(body: body, stocksByIdentifier: stocksByIdentifier, into: &result)
        }
        return result
    }

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty,
              let url = URL(
                string: "https://hq.sinajs.cn/list=\(StockQuoteProviderSupport.sinaIdentifier(for: stock))"
              ) else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 8,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://finance.sina.com.cn/"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let body = StockQuoteProviderSupport.decodeSinaResponse(data),
              let fields = fields(in: body) else { return nil }
        return parse(fields: fields, stock: stock)
    }

    private func merge(
        body: String,
        stocksByIdentifier: [String: [StockHolding]],
        into result: inout [UUID: StockQuote]
    ) {
        for record in body.split(separator: ";", omittingEmptySubsequences: true) {
            guard let identifierStart = record.range(of: "hq_str_")?.upperBound,
                  let equalIndex = record.firstIndex(of: "="),
                  identifierStart < equalIndex,
                  let firstQuote = record.firstIndex(of: "\""),
                  let lastQuote = record.lastIndex(of: "\""),
                  firstQuote < lastQuote else { continue }
            let identifier = String(record[identifierStart..<equalIndex])
            guard let matchingStocks = stocksByIdentifier[identifier] else { continue }
            let payload = record[record.index(after: firstQuote)..<lastQuote]
            guard !payload.isEmpty else { continue }
            let fields = payload
                .split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            for stock in matchingStocks {
                if let quote = parse(fields: fields, stock: stock) {
                    result[stock.id] = quote
                }
            }
        }
    }

    private func fields(in body: String) -> [String]? {
        guard let firstQuote = body.firstIndex(of: "\""),
              let lastQuote = body.lastIndex(of: "\""),
              firstQuote < lastQuote else { return nil }
        let payload = body[body.index(after: firstQuote)..<lastQuote]
        guard !payload.isEmpty else { return nil }
        return payload
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func parse(fields: [String], stock: StockHolding) -> StockQuote? {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        switch stock.market {
        case .aShare:
            return parseAShare(fields: fields, symbol: symbol)
        case .hongKong:
            return parseHongKong(fields: fields, symbol: symbol)
        case .unitedStates:
            return parseUnitedStates(fields: fields, symbol: symbol)
        }
    }

    private func parseAShare(fields: [String], symbol: String) -> StockQuote? {
        guard fields.count > 31,
              let latestPrice = StockQuoteProviderSupport.decimal(fields[3]),
              latestPrice > 0 else { return nil }
        let previousClose = StockQuoteProviderSupport.decimal(fields[2])
        return StockQuote(
            symbol: symbol,
            name: fields[0],
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: StockQuoteProviderSupport.percentageChange(
                latestPrice: latestPrice,
                previousClose: previousClose
            ),
            updatedAt: StockQuoteProviderSupport.quoteDate(
                "\(fields[30]) \(fields[31])",
                timeZoneIdentifier: "Asia/Shanghai"
            ) ?? Date(),
            source: "新浪财经"
        )
    }

    private func parseUnitedStates(fields: [String], symbol: String) -> StockQuote? {
        guard fields.count > 4,
              let latestPrice = StockQuoteProviderSupport.decimal(fields[1]),
              latestPrice > 0 else { return nil }
        let changeAmount = StockQuoteProviderSupport.decimal(fields[4])
        return StockQuote(
            symbol: symbol,
            name: fields[0],
            latestPrice: latestPrice,
            previousClose: changeAmount.map { latestPrice - $0 },
            changePercent: StockQuoteProviderSupport.decimal(fields[2]).map { $0 / 100 },
            // Sina reports this field in Beijing time, including for US stocks.
            updatedAt: StockQuoteProviderSupport.quoteDate(
                fields[3],
                timeZoneIdentifier: "Asia/Shanghai"
            ) ?? Date(),
            source: "新浪财经"
        )
    }

    private func parseHongKong(fields: [String], symbol: String) -> StockQuote? {
        guard fields.count > 18,
              let latestPrice = StockQuoteProviderSupport.decimal(fields[6]),
              latestPrice > 0 else { return nil }
        let previousClose = StockQuoteProviderSupport.decimal(fields[3])
        return StockQuote(
            symbol: symbol,
            name: fields[1].isEmpty ? fields[0] : fields[1],
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: StockQuoteProviderSupport.percentageChange(
                latestPrice: latestPrice,
                previousClose: previousClose
            ),
            updatedAt: StockQuoteProviderSupport.slashQuoteDate(
                "\(fields[17]) \(fields[18])",
                timeZoneIdentifier: "Asia/Hong_Kong"
            ) ?? Date(),
            source: "新浪财经"
        )
    }
}
