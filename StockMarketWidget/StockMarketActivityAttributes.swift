#if os(iOS)
import ActivityKit
import Foundation

/// App and widget-extension contract for the stock market overview Live Activity.
struct StockMarketActivityAttributes: ActivityAttributes {
    struct MarketOverview: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        let currencyCode: String
        let marketValue: String
        let todayChange: String
        let todayChangeRate: String
        let trend: Int
    }

    struct ContentState: Codable, Hashable, Sendable {
        let markets: [MarketOverview]
        let updatedAt: Date
    }

    let title: String
}
#endif
