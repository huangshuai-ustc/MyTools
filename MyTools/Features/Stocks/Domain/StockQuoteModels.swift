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

/// Latest extended-hours performance derived from the cached intraday chart.
/// These values are transient quote presentation data and are not persisted as
/// part of the stock holding itself.
///
/// The change amount travels with the percentage on purpose. Both are derived
/// from the same reference price inside `StockChartPresentation`, and that
/// reference is not the quote provider's `previousClose` — for pre-market it is
/// the specially resolved previous settled close. Re-deriving the amount at the
/// view layer from `previousClose` used to make the sign disagree with the
/// percentage (e.g. 「-$1.59（+0.45%）」).
struct StockExtendedHoursPerformance: Equatable, Sendable {
    let preMarketPrice: Decimal?
    let preMarketChange: Decimal?
    let preMarketPercent: Decimal?
    let postMarketPrice: Decimal?
    let postMarketChange: Decimal?
    let postMarketPercent: Decimal?
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
