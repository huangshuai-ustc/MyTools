#if MYTOOLS_FEATURE_STOCKS
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

/// A symbol candidate returned by a market search. The result is deliberately
/// separate from `StockQuote`: searching must not create or mutate a holding.
enum StockSearchSource: String, Equatable, Sendable {
    case tencent
    case yahoo
}

struct StockSearchResult: Identifiable, Equatable, Sendable {
    let market: StockMarket
    let symbol: String
    let name: String
    let alias: String?
    let detail: String?
    let source: StockSearchSource

    init(
        market: StockMarket,
        symbol: String,
        name: String,
        alias: String? = nil,
        detail: String? = nil,
        source: StockSearchSource = .tencent
    ) {
        self.market = market
        self.symbol = symbol
        self.name = name
        self.alias = alias
        self.detail = detail
        self.source = source
    }

    var id: String { "\(market.rawValue):\(symbol)" }

    static func == (lhs: StockSearchResult, rhs: StockSearchResult) -> Bool {
        // Provider metadata can be enriched on a later request. A candidate
        // still represents the same security when its market and normalized
        // symbol match, so optional display fields must not change identity.
        lhs.market == rhs.market && lhs.symbol == rhs.symbol
    }
}

protocol StockSearching: Sendable {
    func search(query: String, market: StockMarket, limit: Int) async -> [StockSearchResult]
}

struct StockSearchService: StockSearching, Sendable {
    private let httpClient: any StockQuoteHTTPClient

    init(httpClient: any StockQuoteHTTPClient = URLSessionStockQuoteHTTPClient()) {
        self.httpClient = httpClient
    }

    func search(query: String, market: StockMarket, limit: Int = 12) async -> [StockSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        async let tencent = searchTencent(query: query, market: market)
        async let yahoo = searchYahoo(query: query, market: market)
        let (tencentResults, yahooResults) = await (tencent, yahoo)
        let correctedTencentResults = await correctTencentNames(tencentResults, query: query)
        let providerMatchNames = tencentResults.reduce(into: [String: String]()) { names, result in
            names[result.id] = result.name
        }
        let providerOrder = (correctedTencentResults + yahooResults).enumerated().reduce(into: [String: Int]()) { order, item in
            order[item.element.id] = min(order[item.element.id] ?? item.offset, item.offset)
        }
        return rank(
            correctedTencentResults + yahooResults,
            query: query,
            market: market,
            limit: limit,
            providerOrder: providerOrder,
            providerMatchNames: providerMatchNames
        )
    }

    private func correctTencentNames(
        _ results: [StockSearchResult],
        query: String
    ) async -> [StockSearchResult] {
        guard !results.isEmpty else { return results }

        let stocks = results.map {
            StockHolding(market: $0.market, symbol: $0.symbol)
        }
        let quotes = await TencentStockQuoteProvider(httpClient: httpClient)
            .fetchQuotes(for: stocks)
        let namesBySymbol: [String: String] = quotes.values.reduce(into: [:]) { names, quote in
            let name = quote.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            names[quote.symbol] = name
        }
        let aliasesBySymbol: [String: String] = quotes.values.reduce(into: [:]) { aliases, quote in
            guard let alias = quote.shortName,
                  !alias.isEmpty,
                  alias.localizedCaseInsensitiveCompare(quote.name) != .orderedSame else { return }
            aliases[quote.symbol] = alias
        }
        return results.map { result in
            let name = namesBySymbol[result.symbol] ?? result.name
            let alias = result.alias
                ?? aliasesBySymbol[result.symbol]
                ?? StockSearchProviderSupport.providerChineseAlias(result.name, excluding: query)
            return StockSearchResult(
                market: result.market,
                symbol: result.symbol,
                name: name,
                alias: alias,
                detail: result.detail,
                source: result.source
            )
        }
    }

    private func searchTencent(query: String, market: StockMarket) async -> [StockSearchResult] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "smartbox.gtimg.cn"
        components.path = "/s3/"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "t", value: "all")
        ]
        guard let url = components.url else { return [] }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 8,
            headers: [
                "User-Agent": "Mozilla/5.0",
                "Accept": "text/plain, */*"
            ]
        )
        guard let data = try? await httpClient.data(for: request),
              let response = StockQuoteProviderSupport.decodeSinaResponse(data) else {
            return []
        }
        return StockSearchProviderSupport.parseTencent(response)
            .filter { $0.market == market }
    }

    private func searchYahoo(query: String, market: StockMarket) async -> [StockSearchResult] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.path = "/v1/finance/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "20"),
            URLQueryItem(name: "newsCount", value: "0")
        ]
        guard let url = components.url else { return [] }
        let request = StockQuoteProviderSupport.request(
            url: url,
            timeout: 8,
            headers: ["User-Agent": "Mozilla/5.0", "Accept": "application/json"]
        )
        guard let data = try? await httpClient.data(for: request),
              let envelope = try? JSONDecoder().decode(
                StockSearchProviderSupport.YahooSearchEnvelope.self,
                from: data
              ) else { return [] }

        return (envelope.quotes ?? []).compactMap { quote in
            StockSearchProviderSupport.yahooResult(quote, market: market)
        }
    }

    private func rank(
        _ values: [StockSearchResult],
        query: String,
        market: StockMarket,
        limit: Int,
        providerOrder: [String: Int],
        providerMatchNames: [String: String]
    ) -> [StockSearchResult] {
        var unique: [String: StockSearchResult] = [:]
        for value in values where value.market == market {
            let key = value.id
            if let existing = unique[key] {
                unique[key] = merged(existing, value)
            } else {
                unique[key] = value
            }
        }
        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return unique.values.sorted { lhs, rhs in
            let lhsScore = score(lhs, query: foldedQuery)
            let rhsScore = score(rhs, query: foldedQuery)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsNameScore = providerNameScore(lhs, query: foldedQuery, providerMatchNames: providerMatchNames)
            let rhsNameScore = providerNameScore(rhs, query: foldedQuery, providerMatchNames: providerMatchNames)
            if lhsNameScore != rhsNameScore { return lhsNameScore > rhsNameScore }
            let lhsTypeScore = securityTypeScore(lhs)
            let rhsTypeScore = securityTypeScore(rhs)
            if lhsTypeScore != rhsTypeScore { return lhsTypeScore > rhsTypeScore }
            let lhsVenue = listingVenueScore(lhs)
            let rhsVenue = listingVenueScore(rhs)
            if lhsVenue != rhsVenue { return lhsVenue > rhsVenue }
            let lhsPopularity = popularityScore(lhs)
            let rhsPopularity = popularityScore(rhs)
            if lhsPopularity != rhsPopularity { return lhsPopularity > rhsPopularity }
            let lhsOrder = providerOrder[lhs.id] ?? .max
            let rhsOrder = providerOrder[rhs.id] ?? .max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            if lhs.symbol.count != rhs.symbol.count {
                return lhs.symbol.count < rhs.symbol.count
            }
            return lhs.symbol.localizedStandardCompare(rhs.symbol) == .orderedAscending
        }.prefix(limit).map { $0 }
    }

    private func merged(
        _ lhs: StockSearchResult,
        _ rhs: StockSearchResult
    ) -> StockSearchResult {
        let preferred: StockSearchResult
        let secondary: StockSearchResult
        if prefers(rhs, over: lhs) {
            preferred = rhs
            secondary = lhs
        } else {
            preferred = lhs
            secondary = rhs
        }
        let alias: String?
        if preferred.detail?.localizedCaseInsensitiveContains("ETF") == true {
            alias = nil
        } else {
            alias = [preferred.alias, secondary.alias, secondary.name]
                .compactMap { $0 }
                .first {
                    $0.localizedCaseInsensitiveCompare(preferred.name) != .orderedSame
                        && !($0.isEmpty)
                }
        }
        return StockSearchResult(
            market: preferred.market,
            symbol: preferred.symbol,
            name: preferred.name,
            alias: alias,
            detail: preferred.detail ?? secondary.detail,
            source: preferred.source
        )
    }

    private func prefers(
        _ candidate: StockSearchResult,
        over current: StockSearchResult
    ) -> Bool {
        guard candidate.source != current.source else { return false }
        if candidate.market == .unitedStates {
            return candidate.source == .yahoo
        }
        return candidate.source == .tencent
    }

    private func score(_ result: StockSearchResult, query: String) -> Int {
        let symbol = result.symbol.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let name = result.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let alias = result.alias?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if symbol == query { return 110 }
        if name == query { return 105 }
        if alias == query { return 98 }
        if symbol.hasPrefix(query) { return 80 }
        if alias?.hasPrefix(query) == true { return 78 }
        if name.hasPrefix(query) { return 75 }
        if symbol.contains(query) { return 60 }
        if alias?.contains(query) == true { return 58 }
        if name.contains(query) { return 55 }
        return 0
    }

    private func providerNameScore(
        _ result: StockSearchResult,
        query: String,
        providerMatchNames: [String: String]
    ) -> Int {
        guard containsChinese(query),
              let rawName = providerMatchNames[result.id] else {
            return 0
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.localizedCaseInsensitiveContains(query) else {
            return 0
        }

        // Keep the semantic match tier stable first; venue and popularity
        // resolve candidates within the same tier like broker search pages do.
        if name == query { return 400 }
        if name.hasSuffix(query) { return 330 }
        if name.hasPrefix(query) { return 300 }
        return 250
    }

    private func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private func isETF(_ result: StockSearchResult) -> Bool {
        result.detail?.localizedCaseInsensitiveContains("ETF") == true
            || result.name.localizedCaseInsensitiveContains("ETF")
    }

    private func securityTypeScore(_ result: StockSearchResult) -> Int {
        if isETF(result) { return 0 }
        if result.detail?.localizedCaseInsensitiveContains("普通股") == true {
            return 2
        }
        return 1
    }

    private func listingVenueScore(_ result: StockSearchResult) -> Int {
        guard result.market == .unitedStates else { return 3 }
        let detail = result.detail?.uppercased() ?? ""
        if detail.contains("OTC") || detail.contains("PINK") || detail.contains("OTCQ") {
            return 0
        }
        if detail.contains("NYSE") || detail.contains("NASDAQ") || detail.contains("AMEX") {
            return 3
        }
        return 1
    }

    /// A small stable baseline for common symbols. Provider ranking remains the
    /// primary signal; this only resolves ties between similarly named listings.
    private func popularityScore(_ result: StockSearchResult) -> Int {
        let symbol = result.symbol.uppercased()
        switch result.market {
        case .unitedStates:
            return [
                "AAPL": 100, "MSFT": 99, "NVDA": 98, "AMZN": 97, "GOOGL": 96,
                "META": 95, "TSLA": 94, "BRK.B": 93, "JPM": 92, "V": 91,
                "WMT": 90, "AVGO": 89, "AMD": 88, "NFLX": 87, "XOM": 86,
                "JNJ": 85, "KO": 84, "PDD": 83, "PEP": 82,
                // Main Coca-Cola company and listed bottlers outrank OTC
                // listings when the Chinese name is otherwise equivalent.
                "COKE": 81, "CCEP": 80, "KOF": 79, "CCOJY": 10
            ][symbol, default: 0]
        case .hongKong:
            return [
                "00700": 100, "09988": 99, "03690": 98, "09999": 97,
                "00941": 96, "00005": 95
            ][symbol, default: 0]
        case .aShare:
            return [
                "600519": 100, "000858": 99, "601318": 98, "600036": 97,
                "000001": 96, "600900": 95, "601398": 94, "601939": 93
            ][symbol, default: 0]
        }
    }
}

enum StockSearchProviderSupport {
    struct YahooSearchEnvelope: Decodable {
        let quotes: [YahooQuote]?
    }

    struct YahooQuote: Decodable {
        let symbol: String?
        let shortname: String?
        let longname: String?
        let quoteType: String?
        let exchange: String?
        let exchDisp: String?
        let typeDisp: String?

        init(
            symbol: String?,
            shortname: String?,
            longname: String?,
            quoteType: String?,
            exchange: String? = nil,
            exchDisp: String? = nil,
            typeDisp: String? = nil
        ) {
            self.symbol = symbol
            self.shortname = shortname
            self.longname = longname
            self.quoteType = quoteType
            self.exchange = exchange
            self.exchDisp = exchDisp
            self.typeDisp = typeDisp
        }
    }

    static func parseTencent(_ response: String) -> [StockSearchResult] {
        guard let payload = quotedPayload(in: response) else {
            return []
        }
        var results: [StockSearchResult] = []

        for rawRecord in payload.split(whereSeparator: { $0 == "^" || $0 == ";" }) {
            let fields = rawRecord.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  let market = market(for: fields[0]),
                  let symbol = normalizedSymbol(fields[1], market: market) else {
                continue
            }
            let name = decodeEscapedText(fields[2])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let detail = fields.count > 4
                ? tencentDetail(fields[4], rawSymbol: fields[1], market: market)
                : nil
            results.append(
                StockSearchResult(
                    market: market,
                    symbol: symbol,
                    name: name,
                    detail: detail
                )
            )
        }

        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }

    static func normalizedTencentSymbol(_ rawSymbol: String, market: StockMarket) -> String? {
        normalizedSymbol(rawSymbol, market: market)
    }

    static func providerChineseAlias(_ value: String, excluding query: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              containsChinese(candidate),
              candidate.localizedCaseInsensitiveCompare(query) != .orderedSame else {
            return nil
        }
        return candidate
    }

    static func yahooResult(_ quote: YahooQuote, market: StockMarket) -> StockSearchResult? {
        guard let rawSymbol = quote.symbol?.trimmingCharacters(in: .whitespacesAndNewlines),
              let name = (quote.longname ?? quote.shortname)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSymbol.isEmpty, !name.isEmpty else { return nil }
        let symbol: String
        switch market {
        case .aShare:
            let uppercased = rawSymbol.uppercased()
            guard uppercased.hasSuffix(".SS") || uppercased.hasSuffix(".SZ") else { return nil }
            let candidate = String(rawSymbol.dropLast(3))
            guard candidate.count == 6, candidate.allSatisfy(\.isNumber) else { return nil }
            symbol = candidate
        case .hongKong:
            guard rawSymbol.uppercased().hasSuffix(".HK") else { return nil }
            symbol = String(rawSymbol.dropLast(3)).leftPadding(toLength: 5, with: "0")
        case .unitedStates:
            guard quote.quoteType == nil || quote.quoteType == "EQUITY" || quote.quoteType == "ETF" else {
                return nil
            }
            guard isSupportedUSListing(exchange: quote.exchange, symbol: rawSymbol) else {
                return nil
            }
            symbol = rawSymbol.uppercased()
        }
        let detail: String?
        if market == .unitedStates {
            let type = quote.quoteType == "ETF" ? "ETF" : quote.quoteType == "EQUITY" ? "普通股" : quote.typeDisp
            let exchange = quote.exchDisp ?? quote.exchange
            let value = [exchange, type].compactMap { $0 }.joined(separator: " · ")
            detail = value.isEmpty ? nil : value
        } else {
            detail = nil
        }
        let alias: String?
        if market == .unitedStates,
           let shortname = quote.shortname?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shortname.isEmpty,
           shortname.localizedCaseInsensitiveCompare(name) != .orderedSame {
            alias = shortname
        } else {
            alias = nil
        }
        return StockSearchResult(
            market: market,
            symbol: symbol,
            name: name,
            alias: alias,
            detail: detail,
            source: .yahoo
        )
    }

    private static func market(for rawMarket: String) -> StockMarket? {
        switch rawMarket.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sh", "sz", "bj": return .aShare
        case "hk": return .hongKong
        case "us": return .unitedStates
        default: return nil
        }
    }

    private static func tencentDetail(
        _ rawAssetType: String,
        rawSymbol: String,
        market: StockMarket
    ) -> String? {
        var labels: [String] = []
        if market == .unitedStates,
           let dot = rawSymbol.lastIndex(of: ".") {
            let suffix = rawSymbol[rawSymbol.index(after: dot)...].uppercased()
            let venue: String?
            switch suffix {
            case "N": venue = "NYSE"
            case "OQ", "O": venue = "NASDAQ"
            case "A", "AM": venue = "AMEX"
            case "PS", "PK", "PNK", "Q": venue = "OTC"
            default: venue = nil
            }
            if let venue { labels.append(venue) }
        }
        let assetType = rawAssetType.uppercased()
        if assetType.contains("ETF") {
            labels.append("ETF")
        } else if assetType.contains("GP") || assetType.contains("STOCK") {
            labels.append("普通股")
        }
        if assetType.contains("KCB") { labels.append("科创板") }
        if assetType.contains("CYB") { labels.append("创业板") }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }

    private static func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private static func isSupportedUSListing(exchange: String?, symbol: String) -> Bool {
        guard let exchange else {
            return !symbol.contains(".")
        }
        let supported = [
            "ASE", "BTF", "BTS", "BTT", "CBO", "NMS", "NCM", "NGM", "NMQ",
            "NAS", "NYQ", "NYS", "PCX", "PNK", "OQB", "OQX"
        ]
        return supported.contains(exchange.uppercased())
    }

    private static func normalizedSymbol(_ rawSymbol: String, market: StockMarket) -> String? {
        let value = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch market {
        case .aShare:
            guard value.count == 6, value.allSatisfy(\.isNumber) else { return nil }
            return value
        case .hongKong:
            guard value.allSatisfy(\.isNumber), (1...5).contains(value.count) else { return nil }
            return value.leftPadding(toLength: 5, with: "0")
        case .unitedStates:
            let uppercased = value.uppercased()
            guard uppercased.unicodeScalars.allSatisfy({ $0.value < 128 }),
                  uppercased.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
                return nil
            }
            let suffixes = ["N", "OQ", "PS", "NYSE", "NASDAQ", "AM", "AMEX"]
            if let dot = uppercased.lastIndex(of: ".") {
                let suffix = String(uppercased[uppercased.index(after: dot)...])
                if suffixes.contains(suffix) {
                    return String(uppercased[..<dot])
                }
                let foreignSuffixes = [
                    "L", "F", "MU", "DE", "PA", "MI", "ST", "SW", "TO", "V",
                    "AX", "HK", "SS", "SZ", "T", "SA", "AS", "CO", "OL", "HE",
                    "IR", "VI", "BE", "LS"
                ]
                if foreignSuffixes.contains(suffix) {
                    return nil
                }
            }
            return uppercased
        }
    }

    private static func quotedPayload(in response: String) -> String? {
        guard let start = response.firstIndex(of: "\"") else { return nil }
        var index = response.index(after: start)
        var escaped = false
        while index < response.endIndex {
            let character = response[index]
            if character == "\"" && !escaped {
                let raw = String(response[response.index(after: start)..<index])
                return decodeEscapedText(raw)
            }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            index = response.index(after: index)
        }
        return nil
    }

    private static func decodeEscapedText(_ value: String) -> String {
        let wrapped = "\"\(value)\""
        guard let data = wrapped.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return value
        }
        return decoded
    }
}

private extension String {
    func leftPadding(toLength length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
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

#endif
