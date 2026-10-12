#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockChartRequest: Sendable {
    let stock: StockHolding
    let symbol: String
    let range: StockChartRange

    init(
        stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) {
        self.stock = stock
        self.symbol = symbol
        self.range = range
    }
}

protocol StockChartProvider: Sendable {
    func fetchChart(for request: StockChartRequest) async throws -> StockChartSnapshot
}

struct StockChartProviders: Sendable {
    let tencent: any StockChartProvider
    let eastmoney: any StockChartProvider
    let yahoo: any StockChartProvider
    let nasdaq: any StockChartProvider

    init(
        tencent: any StockChartProvider = TencentStockChartProvider(),
        eastmoney: any StockChartProvider = EastmoneyStockChartProvider(),
        yahoo: any StockChartProvider = YahooStockChartProvider(),
        nasdaq: any StockChartProvider = NasdaqStockChartProvider()
    ) {
        self.tencent = tencent
        self.eastmoney = eastmoney
        self.yahoo = yahoo
        self.nasdaq = nasdaq
    }
}

protocol StockChartHTTPClient: Sendable {
    func data(for url: URL, referer: String) async throws -> Data
}

struct URLSessionStockChartHTTPClient: StockChartHTTPClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func data(for url: URL, referer: String) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 8
        )
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let started = Date()
        do {
            let (data, response) = try await Self.session.data(for: request)
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=http host=\(url.host ?? "unknown") status=\(status) bytes=\(data.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            guard (200..<300).contains(status) else { throw StockChartError.serviceUnavailable }
            return data
        } catch {
            if Task.isCancelled { throw CancellationError() }
            DiagnosticLogger.shared.log(.stockQuote,
                "图表阶段=http失败 host=\(url.host ?? "unknown") error=\(DiagnosticLogger.errorCode(error)) ms=\(Int(Date().timeIntervalSince(started) * 1000))", level: .warning)
            throw error
        }
    }
}

#endif
