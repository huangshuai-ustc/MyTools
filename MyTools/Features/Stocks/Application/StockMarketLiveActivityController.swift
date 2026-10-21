#if MYTOOLS_FEATURE_STOCKS && os(iOS)
import ActivityKit
import Foundation

@MainActor
final class StockMarketLiveActivityController {
    static let shared = StockMarketLiveActivityController()

    private init() {}

    private var resolvedAppearance: String?

#if DEBUG && targetEnvironment(simulator)
    func previewActivity(appearance: String) async {
        let state = StockMarketActivityAttributes.ContentState(markets: [
            .init(id: "US", name: "美股", currencyCode: "USD", marketValue: "$11,591.32",
                  todayChange: "+$466.86", todayChangeRate: "+4.20%", trend: 1)
        ], updatedAt: Date(), appearanceMode: appearance)
        do {
            _ = try Activity.request(attributes: StockMarketActivityAttributes(title: "开市市场总览"),
                                     content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        } catch { DiagnosticLogger.logError(.stockQuote, operation: "实时活动预览", error: error) }
    }
#endif

    func updateAppearance(_ mode: String) async {
        resolvedAppearance = mode
        for activity in Activity<StockMarketActivityAttributes>.activities {
            let old = activity.content
            let state = StockMarketActivityAttributes.ContentState(
                markets: old.state.markets,
                updatedAt: old.state.updatedAt,
                appearanceMode: mode
            )
            await activity.update(ActivityContent(
                state: state, staleDate: old.staleDate, relevanceScore: old.relevanceScore
            ))
        }
    }

    func shouldKeepUpdated(
        store: StockStore,
        isEnabled: Bool = true,
        at now: Date = Date()
    ) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              store.isDataLoaded,
              isEnabled,
              Self.isEnabledByUser else { return false }
        return openMarketsWithPositions(in: store, at: now).isEmpty == false
    }

    private static var isEnabledByUser: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppStorageKey.stockMarketLiveActivityEnabled) != nil else {
            return true
        }
        return defaults.bool(forKey: AppStorageKey.stockMarketLiveActivityEnabled)
    }

    func reconcile(
        store: StockStore,
        isEnabled: Bool = true,
        at now: Date = Date()
    ) async {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-stock-activity") { return }
#endif
        let existing = Activity<StockMarketActivityAttributes>.activities
        guard shouldKeepUpdated(store: store, isEnabled: isEnabled, at: now) else {
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let state = makeContentState(store: store, at: now)
        guard state.markets.isEmpty == false else { return }
        let content = ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(90),
            relevanceScore: 80
        )

        if let current = existing.first {
            await current.update(content)
            for duplicate in existing.dropFirst() {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        do {
            _ = try Activity.request(
                attributes: StockMarketActivityAttributes(title: "开市市场总览"),
                content: content,
                pushType: nil
            )
            DiagnosticLogger.shared.log(.lifecycle, "股票市场实时活动启动")
        } catch {
            DiagnosticLogger.logError(.stockQuote, operation: "启动股票市场实时活动失败", error: error)
        }
    }

    private func openMarketsWithPositions(in store: StockStore, at now: Date) -> [StockMarket] {
        let performances = store.performances(for: store.stocks)
        return StockMarket.topLevelOrder.filter { market in
            StockMarketTradingCalendar.session(for: market, at: now) != .closed
                && store.stocks.contains {
                    $0.market == market && (performances[$0.id]?.shares ?? 0) > 0
                }
        }
    }

    private func makeContentState(store: StockStore, at now: Date) -> StockMarketActivityAttributes.ContentState {
        let stocks = store.stocks
        let performances = store.performances(for: stocks)
        let rows = openMarketsWithPositions(in: store, at: now).map { market in
            let summary = StockPortfolioSummary(
                market: market,
                stocks: stocks,
                extendedHours: store.extendedHoursPerformance,
                at: now,
                performances: performances
            )
            let previousValue = summary.todayProfitLoss.map { summary.knownMarketValue - $0 }
            let changeRate: Decimal? = summary.todayProfitLoss.flatMap { change -> Decimal? in
                guard let previousValue, previousValue > 0 else { return nil }
                return change / previousValue
            }
            let change = summary.todayProfitLoss
            return StockMarketActivityAttributes.MarketOverview(
                id: market.rawValue,
                name: market.title,
                currencyCode: market.currencyCode,
                marketValue: summary.hasMissingQuotes
                    ? "--"
                    : StockValueFormatter.money(summary.knownMarketValue, currencyCode: market.currencyCode),
                todayChange: change.map {
                    StockValueFormatter.signedMoney($0, currencyCode: market.currencyCode)
                } ?? "--",
                todayChangeRate: changeRate.map(StockValueFormatter.signedPercent) ?? "--",
                trend: change.map { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) } ?? 0
            )
        }
        return .init(
            markets: rows,
            updatedAt: now,
            appearanceMode: resolvedAppearance
                ?? UserDefaults.standard.string(forKey: AppStorageKey.appearanceMode)
        )
    }
}
#elseif MYTOOLS_FEATURE_STOCKS
import Foundation

@MainActor
final class StockMarketLiveActivityController {
    static let shared = StockMarketLiveActivityController()
    private init() {}

    func shouldKeepUpdated(
        store: StockStore,
        isEnabled: Bool = true,
        at now: Date = Date()
    ) -> Bool {
        false
    }

    func reconcile(
        store: StockStore,
        isEnabled: Bool = true,
        at now: Date = Date()
    ) async {}
}
#endif
