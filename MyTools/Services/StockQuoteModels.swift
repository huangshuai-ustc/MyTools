import Foundation

struct StockQuote: Sendable {
    let symbol: String
    let name: String
    let latestPrice: Decimal
    let previousClose: Decimal?
    let changePercent: Decimal?
    let updatedAt: Date
    let source: String
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
