import Foundation

enum StockChartRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case intraday
    case fiveDays
    case oneMonth
    case threeMonths
    case oneYear
    case fiveYears
    case tenYears
    case sinceInception

    var id: Self { self }

    var title: String {
        switch self {
        case .intraday: return "分时"
        case .fiveDays: return "5 日"
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
        case .oneMonth, .threeMonths, .oneYear: return "1d"
        case .fiveYears, .tenYears: return "1wk"
        case .sinceInception: return "1mo"
        }
    }

    var eastmoneyInterval: String {
        switch self {
        case .intraday: return "5"
        case .fiveDays: return "15"
        case .oneMonth, .threeMonths, .oneYear: return "101"
        case .fiveYears, .tenYears: return "102"
        case .sinceInception: return "103"
        }
    }

    var providerPointLimit: Int {
        switch self {
        case .intraday, .fiveDays: return 500
        case .oneMonth: return 100
        case .threeMonths: return 150
        case .oneYear: return 330
        case .fiveYears: return 330
        case .tenYears: return 600
        case .sinceInception: return 1_500
        }
    }

    var cacheLifetime: TimeInterval {
        switch self {
        case .intraday: return 20
        case .fiveDays: return 60
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

struct StockChartSnapshot: Codable, Equatable, Sendable {
    let symbol: String
    let name: String
    let currencyCode: String
    let previousClose: Double?
    let points: [StockChartPoint]
    let indicatorPoints: [StockChartPoint]?
    let quoteUpdatedAt: Date
    let fetchedAt: Date
    let source: String
    let supportsCandlesticks: Bool

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
