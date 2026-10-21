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
        /// The main app can override the system appearance independently. The widget
        /// extension does not share that UserDefaults domain, so carry the choice in
        /// the activity state. Optional keeps activities created by older builds valid.
        let appearanceMode: String?
    }

    let title: String
}
#endif
