import Foundation

struct TencentStockQuoteProvider: StockQuoteBatchProviding {
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
                guard let identifier = StockQuoteProviderSupport.tencentIdentifier(for: stock) else {
                    return
                }
                result[identifier, default: []].append(stock)
            }
            guard !stocksByIdentifier.isEmpty,
                  let url = URL(
                    string: "https://qt.gtimg.cn/q=\(stocksByIdentifier.keys.sorted().joined(separator: ","))"
                  ) else { continue }

            let request = StockQuoteProviderSupport.request(
                url: url,
                timeout: 2,
                headers: [
                    "User-Agent": "Mozilla/5.0",
                    "Referer": "https://stockapp.finance.qq.com/"
                ]
            )
            guard let data = try? await httpClient.data(for: request),
                  let body = StockQuoteProviderSupport.decodeGB18030(data) else { continue }
            merge(body: body, stocksByIdentifier: stocksByIdentifier, into: &result)
        }
        return result
    }

    func fetchQuote(for stock: StockHolding) async -> StockQuote? {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard !symbol.isEmpty else { return nil }
        if stock.market == .unitedStates {
            return await fetchQuotes(for: [stock])[stock.id]
        }

        let identifier: String
        switch stock.market {
        case .aShare:
            identifier = StockQuoteProviderSupport.sinaIdentifier(
                symbol: symbol,
                market: .aShare
            )
        case .hongKong:
            identifier = "r_hk\(symbol)"
        case .unitedStates:
            return nil
        }
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(identifier)") else { return nil }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 8,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://stockapp.finance.qq.com/"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let body = StockQuoteProviderSupport.decodeGB18030(data),
              let fields = fields(in: body) else { return nil }
        return parse(fields: fields, stock: stock, requiresTimestamp: false)
    }

    private func merge(
        body: String,
        stocksByIdentifier: [String: [StockHolding]],
        into result: inout [UUID: StockQuote]
    ) {
        for record in body.split(separator: ";", omittingEmptySubsequences: true) {
            guard let equalIndex = record.firstIndex(of: "="),
                  let firstQuote = record.firstIndex(of: "\""),
                  let lastQuote = record.lastIndex(of: "\""),
                  firstQuote < lastQuote else { continue }
            let rawIdentifier = record[..<equalIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = rawIdentifier.hasPrefix("v_")
                ? String(rawIdentifier.dropFirst(2))
                : rawIdentifier
            guard let matchingStocks = stocksByIdentifier[identifier] else { continue }
            let payload = record[record.index(after: firstQuote)..<lastQuote]
            let fields = payload
                .split(separator: "~", omittingEmptySubsequences: false)
                .map(String.init)
            for stock in matchingStocks {
                if let quote = parse(fields: fields, stock: stock, requiresTimestamp: true) {
                    result[stock.id] = quote
                }
            }
        }
    }

    private func fields(in body: String) -> [String]? {
        guard let firstQuote = body.firstIndex(of: "\""),
              let lastQuote = body.lastIndex(of: "\""),
              firstQuote < lastQuote else { return nil }
        return body[body.index(after: firstQuote)..<lastQuote]
            .split(separator: "~", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func parse(
        fields: [String],
        stock: StockHolding,
        requiresTimestamp: Bool
    ) -> StockQuote? {
        let symbol = StockQuoteProviderSupport.symbol(for: stock)
        guard fields.count > 32,
              let latestPrice = StockQuoteProviderSupport.decimal(fields[3]),
              latestPrice > 0 else { return nil }
        let previousClose = StockQuoteProviderSupport.decimal(fields[4])
        let calculatedChange = StockQuoteProviderSupport.percentageChange(
            latestPrice: latestPrice,
            previousClose: previousClose
        )
        let suppliedChange = StockQuoteProviderSupport.decimal(fields[32]).map { $0 / 100 }

        let parsedDate: Date?
        switch stock.market {
        case .aShare:
            parsedDate = StockQuoteProviderSupport.compactQuoteDate(
                fields[30],
                timeZoneIdentifier: "Asia/Shanghai"
            )
        case .hongKong:
            parsedDate = StockQuoteProviderSupport.slashQuoteDate(
                fields[30],
                timeZoneIdentifier: "Asia/Hong_Kong"
            )
        case .unitedStates:
            parsedDate = StockQuoteProviderSupport.quoteDate(
                fields[30],
                timeZoneIdentifier: "America/New_York"
            )
        }
        if requiresTimestamp && parsedDate == nil { return nil }

        let name: String
        if stock.market == .unitedStates, fields.indices.contains(46), !fields[46].isEmpty {
            name = fields[46]
        } else {
            name = fields[1]
        }
        return StockQuote(
            symbol: stock.market == .aShare && !fields[2].isEmpty ? fields[2] : symbol,
            name: name,
            latestPrice: latestPrice,
            previousClose: previousClose,
            changePercent: requiresTimestamp ? calculatedChange : suppliedChange,
            updatedAt: parsedDate ?? Date(),
            source: "腾讯证券"
        )
    }
}
