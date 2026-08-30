#if MYTOOLS_FEATURE_STOCKS
import Foundation

private enum StockStoreDefaultsKey {
    static let refreshDatesByMarket = "stock-last-refresh-dates-by-market-v1"
}

@MainActor
final class StockStore: ObservableObject, ModuleLifecycleParticipant {
    @Published private(set) var stocks: [StockHolding]
    @Published private(set) var priceAlerts: [StockPriceAlert]
    @Published private(set) var isRefreshingQuotes = false
    @Published private(set) var quoteRefreshError: String?
    @Published private(set) var lastRefreshAtByMarket: [StockMarket: Date] = [:]
    @Published private(set) var quoteErrors: [UUID: String] = [:]
    @Published private(set) var quoteSources: [UUID: String] = [:]
    @Published private(set) var isDataLoaded: Bool

    private let quoteService: any StockQuoteRefreshing
    private let alertNotifications: any AlertNotificationRouting
    private let refreshInvalidator: any StockRefreshInvalidating
    private let chartService: any StockChartServing
    private let defaults: UserDefaults
    private weak var moduleSettings: ToolModuleSettings?
    private weak var mutationNotifier: (any VaultMutationNotifying)?
    private weak var exchangeRateStore: ExchangeRateStore?

    init(
        stocks: [StockHolding] = [],
        priceAlerts: [StockPriceAlert] = [],
        isDataLoaded: Bool = false,
        quoteService: any StockQuoteRefreshing,
        alertNotifications: any AlertNotificationRouting,
        refreshInvalidator: any StockRefreshInvalidating,
        chartService: any StockChartServing = StockChartService.shared,
        defaults: UserDefaults,
        moduleSettings: ToolModuleSettings? = nil,
        exchangeRateStore: ExchangeRateStore? = nil
    ) {
        self.stocks = stocks
        self.priceAlerts = priceAlerts
        self.isDataLoaded = isDataLoaded
        self.quoteService = quoteService
        self.alertNotifications = alertNotifications
        self.refreshInvalidator = refreshInvalidator
        self.chartService = chartService
        self.defaults = defaults
        self.moduleSettings = moduleSettings
        self.exchangeRateStore = exchangeRateStore
        lastRefreshAtByMarket = Self.loadRefreshDates(from: defaults)
    }

    var openStockCount: Int {
        stocks.lazy.filter { $0.currentShares > 0 }.count
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(
        stocks: [StockHolding],
        priceAlerts: [StockPriceAlert],
        isDataLoaded: Bool
    ) {
        self.stocks = stocks
        self.priceAlerts = priceAlerts
        self.isDataLoaded = isDataLoaded
        quoteErrors = [:]
        quoteSources = [:]
        refreshInvalidator.refreshEligibilityChanged()
    }

    func moduleVisibilityChanged() {
        refreshInvalidator.refreshEligibilityChanged()
    }

    var observedModules: Set<ToolModule> { [.myStocks] }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        moduleVisibilityChanged()
    }

    func stockExists(
        market: StockMarket,
        symbol: String,
        excluding stockID: UUID? = nil
    ) -> Bool {
        StockPortfolioEditor.containsStock(
            in: stocks,
            market: market,
            symbol: symbol,
            excluding: stockID
        )
    }

    func upsertStock(_ stock: StockHolding) {
        let normalized = StockPortfolioEditor.normalizedHolding(stock)
        if let index = stocks.firstIndex(where: { $0.id == stock.id }) {
            stocks[index] = normalized
        } else {
            stocks.append(normalized)
        }
        didMutate()
    }

    @discardableResult
    func archiveStock(id: UUID, at date: Date = Date()) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == id }),
              let archived = StockPortfolioEditor.archiving(stocks[index], at: date) else {
            return false
        }
        stocks[index] = archived
        for alertIndex in priceAlerts.indices where priceAlerts[alertIndex].stockID == id {
            guard priceAlerts[alertIndex].isEnabled else { continue }
            priceAlerts[alertIndex].isEnabled = false
            priceAlerts[alertIndex].disabledByArchive = true
            alertNotifications.clearState(for: priceAlerts[alertIndex].id)
        }
        quoteErrors[id] = nil
        quoteSources[id] = nil
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
        return true
    }

    @discardableResult
    func restoreArchivedStock(id: UUID) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == id }),
              let restored = StockPortfolioEditor.restoring(stocks[index]) else { return false }
        stocks[index] = restored
        // Only re-enable alerts this store itself disabled when archiving.
        // An alert the user had already turned off before archiving must
        // stay off after restoring.
        for alertIndex in priceAlerts.indices where priceAlerts[alertIndex].stockID == id {
            guard priceAlerts[alertIndex].disabledByArchive else { continue }
            priceAlerts[alertIndex].isEnabled = true
            priceAlerts[alertIndex].disabledByArchive = false
            alertNotifications.clearState(for: priceAlerts[alertIndex].id)
        }
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
        return true
    }

    func deleteStocks(ids: Set<UUID>) {
        let removed = stocks.filter { ids.contains($0.id) }
        let result = StockPortfolioEditor.deletingStocks(
            ids: ids,
            from: stocks,
            alerts: priceAlerts
        )
        stocks = result.stocks
        priceAlerts = result.stockPriceAlerts
        result.removedAlertIDs.forEach(alertNotifications.clearState)
        for id in ids {
            quoteErrors[id] = nil
            quoteSources[id] = nil
        }
        // Remove the cached chart data for every deleted stock so that stale
        // series are not shown if the same symbol is re-added later.
        let chartService = chartService
        Task {
            for stock in removed {
                await chartService.clearCache(for: stock)
            }
        }
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
    }

    func upsertTransaction(_ transaction: StockTransaction, in stockID: UUID) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == stockID }),
              let candidate = StockPortfolioEditor.upserting(transaction, in: stocks[index]) else {
            return false
        }
        stocks[index] = candidate
        didMutate()
        return true
    }

    func deleteTransactions(ids: Set<UUID>, from stockID: UUID) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == stockID }),
              let candidate = StockPortfolioEditor.deletingTransactions(
                ids: ids,
                from: stocks[index]
              ) else { return false }
        stocks[index] = candidate
        didMutate()
        return true
    }

    func reorderTransactions(_ orderedIDs: [UUID], in stockID: UUID) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == stockID }),
              let candidate = StockPortfolioEditor.reorderingTransactions(
                orderedIDs,
                in: stocks[index]
              ) else { return false }
        stocks[index] = candidate
        didMutate()
        return true
    }

    func upsertDividend(_ dividend: StockDividend, in stockID: UUID) {
        guard let index = stocks.firstIndex(where: { $0.id == stockID }) else { return }
        stocks[index] = StockPortfolioEditor.upserting(dividend, in: stocks[index])
        didMutate()
    }

    func deleteDividends(ids: Set<UUID>, from stockID: UUID) {
        guard let index = stocks.firstIndex(where: { $0.id == stockID }) else { return }
        stocks[index] = StockPortfolioEditor.deletingDividends(ids: ids, from: stocks[index])
        didMutate()
    }

    func upsertPriceAlert(_ alert: StockPriceAlert) {
        guard let stockID = alert.stockID,
              stocks.contains(where: { $0.id == stockID }),
              alert.threshold > 0 else { return }
        if let index = priceAlerts.firstIndex(where: { $0.id == alert.id }) {
            priceAlerts[index] = alert
        } else {
            priceAlerts.append(alert)
        }
        alertNotifications.clearState(for: alert.id)
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
    }

    func deletePriceAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        priceAlerts.removeAll { alert in
            if ids.contains(alert.id) {
                alertNotifications.clearState(for: alert.id)
                return true
            }
            return false
        }
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
    }

    func clearNotificationState(for ids: Set<UUID>) {
        ids.forEach(alertNotifications.clearState)
    }

    func clearLocalRefreshState() {
        lastRefreshAtByMarket.removeAll()
        quoteErrors.removeAll()
        quoteSources.removeAll()
        quoteRefreshError = nil
        defaults.removeObject(forKey: StockStoreDefaultsKey.refreshDatesByMarket)
        refreshInvalidator.refreshEligibilityChanged()
    }

    func refreshQuotes(
        for market: StockMarket? = nil,
        forcedMarkets: Set<StockMarket> = [],
        allowClosedMissingData: Bool = true,
        forceRefresh: Bool = false
    ) async {
        guard isModuleVisible, !isRefreshingQuotes, !Task.isCancelled else { return }
        let effectiveForcedMarkets: Set<StockMarket>
        if forceRefresh {
            effectiveForcedMarkets = market.map { Set([$0]) }
                ?? Set(StockMarket.allCases)
        } else {
            effectiveForcedMarkets = forcedMarkets
        }
        let requestedStocks = StockQuoteRefreshReducer.stocksToRefresh(
            from: stocks,
            market: market,
            forcedMarkets: effectiveForcedMarkets,
            allowClosedMissingData: allowClosedMissingData,
            at: Date()
        )
        guard !requestedStocks.isEmpty else { return }
        isRefreshingQuotes = true
        quoteRefreshError = nil
        defer { isRefreshingQuotes = false }
        exchangeRateStore?.refreshIfNeeded()

        let quotes = await quoteService.fetchQuotes(for: requestedStocks)
        guard !Task.isCancelled, isModuleVisible else { return }
        let reduction = StockQuoteRefreshReducer.reduce(
            currentStocks: stocks,
            requestedStocks: requestedStocks,
            quotes: quotes
        )
        stocks = reduction.stocks
        quoteErrors = reduction.failures
        for id in reduction.failures.keys { quoteSources[id] = nil }
        for (id, source) in reduction.sources { quoteSources[id] = source }
        if !reduction.failures.isEmpty {
            let reason = reduction.failures.values.first ?? "行情服务暂时不可用"
            quoteRefreshError = "\(reduction.failures.count) 个标的暂时无法刷新：\(reason)"
            DiagnosticLogger.shared.log(
                .stockQuote,
                "行情刷新完成 success=\(reduction.successCount) failure=\(reduction.failures.count)",
                level: .warning
            )
        }
        if reduction.successCount > 0 {
            if reduction.didChangePersistedQuote { didMutateLocalOnly() }
            let refreshedAt = Date()
            for market in reduction.refreshedMarkets {
                lastRefreshAtByMarket[market] = refreshedAt
            }
            persistRefreshDates()
            evaluatePriceAlerts()
        }
    }

    func lastRefreshAt(for market: StockMarket?) -> Date? {
        if let market { return lastRefreshAtByMarket[market] }
        return lastRefreshAtByMarket.values.max()
    }

    func latestQuoteAt(for market: StockMarket) -> Date? {
        stocks
            .filter { $0.market == market && $0.hasConfiguredSymbol }
            .compactMap(\.lastQuoteAt)
            .max()
    }

    private var isModuleVisible: Bool {
        moduleSettings?.isVisible(.myStocks) ?? true
    }

    private func evaluatePriceAlerts() {
        guard isModuleVisible else { return }
        let matches = AppStoreAlertEvaluator.matchingStockAlertIDs(
            alerts: priceAlerts,
            stocks: stocks
        )
        let triggeredIDs = AppStoreAlertEvaluator.dispatchAlerts(
            alerts: priceAlerts,
            matchingIDs: matches,
            isEnabled: \.isEnabled,
            notifications: alertNotifications
        ) { alert in
            guard let stockID = alert.stockID,
                  let stock = stocks.first(where: { $0.id == stockID }),
                  let price = stock.latestPrice else { return nil }
            return (
                title: "股票价格提醒",
                body: "\(stock.displayName)（\(stock.symbol)）当前 \(StockValueFormatter.price(price, currencyCode: stock.market.currencyCode))，已\(alert.direction.title) \(StockValueFormatter.price(alert.threshold, currencyCode: stock.market.currencyCode))。"
            )
        }
        disablePriceAlerts(ids: triggeredIDs)
    }

    private func disablePriceAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var didChange = false
        for index in priceAlerts.indices where ids.contains(priceAlerts[index].id) {
            guard priceAlerts[index].isEnabled else { continue }
            priceAlerts[index].isEnabled = false
            alertNotifications.clearState(for: priceAlerts[index].id)
            didChange = true
        }
        if didChange {
            didMutate()
            refreshInvalidator.refreshEligibilityChanged()
        }
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
    }

    private func didMutateLocalOnly() {
        mutationNotifier?.moduleStoreDidMutateLocalOnly()
    }

    private static func loadRefreshDates(from defaults: UserDefaults) -> [StockMarket: Date] {
        guard let values = defaults.dictionary(
            forKey: StockStoreDefaultsKey.refreshDatesByMarket
        ) else { return [:] }
        return values.reduce(into: [:]) { result, entry in
            guard let market = StockMarket(rawValue: entry.key),
                  let date = entry.value as? Date else { return }
            result[market] = date
        }
    }

    private func persistRefreshDates() {
        let values = lastRefreshAtByMarket.reduce(into: [String: Date]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        defaults.set(values, forKey: StockStoreDefaultsKey.refreshDatesByMarket)
    }
}

#endif
