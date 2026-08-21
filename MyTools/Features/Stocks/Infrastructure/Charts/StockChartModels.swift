#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockChartRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case intraday
    case fiveDays
    case dayK
    case weekK
    case monthK
    case quarterK
    case yearK

    // Legacy values remain decodable for old cache metadata. They are not
    // exposed by the picker and are not used for new chart requests.
    case oneMonth
    case threeMonths
    case oneYear
    case fiveYears
    case tenYears
    case sinceInception

    static var allCases: [Self] {
        [.intraday, .fiveDays, .dayK, .weekK, .monthK, .quarterK, .yearK]
    }

    static var allPersistedCases: [Self] {
        allCases + [.oneMonth, .threeMonths, .oneYear, .fiveYears, .tenYears, .sinceInception]
    }

    var id: Self { self }

    var isMinuteRange: Bool {
        self == .intraday || self == .fiveDays
    }

    var isKLineRange: Bool {
        switch self {
        case .dayK, .weekK, .monthK, .quarterK, .yearK:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .intraday: return "分时"
        case .fiveDays: return "5 日"
        case .dayK: return "日K"
        case .weekK: return "周K"
        case .monthK: return "月K"
        case .quarterK: return "季K"
        case .yearK: return "年K"
        case .oneMonth: return "1 月"
        case .threeMonths: return "3 月"
        case .oneYear: return "1 年"
        case .fiveYears: return "5 年"
        case .tenYears: return "10 年"
        case .sinceInception: return "成立以来"
        }
    }

    var yahooRange: String {
        switch self {
        case .intraday: return "5d"
        case .fiveDays: return "1mo"
        case .dayK: return "3mo"
        case .weekK: return "2y"
        case .monthK: return "5y"
        case .quarterK: return "10y"
        case .yearK: return "max"
        case .oneMonth: return "1mo"
        case .threeMonths: return "3mo"
        case .oneYear: return "1y"
        case .fiveYears: return "5y"
        case .tenYears: return "10y"
        case .sinceInception: return "max"
        }
    }

    var yahooInterval: String {
        switch self {
        case .intraday: return "5m"
        case .fiveDays: return "15m"
        case .dayK: return "1d"
        case .weekK: return "1wk"
        case .monthK, .quarterK, .yearK: return "1mo"
        case .oneMonth, .threeMonths, .oneYear: return "1d"
        case .fiveYears, .tenYears: return "1wk"
        case .sinceInception: return "1mo"
        }
    }

    var eastmoneyInterval: String {
        switch self {
        case .intraday: return "5"
        case .fiveDays: return "15"
        case .dayK: return "101"
        case .weekK: return "102"
        case .monthK, .quarterK, .yearK: return "103"
        case .oneMonth, .threeMonths, .oneYear: return "101"
        case .fiveYears, .tenYears: return "102"
        case .sinceInception: return "103"
        }
    }

    var providerPointLimit: Int {
        switch self {
        case .intraday: return 1_500
        case .fiveDays: return 2_000
        // K-line tabs share the same complete historical source. The range
        // only controls the aggregation granularity after fetching.
        case .dayK, .weekK, .monthK, .quarterK, .yearK: return 20_000
        case .oneMonth: return 100
        case .threeMonths: return 150
        case .oneYear: return 330
        case .fiveYears: return 330
        case .tenYears: return 600
        case .sinceInception: return 1_500
        }
    }

    var dailyTechnicalPointLimit: Int {
        switch self {
        case .dayK, .weekK, .monthK, .quarterK, .yearK: return 20_000
        case .fiveYears: return 1_500
        case .tenYears: return 3_000
        case .sinceInception: return 20_000
        default: return 330
        }
    }

    var cacheLifetime: TimeInterval {
        switch self {
        case .intraday: return 20
        case .fiveDays: return 60
        case .dayK: return 10 * 60
        case .weekK: return 15 * 60
        case .monthK: return 30 * 60
        case .quarterK: return 60 * 60
        case .yearK: return 2 * 60 * 60
        case .oneMonth, .threeMonths, .oneYear: return 5 * 60
        case .fiveYears, .tenYears: return 15 * 60
        case .sinceInception: return 30 * 60
        }
    }
}

struct StockChartPoint: Identifiable, Codable, Equatable, Sendable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?

    var id: Date { date }
}

struct StockChartSessionSummary: Equatable, Sendable {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?
    let date: Date
}

struct StockChartSnapshot: Codable, Equatable, Sendable {
    let symbol: String
    let name: String
    let currencyCode: String
    let previousClose: Double?
    let points: [StockChartPoint]
    let preMarketPoints: [StockChartPoint]
    let postMarketPoints: [StockChartPoint]
    let indicatorPoints: [StockChartPoint]?
    /// Daily closes used for RSI on every range except the intraday chart.
    /// The visible series can remain minute, weekly, or monthly while RSI
    /// keeps the same trading-day definition. Minute overlays use
    /// `indicatorPoints` instead, with historical warm-up bars kept out of
    /// the visible chart.
    let dailyIndicatorPoints: [StockChartPoint]?
    let quoteUpdatedAt: Date
    let fetchedAt: Date
    let source: String
    let supportsCandlesticks: Bool

    init(
        symbol: String,
        name: String,
        currencyCode: String,
        previousClose: Double?,
        points: [StockChartPoint],
        preMarketPoints: [StockChartPoint] = [],
        postMarketPoints: [StockChartPoint] = [],
        indicatorPoints: [StockChartPoint]?,
        dailyIndicatorPoints: [StockChartPoint]? = nil,
        quoteUpdatedAt: Date,
        fetchedAt: Date,
        source: String,
        supportsCandlesticks: Bool
    ) {
        self.symbol = symbol
        self.name = name
        self.currencyCode = currencyCode
        self.previousClose = previousClose
        self.points = points
        self.preMarketPoints = preMarketPoints
        self.postMarketPoints = postMarketPoints
        self.indicatorPoints = indicatorPoints
        self.dailyIndicatorPoints = dailyIndicatorPoints
        self.quoteUpdatedAt = quoteUpdatedAt
        self.fetchedAt = fetchedAt
        self.source = source
        self.supportsCandlesticks = supportsCandlesticks
    }

    private enum CodingKeys: String, CodingKey {
        case symbol, name, currencyCode, previousClose, points, preMarketPoints, postMarketPoints
        case indicatorPoints, dailyIndicatorPoints, quoteUpdatedAt, fetchedAt, source
        case supportsCandlesticks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        name = try container.decode(String.self, forKey: .name)
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
        previousClose = try container.decodeIfPresent(Double.self, forKey: .previousClose)
        points = try container.decode([StockChartPoint].self, forKey: .points)
        preMarketPoints = try container.decodeIfPresent(
            [StockChartPoint].self,
            forKey: .preMarketPoints
        ) ?? []
        postMarketPoints = try container.decodeIfPresent(
            [StockChartPoint].self,
            forKey: .postMarketPoints
        ) ?? []
        indicatorPoints = try container.decodeIfPresent(
            [StockChartPoint].self,
            forKey: .indicatorPoints
        )
        dailyIndicatorPoints = try container.decodeIfPresent(
            [StockChartPoint].self,
            forKey: .dailyIndicatorPoints
        )
        quoteUpdatedAt = try container.decode(Date.self, forKey: .quoteUpdatedAt)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        source = try container.decode(String.self, forKey: .source)
        supportsCandlesticks = try container.decode(Bool.self, forKey: .supportsCandlesticks)
    }

    var latestPoint: StockChartPoint? { points.last }
}

enum StockChartError: LocalizedError, Sendable, Equatable {
    case invalidSymbol
    case noData
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSymbol:
            return "股票代码无效。"
        case .noData:
            return "该时段暂无可用行情。"
        case .serviceUnavailable:
            return "暂时无法取得走势图，请稍后重试。"
        }
    }
}

#endif
