#if MYTOOLS_FEATURE_STOCKS
import Foundation

private enum StockStoreDefaultsKey {
    static let refreshDatesByMarket = "stock-last-refresh-dates-by-market-v1"
}

@MainActor
final class StockStore: ObservableObject, ModuleLifecycleParticipant {
    @Published private(set) var stocks: [StockHolding]
    @Published private(set) var priceAlerts: [StockPriceAlert]
    @Published private(set) var returnAlerts: [StockReturnAlert]
    @Published private(set) var isRefreshingQuotes = false
    /// 分时缓存强刷中。与报价刷新分开记录：报价先回来，迷你图和盘前盘后派生值要等
    /// 分时请求结束，刷新指示器必须覆盖到那时候。
    @Published private(set) var isRefreshingCharts = false
    @Published private(set) var quoteRefreshError: String?
    @Published private(set) var lastRefreshAtByMarket: [StockMarket: Date] = [:]
    @Published private(set) var quoteErrors: [UUID: String] = [:]
    @Published private(set) var quoteSources: [UUID: String] = [:]
    @Published private(set) var extendedHoursPerformance: [UUID: StockExtendedHoursPerformance] = [:]
    @Published private(set) var intradaySparklines: [UUID: StockSparklineSeries] = [:]
    @Published private(set) var isDataLoaded: Bool

    private let quoteService: any StockQuoteRefreshing
    private let alertNotifications: any AlertNotificationRouting
    private let refreshInvalidator: any StockRefreshInvalidating
    private let chartService: any StockChartServing
    private let defaults: UserDefaults
    private var isModuleVisible: Bool
    private weak var mutationNotifier: (any VaultMutationNotifying)?
    private weak var exchangeRateStore: ExchangeRateStore?

    init(
        stocks: [StockHolding] = [],
        priceAlerts: [StockPriceAlert] = [],
        returnAlerts: [StockReturnAlert] = [],
        isDataLoaded: Bool = false,
        quoteService: any StockQuoteRefreshing,
        alertNotifications: any AlertNotificationRouting,
        refreshInvalidator: any StockRefreshInvalidating,
        chartService: any StockChartServing = StockChartService.shared,
        defaults: UserDefaults,
        isModuleVisible: Bool = true,
        exchangeRateStore: ExchangeRateStore? = nil
    ) {
        self.stocks = stocks
        self.priceAlerts = priceAlerts
        self.returnAlerts = returnAlerts
        self.isDataLoaded = isDataLoaded
        extendedHoursPerformance = [:]
        self.quoteService = quoteService
        self.alertNotifications = alertNotifications
        self.refreshInvalidator = refreshInvalidator
        self.chartService = chartService
        self.defaults = defaults
        self.isModuleVisible = isModuleVisible
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
        returnAlerts: [StockReturnAlert],
        isDataLoaded: Bool
    ) {
        self.stocks = stocks
        self.priceAlerts = priceAlerts
        self.returnAlerts = returnAlerts
        self.isDataLoaded = isDataLoaded
        quoteErrors = [:]
        quoteSources = [:]
        DiagnosticLogger.shared.log(.data, "股票数据替换 stocks=\(stocks.count) alerts=\(priceAlerts.count) returnAlerts=\(returnAlerts.count)")
        refreshInvalidator.refreshEligibilityChanged()
    }

    var observedModules: Set<ToolModule> { [.myStocks] }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        isModuleVisible = isEnabled
        refreshInvalidator.refreshEligibilityChanged()
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
        let isUpdate = stocks.contains { $0.id == stock.id }
        if let index = stocks.firstIndex(where: { $0.id == stock.id }) {
            stocks[index] = normalized
        } else {
            stocks.append(normalized)
        }
        DiagnosticLogger.shared.log(.data, "股票持仓\(isUpdate ? "更新" : "新增") id=\(stock.id)")
        didMutate()
    }

    @discardableResult
    func archiveStock(id: UUID, at date: Date = Date()) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == id }),
              let archived = StockPortfolioEditor.archiving(stocks[index], at: date) else {
            DiagnosticLogger.shared.log(.data, "股票归档失败（未找到或无法归档） id=\(id)", level: .warning)
            return false
        }
        stocks[index] = archived
        for alertIndex in priceAlerts.indices where priceAlerts[alertIndex].stockID == id {
            guard priceAlerts[alertIndex].isEnabled else { continue }
            priceAlerts[alertIndex].isEnabled = false
            priceAlerts[alertIndex].disabledByArchive = true
            alertNotifications.clearState(for: priceAlerts[alertIndex].id)
        }
        for alertIndex in returnAlerts.indices where returnAlerts[alertIndex].stockID == id {
            guard returnAlerts[alertIndex].isEnabled else { continue }
            returnAlerts[alertIndex].isEnabled = false
            returnAlerts[alertIndex].disabledByArchive = true
            alertNotifications.clearState(for: returnAlerts[alertIndex].id)
        }
        quoteErrors[id] = nil
        quoteSources[id] = nil
        DiagnosticLogger.shared.log(.data, "股票归档 id=\(id)")
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
        return true
    }

    @discardableResult
    func restoreArchivedStock(id: UUID) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == id }),
              let restored = StockPortfolioEditor.restoring(stocks[index]) else {
            DiagnosticLogger.shared.log(.data, "股票恢复归档失败（未找到或非归档状态） id=\(id)", level: .warning)
            return false
        }
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
        for alertIndex in returnAlerts.indices where returnAlerts[alertIndex].stockID == id {
            guard returnAlerts[alertIndex].disabledByArchive else { continue }
            returnAlerts[alertIndex].isEnabled = true
            returnAlerts[alertIndex].disabledByArchive = false
            alertNotifications.clearState(for: returnAlerts[alertIndex].id)
        }
        DiagnosticLogger.shared.log(.data, "股票恢复归档 id=\(id)")
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
        return true
    }

    func deleteStocks(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = stocks.filter { ids.contains($0.id) }
        let result = StockPortfolioEditor.deletingStocks(
            ids: ids,
            from: stocks,
            alerts: priceAlerts,
            returnAlerts: returnAlerts
        )
        stocks = result.stocks
        priceAlerts = result.stockPriceAlerts
        returnAlerts = result.stockReturnAlerts
        result.removedAlertIDs.forEach(alertNotifications.clearState)
        result.removedReturnAlertIDs.forEach(alertNotifications.clearState)
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
        DiagnosticLogger.shared.log(.data, "股票持仓删除 count=\(ids.count)")
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
    }

    func upsertTransaction(_ transaction: StockTransaction, in stockID: UUID) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == stockID }),
              let candidate = StockPortfolioEditor.upserting(transaction, in: stocks[index]) else {
            DiagnosticLogger.shared.log(.data, "股票交易记录保存失败（未找到持仓） stockID=\(stockID)", level: .warning)
            return false
        }
        stocks[index] = candidate
        DiagnosticLogger.shared.log(.data, "股票交易记录保存 transactionID=\(transaction.id) stockID=\(stockID)")
        didMutate()
        return true
    }

    func deleteTransactions(ids: Set<UUID>, from stockID: UUID) -> Bool {
        guard let index = stocks.firstIndex(where: { $0.id == stockID }),
              let candidate = StockPortfolioEditor.deletingTransactions(
                ids: ids,
                from: stocks[index]
              ) else {
            DiagnosticLogger.shared.log(.data, "股票交易记录删除失败（未找到持仓） stockID=\(stockID)", level: .warning)
            return false
        }
        stocks[index] = candidate
        DiagnosticLogger.shared.log(.data, "股票交易记录删除 count=\(ids.count) stockID=\(stockID)")
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
              alert.threshold > 0 else {
            DiagnosticLogger.shared.log(.data, "股票价格提醒保存被拒绝（无效参数） id=\(alert.id)", level: .warning)
            return
        }
        let isUpdate = priceAlerts.contains { $0.id == alert.id }
        if let index = priceAlerts.firstIndex(where: { $0.id == alert.id }) {
            priceAlerts[index] = alert
        } else {
            priceAlerts.append(alert)
        }
        alertNotifications.clearState(for: alert.id)
        DiagnosticLogger.shared.log(.data, "股票价格提醒\(isUpdate ? "更新" : "新增") id=\(alert.id)")
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
        DiagnosticLogger.shared.log(.data, "股票价格提醒删除 count=\(ids.count)")
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
    }

    func upsertReturnAlert(_ alert: StockReturnAlert) {
        guard let stockID = alert.stockID,
              stocks.contains(where: { $0.id == stockID }),
              alert.threshold != 0 else {
            DiagnosticLogger.shared.log(.data, "股票盈亏提醒保存被拒绝（无效参数） id=\(alert.id)", level: .warning)
            return
        }
        let isUpdate = returnAlerts.contains { $0.id == alert.id }
        if let index = returnAlerts.firstIndex(where: { $0.id == alert.id }) {
            returnAlerts[index] = alert
        } else {
            returnAlerts.append(alert)
        }
        alertNotifications.clearState(for: alert.id)
        DiagnosticLogger.shared.log(.data, "股票盈亏提醒\(isUpdate ? "更新" : "新增") id=\(alert.id)")
        didMutate()
        refreshInvalidator.refreshEligibilityChanged()
    }

    func deleteReturnAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        returnAlerts.removeAll { alert in
            if ids.contains(alert.id) {
                alertNotifications.clearState(for: alert.id)
                return true
            }
            return false
        }
        DiagnosticLogger.shared.log(.data, "股票盈亏提醒删除 count=\(ids.count)")
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
            DiagnosticLogger.shared.log(
                .stockQuote,
                "行情刷新成功 success=\(reduction.successCount) markets=\(reduction.refreshedMarkets.map { $0.rawValue }.sorted().joined(separator: ","))"
            )
            evaluatePriceAlerts()
        }
    }

    /// Loads the cached intraday snapshots used by the stocks list to show
    /// US pre-market and post-market performance. The chart service owns the
    /// provider/cache boundary; the list only receives derived percentages.
    func refreshExtendedHoursPerformance(forceRefresh: Bool = false) async {
        let candidates = stocks.filter {
            $0.market == .unitedStates && $0.hasConfiguredSymbol && !$0.isArchived
        }
        guard !candidates.isEmpty else {
            extendedHoursPerformance = [:]
            return
        }

        var values: [UUID: StockExtendedHoursPerformance] = [:]
        // 同一个 `now` 决定盘前/盘后数据是否属于当前交易日，与迷你图的时段判定同源。
        let now = Date()
        await withTaskGroup(of: (UUID, StockExtendedHoursPerformance?).self) { group in
            for stock in candidates {
                group.addTask { [chartService] in
                    let snapshot: StockChartSnapshot?
                    if forceRefresh {
                        snapshot = try? await chartService.fetchChart(
                            for: stock,
                            range: .intraday,
                            forceRefresh: true
                        )
                    } else {
                        snapshot = await chartService.cachedChart(
                            for: stock,
                            range: .intraday
                        )
                    }
                    guard let snapshot else { return (stock.id, nil) }
                    let preMarket = StockChartPresentation.preMarketPerformance(
                        snapshot: snapshot,
                        market: stock.market,
                        at: now
                    )
                    let postMarket = StockChartPresentation.postMarketPerformance(
                        snapshot: snapshot,
                        market: stock.market,
                        at: now
                    )
                    // 金额与百分比都取自同一个 `(change, percent)`，不在展示层用
                    // 报价源的 `previousClose` 另算一次，否则两者基准不同会出现
                    // 「金额跌、百分比涨」这种自相矛盾的行。
                    //
                    // 价格也跟着这对派生值走：`preMarketPerformance` 只在数据属于当前
                    // 交易日时返回值，价格若单独放行，行内就会显示昨天的盘前价而涨跌
                    // 为「--」，迷你图又按当天判定画另一段。
                    let preMarketPrice = preMarket == nil
                        ? nil
                        : snapshot.preMarketPoints.max(by: { $0.date < $1.date })
                    let postMarketPrice = postMarket == nil
                        ? nil
                        : snapshot.postMarketPoints.max(by: { $0.date < $1.date })
                    return (
                        stock.id,
                        StockExtendedHoursPerformance(
                            preMarketPrice: preMarketPrice.map {
                                Self.decimalQuoteValue($0.close)
                            },
                            preMarketChange: preMarket.map { Self.decimalQuoteValue($0.change) },
                            preMarketPercent: preMarket.map { Self.decimalQuoteValue($0.percent) },
                            postMarketPrice: postMarketPrice.map {
                                Self.decimalQuoteValue($0.close)
                            },
                            postMarketChange: postMarket.map { Self.decimalQuoteValue($0.change) },
                            postMarketPercent: postMarket.map { Self.decimalQuoteValue($0.percent) }
                        )
                    )
                }
            }
            for await (id, performance) in group {
                if let performance { values[id] = performance }
            }
        }
        guard !Task.isCancelled else { return }
        extendedHoursPerformance = values
    }

    nonisolated private static func decimalQuoteValue(_ value: Double) -> Decimal {
        Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
            ?? Decimal(value)
    }

    /// 强制刷新分时缓存，供手动刷新按钮和下拉刷新使用。
    ///
    /// 报价接口只更新价格，而迷你图、盘前盘后派生值和持仓总价值走势都读分时缓存。
    /// 在此之前手动刷新只会通过 `refreshExtendedHoursPerformance(forceRefresh:)`
    /// 顺带刷新美股的分时，A 股和港股的迷你图只能等 `StockRefreshCoordinator` 的
    /// 60 秒轮询，按钮对图形形同无效。
    func refreshIntradayCharts(for market: StockMarket? = nil) async {
        let candidates = stocks.filter { stock in
            guard stock.hasConfiguredSymbol, !stock.isArchived else { return false }
            guard let market else { return true }
            return stock.market == market
        }
        guard !candidates.isEmpty, !isRefreshingCharts else { return }
        isRefreshingCharts = true
        defer { isRefreshingCharts = false }
        await withTaskGroup(of: Void.self) { group in
            for stock in candidates {
                group.addTask { [chartService] in
                    // 缺数据的标的不该打断其余标的，错误由行情状态区和诊断日志体现。
                    _ = try? await chartService.fetchChart(
                        for: stock,
                        range: .intraday,
                        forceRefresh: true
                    )
                }
            }
        }
    }

    /// Derives the inline watchlist sparklines from whatever intraday snapshots
    /// are already on disk. Unlike `refreshExtendedHoursPerformance` this covers
    /// every market, and it never calls `fetchChart` — a missing cache entry just
    /// leaves the row without a sparkline until a real chart visit populates it.
    ///
    /// That cache is not stale while the page is open: `StockRefreshCoordinator`
    /// already refetches the intraday chart every polling cycle during a regular
    /// session and during US pre/post-market, so re-deriving after each cycle is
    /// what keeps the sparklines live.
    func refreshSparklines() async {
        let candidates = stocks.filter { $0.hasConfiguredSymbol && !$0.isArchived }
        guard !candidates.isEmpty else {
            intradaySparklines = [:]
            return
        }

        var values: [UUID: StockSparklineSeries] = [:]
        // 一次刷新内所有行共用同一个 `now`，与 `refreshExtendedHoursPerformance` 的当天
        // 校验用的是同一套判定。
        let now = Date()
        await withTaskGroup(of: (UUID, StockSparklineSeries?).self) { group in
            for stock in candidates {
                group.addTask { [chartService] in
                    guard let snapshot = await chartService.cachedChart(
                        for: stock,
                        range: .intraday
                    ) else { return (stock.id, nil) }
                    // 同一个 `now` 同时决定画哪一段和横坐标域，避免跨时段瞬间两者不
                    // 一致，也避免把上一交易日的盘前当成今天的。虚线零轴不在这里定，
                    // 由行内报价给出，虚线和色块因此不可能对不上。
                    let selection = StockSparklineSeries.resolve(
                        regular: snapshot.points,
                        preMarket: snapshot.preMarketPoints,
                        postMarket: snapshot.postMarketPoints,
                        market: stock.market,
                        at: now
                    )
                    return (
                        stock.id,
                        StockSparklineSeries.make(
                            points: selection.points,
                            domain: selection.domain
                        )
                    )
                }
            }
            for await (id, series) in group {
                if let series { values[id] = series }
            }
        }
        guard !Task.isCancelled else { return }
        intradaySparklines = values
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
        if !triggeredIDs.isEmpty {
            DiagnosticLogger.shared.log(.notification, "股票价格提醒触发 count=\(triggeredIDs.count)")
        }
        disablePriceAlerts(ids: triggeredIDs)
        evaluateReturnAlerts()
    }

    private func evaluateReturnAlerts() {
        guard isModuleVisible else { return }
        let matches = AppStoreAlertEvaluator.matchingStockReturnAlertIDs(
            alerts: returnAlerts,
            stocks: stocks
        )
        let triggeredIDs = AppStoreAlertEvaluator.dispatchAlerts(
            alerts: returnAlerts,
            matchingIDs: matches,
            isEnabled: \.isEnabled,
            notifications: alertNotifications
        ) { alert in
            guard let stockID = alert.stockID,
                  let stock = stocks.first(where: { $0.id == stockID }),
                  let rate = stock.holdingProfitRate else { return nil }
            let actualPct = StockValueFormatter.signedPercent(rate)
            let thresholdPct = StockValueFormatter.signedPercent(alert.threshold)
            let direction = alert.threshold >= 0 ? "盈利" : "亏损"
            return (
                title: "持仓盈亏提醒",
                body: "\(stock.displayName)（\(stock.symbol)）\(direction)已达 \(actualPct)，触发阈值 \(thresholdPct)。"
            )
        }
        if !triggeredIDs.isEmpty {
            DiagnosticLogger.shared.log(.notification, "股票盈亏提醒触发 count=\(triggeredIDs.count)")
        }
        disableReturnAlerts(ids: triggeredIDs)
    }

    private func disableReturnAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var didChange = false
        for index in returnAlerts.indices where ids.contains(returnAlerts[index].id) {
            guard returnAlerts[index].isEnabled else { continue }
            returnAlerts[index].isEnabled = false
            alertNotifications.clearState(for: returnAlerts[index].id)
            didChange = true
        }
        if didChange {
            didMutate()
            refreshInvalidator.refreshEligibilityChanged()
        }
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
