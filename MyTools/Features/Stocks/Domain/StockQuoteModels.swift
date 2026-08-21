#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockQuote: Sendable {
    let symbol: String
    let name: String
    /// The provider's localized short name, when available. This is metadata
    /// for search/display and is intentionally not used as the formal quote name.
    let shortName: String?
    let latestPrice: Decimal
    let previousClose: Decimal?
    let changePercent: Decimal?
    let updatedAt: Date
    let source: String

    init(
        symbol: String,
        name: String,
        shortName: String? = nil,
        latestPrice: Decimal,
        previousClose: Decimal?,
        changePercent: Decimal?,
        updatedAt: Date,
        source: String
    ) {
        self.symbol = symbol
        self.name = name
        self.shortName = shortName
        self.latestPrice = latestPrice
        self.previousClose = previousClose
        self.changePercent = changePercent
        self.updatedAt = updatedAt
        self.source = source
    }
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

#endif
