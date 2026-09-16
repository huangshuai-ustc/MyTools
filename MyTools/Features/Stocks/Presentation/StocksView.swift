#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

private enum StockMarketFilter: Hashable, Identifiable {
    case all
    case market(StockMarket)

    static var marketCases: [Self] {
        StockMarket.topLevelOrder.map(Self.market)
    }

    init(_ market: StockMarket) {
        self = .market(market)
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case let .market(market): return market.title.replacingOccurrences(of: " ", with: "")
        }
    }

    var market: StockMarket? {
        switch self {
        case .all: return nil
        case let .market(market): return market
        }
    }

    func filtered(_ stocks: [StockHolding]) -> [StockHolding] {
        stocks.filter(includes)
    }

    func includes(_ stock: StockHolding) -> Bool {
        switch self {
        case .all: return true
        case let .market(market): return stock.market == market
        }
    }
}

struct StocksView: View {
    private struct WatchRoute: Hashable {
        let stockID: UUID
    }

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @State private var query = ""
    @State private var marketFilter: StockMarketFilter = .all
    @State private var didAutoSelectMarket = false
    @State private var didRefreshOnCurrentAppearance = false
    @State private var enteringRefreshTask: Task<Void, Never>?
    @State private var editingStock: StockHolding?
    @State private var watchRoute: WatchRoute?
    @State private var showsArchivedStocks = false
    @ObservedObject private var refreshCoordinator = StockRefreshCoordinator.shared

    private var configuredStocks: [StockHolding] {
        store.stocks.filter(\.hasConfiguredSymbol)
    }

    private var activeConfiguredStocks: [StockHolding] {
        configuredStocks.filter { !$0.isArchived }
    }

    private var availableMarketFilters: [StockMarketFilter] {
        let availableMarkets = Set(configuredStocks.map(\.market))
        let marketFilters = StockMarketFilter.marketCases.filter { filter in
            filter.market.map(availableMarkets.contains) ?? false
        }
        return [.all] + marketFilters
    }

    private var stocksInSelectedMarket: [StockHolding] {
        marketFilter.filtered(configuredStocks)
    }

    private var searchFilteredStocks: [StockHolding] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return stocksInSelectedMarket.filter { stock in
                searchTerm.isEmpty
                    || stock.symbol.localizedCaseInsensitiveContains(searchTerm)
                    || stock.displayName.localizedCaseInsensitiveContains(searchTerm)
            }
    }

    private var displayedStocks: [StockHolding] {
        alphabeticallySorted(searchFilteredStocks.filter { $0.currentShares > 0 })
    }

    private var noPositionStocks: [StockHolding] {
        alphabeticallySorted(searchFilteredStocks.filter {
            $0.currentShares <= 0 && !$0.isArchived
        })
    }

    private var archivedStocks: [StockHolding] {
        alphabeticallySorted(searchFilteredStocks.filter(\.isArchived))
    }

    private var summaryMarkets: [StockMarket] {
        if let market = marketFilter.market {
            return [market]
        }
        let relevantStocks = stocksInSelectedMarket.filter {
            $0.currentShares > 0 || $0.hasHistoricalActivity
        }
        return StockMarket.topLevelOrder.filter { market in
            relevantStocks.contains { $0.market == market }
        }
    }

    private var allocationSnapshot: StockAllocationSnapshot {
        let stocks = stocksInSelectedMarket
        let multipliers: [StockMarket: Decimal]
        if marketFilter.market == nil {
            var renminbiMultipliers: [StockMarket: Decimal] = [.aShare: 1]
            if let rate = exchangeRateStore.renminbiBuyingRates[.hkd] {
                renminbiMultipliers[.hongKong] = rate
            }
            if let rate = exchangeRateStore.renminbiBuyingRates[.usd] {
                renminbiMultipliers[.unitedStates] = rate
            }
            multipliers = renminbiMultipliers
        } else if let market = marketFilter.market {
            multipliers = [market: 1]
        } else {
            multipliers = [:]
        }
        return StockAllocationSnapshot(stocks: stocks, marketValueMultipliers: multipliers)
    }

    private var costAllocationSnapshot: StockCostAllocationSnapshot {
        var multipliers: [StockMarket: Decimal] = [:]
        if let market = marketFilter.market {
            multipliers[market] = 1
        } else {
            multipliers[.aShare] = 1
            multipliers[.hongKong] = exchangeRateStore.renminbiBuyingRates[.hkd]
            multipliers[.unitedStates] = exchangeRateStore.renminbiBuyingRates[.usd]
        }
        return StockCostAllocationSnapshot(
            stocks: stocksInSelectedMarket,
            costMultipliers: multipliers
        )
    }

    var body: some View {
        let allocations = allocationSnapshot
        let costAllocations = costAllocationSnapshot

        return List {
            Section {
                Picker("股票市场", selection: $marketFilter) {
                    ForEach(availableMarketFilters) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("组合总览") {
                RenminbiPortfolioSummaryRow(marketFilter: marketFilter)
                    .appListRowStyle()
                NavigationLink {
                    PortfolioValueHistoryView(market: marketFilter.market)
                        .environmentObject(store)
                        .environmentObject(exchangeRateStore)
                } label: {
                    Label("持仓总价值走势", systemImage: "chart.line.uptrend.xyaxis")
                }
                .appListRowStyle()
            }

            if !summaryMarkets.isEmpty {
                Section("市场概况") {
                    ForEach(summaryMarkets) { market in
                        StockMarketSummaryRow(
                            summary: StockPortfolioSummary(
                                market: market,
                                stocks: stocksInSelectedMarket
                            ),
                            allocation: allocations.marketShare(for: market),
                            showsAllocation: marketFilter.market == nil
                        )
                        .appListRowStyle()
                    }
                }
            }

            if displayedStocks.isEmpty && noPositionStocks.isEmpty && archivedStocks.isEmpty {
                Section("当前持仓（\(displayedStocks.count)）") {
                    ContentUnavailableView(
                        emptyStocksTitle,
                        systemImage: emptyStocksSystemImage
                    )
                }
            } else if !displayedStocks.isEmpty {
                Section("当前持仓（\(displayedStocks.count)）") {
                    stockLinks(displayedStocks, costAllocation: costAllocations)
                }
            }
            if !noPositionStocks.isEmpty {
                Section("看盘（\(noPositionStocks.count)）") {
                    stockLinks(noPositionStocks, costAllocation: costAllocations)
                }
            }
            if showsArchivedStocks && !archivedStocks.isEmpty {
                Section("历史股票（\(archivedStocks.count)）") {
                    stockLinks(archivedStocks, costAllocation: costAllocations)
                }
            }

            Section {
                if store.isRefreshingQuotes {
                    Label("正在刷新行情", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
                if let error = store.quoteRefreshError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                AppLabeledContentRow("最新数据获取时间") {
                    if let updatedAt = store.lastRefreshAt(for: marketFilter.market) {
                        Text(AppDateFormatter.dateTimeString(from: updatedAt))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("暂无")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("股票行情通过腾讯证券批量获取，并由新浪财经按时间校验；缺失时按市场使用交易所、东方财富、Nasdaq 或 Yahoo Finance。公开行情可能存在延迟，请以交易所和券商数据为准。")
            }
        }
        .appNavigationTitle(ToolModule.myStocks.title)
        .iOSLabeledBackButton("工具")
#if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索股票名称或代码")
#else
        .searchable(text: $query, prompt: "搜索股票名称或代码")
#endif
        .refreshable {
            await store.refreshQuotes(
                for: marketFilter.market,
                forceRefresh: true
            )
            await store.refreshExtendedHoursPerformance(forceRefresh: true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsArchivedStocks.toggle()
                } label: {
                    Image(systemName: showsArchivedStocks ? "archivebox.fill" : "archivebox")
                }
                .accessibilityLabel(showsArchivedStocks ? "隐藏历史股票" : "显示历史股票")
                .help(showsArchivedStocks ? "隐藏历史股票" : "显示历史股票")
                Button {
                    Task {
                        await store.refreshQuotes(
                            for: marketFilter.market,
                            forceRefresh: true
                        )
                        await store.refreshExtendedHoursPerformance(forceRefresh: true)
                    }
                } label: {
                    if store.isRefreshingQuotes {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshingQuotes)
                .accessibilityLabel("刷新股票行情")

                Button { editingStock = StockHolding() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加股票")
            }
        }
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
#endif
        .sheet(item: $editingStock) { stock in
            StockEditorView(stock: stock, isNew: true)
                .id(stock.id)
                .iOSLargeSheet()
        }
        .navigationDestination(item: $watchRoute) { route in
            StockWatchView(stockID: route.stockID)
        }
        .onChange(of: availableMarketFilters) { _, filters in
            if !filters.contains(marketFilter) {
                marketFilter = .all
            }
        }
        .onAppear {
            StockRefreshCoordinator.shared.setStocksPageVisible(true)
            autoSelectMarketIfNeeded()
            refreshWhenEntering()
        }
        .onChange(of: store.isDataLoaded) { _, isLoaded in
            if isLoaded {
                StockRefreshCoordinator.shared.setStocksPageVisible(true)
                autoSelectMarketIfNeeded()
                refreshWhenEntering()
            }
        }
        .onChange(of: refreshCoordinator.lastRefreshCompletedAt) { _, _ in
            Task { await store.refreshExtendedHoursPerformance() }
        }
        .onDisappear {
            StockRefreshCoordinator.shared.setStocksPageVisible(false)
            enteringRefreshTask?.cancel()
            enteringRefreshTask = nil
            didRefreshOnCurrentAppearance = false
        }
    }

    private func alphabeticallySorted(_ stocks: [StockHolding]) -> [StockHolding] {
        stocks.sorted { lhs, rhs in
            AppAlphabeticalSort.isOrderedBefore(
                lhs.displayName,
                rhs.displayName,
                lhsTieBreaker: "\(lhs.symbol)|\(lhs.id.uuidString)",
                rhsTieBreaker: "\(rhs.symbol)|\(rhs.id.uuidString)"
            )
        }
    }

    @ViewBuilder
    private func stockLink(
        _ stock: StockHolding,
        costAllocation: StockCostAllocationSnapshot
    ) -> some View {
        let link = NavigationLink {
            StockDetailView(stockID: stock.id)
        } label: {
            StockRow(
                stock: stock,
                costShare: costAllocation.holdingShare(for: stock.id),
                extendedHours: store.extendedHoursPerformance[stock.id]
            )
        }
        if stock.isArchived {
            link
                .modifier(StockCompactListRowStyle())
                .appSwipeActions(edge: .leading, style: AppSwipeActions.secondary) {
                    Button {
                        _ = store.restoreArchivedStock(id: stock.id)
                    } label: {
                        Label("恢复看盘", systemImage: "arrow.uturn.backward")
                    }
                }
                .appDeleteSwipeAction(isEnabled: true) {
                    store.deleteStocks(ids: [stock.id])
                }
        } else {
            link
                .modifier(StockCompactListRowStyle())
                .modifier(StockListRemovalActions(
                    stock: stock,
                    isEnabled: true,
                    onArchive: { _ = store.archiveStock(id: stock.id) },
                    onDelete: { store.deleteStocks(ids: [stock.id]) }
                ))
                .appSwipeActions(edge: .leading, style: AppSwipeActions.primary) {
                    Button {
                        watchRoute = WatchRoute(stockID: stock.id)
                    } label: {
                        Label("看盘", systemImage: "chart.xyaxis.line")
                    }
                }
        }
    }

    @ViewBuilder
    private func stockLinks(
        _ stocks: [StockHolding],
        costAllocation: StockCostAllocationSnapshot
    ) -> some View {
        ForEach(stocks) { stock in
            stockLink(stock, costAllocation: costAllocation)
        }
    }

    private var emptyStocksTitle: String {
        if activeConfiguredStocks.isEmpty {
            if !configuredStocks.isEmpty {
                return showsArchivedStocks ? "暂无可显示的股票" : "暂无股票"
            }
            return "暂无股票"
        }
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return searchTerm.isEmpty ? "暂无持仓股票" : "没有匹配的持仓股票"
    }

    private var emptyStocksSystemImage: String {
        configuredStocks.isEmpty ? "chart.line.uptrend.xyaxis" : "magnifyingglass"
    }

    private func autoSelectMarketIfNeeded() {
        guard store.isDataLoaded, !didAutoSelectMarket else { return }

        let availableMarkets = Set(
            configuredStocks
                .filter { $0.currentShares > 0 }
                .map(\.market)
        )
        let now = Date()
        // Priority: regular session > extended hours; within each tier: US > A-share > HK.
        let priorityOrder = StockMarket.displayOrder
        let regularMarket = priorityOrder.first {
            availableMarkets.contains($0) && StockMarketTradingCalendar.isOpen($0, at: now)
        }
        let extendedMarket = priorityOrder.first {
            availableMarkets.contains($0)
                && (StockMarketTradingCalendar.isPreMarketOpen($0, at: now)
                    || StockMarketTradingCalendar.isPostMarketOpen($0, at: now))
        }
        if let market = regularMarket ?? extendedMarket {
            marketFilter = StockMarketFilter(market)
        } else {
            marketFilter = .all
        }
        didAutoSelectMarket = true
    }

    private func refreshWhenEntering() {
        guard store.isDataLoaded, !didRefreshOnCurrentAppearance else { return }
        didRefreshOnCurrentAppearance = true
        enteringRefreshTask?.cancel()
        enteringRefreshTask = Task { @MainActor in
            await store.refreshQuotes(for: marketFilter.market)
            await store.refreshExtendedHoursPerformance()
            StockRefreshCoordinator.shared.triggerClosingRefreshIfNeeded()
        }
    }
}

private struct StockListRemovalActions: ViewModifier {
    let stock: StockHolding
    let isEnabled: Bool
    let onArchive: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if stock.currentShares <= 0 && stock.hasHistoricalActivity {
            // SwiftUI places the first trailing action closest to the row edge.
            // Keep delete first so full-swipe deletion remains unchanged, with
            // archive rendered immediately to its left.
            content.appSwipeActions(edge: .trailing, style: AppSwipeActions.delete) {
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
                .tint(AppSwipeActions.delete.tint)
                Button(action: onArchive) {
                    Label("存档", systemImage: "archivebox")
                }
                .tint(AppSwipeActions.secondary.tint)
            }
        } else {
            content.appDeleteSwipeAction(action: onDelete)
        }
    }
}

private struct RenminbiPortfolioSummaryRow: View {
    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let marketFilter: StockMarketFilter
    @State private var showingConversionInfo = false

    private var selectedStocks: [StockHolding] {
        store.stocks.filter {
            $0.hasPurchaseRecord && marketFilter.includes($0)
        }
    }

    private var convertedSummary: StockConvertedPortfolioSummary {
        StockConvertedPortfolioSummary(
            stocks: selectedStocks,
            multipliers: renminbiMultipliers
        )
    }

    private var renminbiMultipliers: [StockMarket: Decimal] {
        var result: [StockMarket: Decimal] = [.aShare: 1]
        if let rate = exchangeRateStore.renminbiBuyingRates[.hkd] {
            result[.hongKong] = rate
        }
        if let rate = exchangeRateStore.renminbiBuyingRates[.usd] {
            result[.unitedStates] = rate
        }
        return result
    }

    private var requiredForeignCurrencies: [CurrencyCode] {
        var result: [CurrencyCode] = []
        if marketFilter.market == .hongKong || selectedStocks.contains(where: { $0.market == .hongKong }) {
            result.append(.hkd)
        }
        if marketFilter.market == .unitedStates || selectedStocks.contains(where: { $0.market == .unitedStates }) {
            result.append(.usd)
        }
        return result
    }

    private var missingRateText: String {
        let missing = requiredForeignCurrencies.filter {
            exchangeRateStore.renminbiBuyingRates[$0] == nil
        }
        guard !missing.isEmpty else { return "外币买入价待同步" }
        return "中国银行\(missing.map(\.title).joined(separator: "、"))现汇买入价待同步"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack(spacing: 6) {
                Label("人民币总览", systemImage: "yensign.circle.fill")
                    .appFont(.headline)
                    .foregroundStyle(.blue)
                Button {
                    showingConversionInfo = true
                } label: {
                    Image(systemName: "exclamationmark.circle")
                }
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityLabel("人民币合计说明")
                .help("人民币合计说明")
                Spacer()
                Text("CNY")
                    .appFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if requiredForeignCurrencies.contains(where: { exchangeRateStore.renminbiBuyingRates[$0] == nil }) {
                Label(missingRateText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Grid(horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        overviewMetric("总资产", value: moneyText(convertedSummary.marketValue))
                        overviewMetric(
                            "今日盈亏",
                            value: moneyText(convertedSummary.todayProfitLoss),
                            color: profitLossColor(convertedSummary.todayProfitLoss)
                        )
                    }
                    GridRow {
                        overviewMetric(
                            "持仓盈亏",
                            value: moneyText(convertedSummary.holdingProfitLoss),
                            color: profitLossColor(convertedSummary.holdingProfitLoss)
                        )
                        overviewMetric(
                            "累计总收益",
                            value: moneyText(convertedSummary.totalProfitLoss),
                            color: profitLossColor(convertedSummary.totalProfitLoss)
                        )
                    }
                }
            }
        }
        .alert("人民币合计说明", isPresented: $showingConversionInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(conversionInfoText)
        }
    }

    private var conversionInfoText: String {
        if marketFilter.market == .aShare {
            return "A 股资产无需换汇。"
        }
        if requiredForeignCurrencies.isEmpty {
            return "当前没有需要折算的外币资产。"
        }

        var lines = requiredForeignCurrencies.compactMap { currency -> String? in
            guard let rate = exchangeRateStore.renminbiBuyingRates[currency] else { return nil }
            return "按中国银行\(currency.title)现汇买入价换算：1 \(currency.rawValue) = \(StockValueFormatter.exchangeRate(rate)) CNY"
        }
        let missingCurrencies = requiredForeignCurrencies.filter {
            exchangeRateStore.renminbiBuyingRates[$0] == nil
        }
        if !missingCurrencies.isEmpty {
            lines.append("\(missingCurrencies.map(\.title).joined(separator: "、"))牌价待同步。")
        }
        if let updatedAt = exchangeRateStore.updatedAt {
            lines.append("牌价时间：\(AppDateFormatter.dateTimeString(from: updatedAt))")
        }
        if let error = exchangeRateStore.error, !missingCurrencies.isEmpty {
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }

    private func overviewMetric(
        _ title: String,
        value: String,
        color: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func moneyText(_ value: Decimal?) -> String {
        guard let value else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(value, currencyCode: "CNY")
    }

    private func profitLossColor(_ value: Decimal?) -> Color {
        guard let value else { return .secondary }
        return aggregateProfitLossColor(value)
    }

    private func aggregateProfitLossColor(_ value: Decimal) -> Color {
        let market = marketFilter.market ?? .aShare
        return StockTrendColor.color(
            for: value,
            market: market,
            settings: stockAppearanceSettings
        )
    }
}

private struct StockMarketSummaryRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let summary: StockPortfolioSummary
    let allocation: Decimal?
    let showsAllocation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack {
                StockMarketBadge(market: summary.market)
                Text(positionSummaryText)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text(summary.market.currencyCode)
                    .appFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Grid(horizontalSpacing: 12) {
                GridRow {
                    summaryMetric("市值", value: marketValueText)
                    summaryMetric("今日盈亏", value: todayProfitLossText, color: todayProfitLossColor)
                    summaryMetric("持仓盈亏", value: profitLossText, color: profitLossColor)
                }
            }
        }
    }

    private var positionSummaryText: String {
        let positionCount = "\(summary.openPositionCount) 只持仓"
        guard showsAllocation else { return positionCount }
        let allocationText = allocation.map(StockValueFormatter.allocationPercent) ?? "待同步"
        return "\(positionCount) · 占比 \(allocationText)"
    }

    private var marketValueText: String {
        guard !summary.hasMissingQuotes else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(
            summary.knownMarketValue,
            currencyCode: summary.market.currencyCode
        )
    }

    private var todayProfitLossText: String {
        guard let value = summary.todayProfitLoss else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(value, currencyCode: summary.market.currencyCode)
    }

    private var todayProfitLossColor: Color {
        guard let value = summary.todayProfitLoss else { return .secondary }
        return StockTrendColor.color(
            for: value,
            market: summary.market,
            settings: stockAppearanceSettings
        )
    }

    private var profitLossText: String {
        guard let profitLoss = summary.profitLoss else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(
            profitLoss,
            currencyCode: summary.market.currencyCode
        )
    }

    private var profitLossColor: Color {
        guard let profitLoss = summary.profitLoss else { return .secondary }
        return StockTrendColor.color(
            for: profitLoss,
            market: summary.market,
            settings: stockAppearanceSettings
        )
    }

    private func summaryMetric(
        _ title: String,
        value: String,
        color: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct StockRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let stock: StockHolding
    let costShare: Decimal?
    let extendedHours: StockExtendedHoursPerformance?

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack(alignment: .top, spacing: 8) {
                StockMarketBadge(market: stock.market)
                Text(stock.displayName)
                    .appFont(.headline)
                    .lineLimit(1)
                Text(stock.symbol)
                    .appFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if stock.isArchived {
                    Text("已存档")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 4)
                quoteSummary
            }

            if stock.currentShares > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    primaryMetric
                    Spacer(minLength: 4)
                    dailyMetric
                }

                Text(positionSummaryText)
                    .appFont(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } else {
                Text(stock.isArchived ? "历史记录" : "暂无持仓")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quoteSummary: some View {
        let quote = activeQuote
        let color = quoteColor(quote.percent)
        let priceText = quote.price.map {
                StockValueFormatter.price($0, currencyCode: stock.market.currencyCode)
            } ?? "--"
        let percentText = quote.percent.map(StockValueFormatter.signedPercent) ?? "--"
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(quote.label) \(priceText)")
            Text("(\(percentText))")
        }
            .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(quote.label)，\(priceText)，\(percentText)")
    }

    private var activeQuote: (label: String, price: Decimal?, percent: Decimal?) {
        guard stock.market == .unitedStates else {
            return ("涨跌", stock.latestPrice, stock.changePercent)
        }
        switch StockMarketTradingCalendar.session(for: stock.market) {
        case .preMarket:
            return (
                "盘前",
                extendedHours?.preMarketPrice ?? stock.latestPrice,
                extendedHours?.preMarketPercent ?? stock.changePercent
            )
        case .postMarket:
            return (
                "盘后",
                extendedHours?.postMarketPrice ?? stock.latestPrice,
                extendedHours?.postMarketPercent ?? stock.changePercent
            )
        case .regular, .closed:
            return ("涨跌", stock.latestPrice, stock.changePercent)
        }
    }

    private func quoteColor(_ value: Decimal?) -> Color {
        guard let value else { return .secondary }
        return StockTrendColor.color(
            for: value,
            market: stock.market,
            settings: stockAppearanceSettings,
            neutral: .secondary
        )
    }

    private var primaryMetric: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(displayHoldingProfitLossText)
                .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
            Text("(\(displayHoldingProfitRateText))")
                .appFont(.caption.monospacedDigit())
        }
        .foregroundStyle(displayHoldingProfitColor)
        .lineLimit(1)
        .minimumScaleFactor(0.68)
        .accessibilityLabel("持仓盈亏，\(displayHoldingProfitLossText)，\(displayHoldingProfitRateText)")
        .accessibilityElement(children: .combine)
    }

    private var dailyMetric: some View {
        Text(todayProfitLossText)
            .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
            .foregroundStyle(todayProfitLossColor)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .accessibilityLabel("\(dailyMetricAccessibilityTitle)，\(todayProfitLossText)")
        .accessibilityElement(children: .combine)
    }

    private var displayPrice: Decimal? {
        activeQuote.price
    }

    private var displayMarketValue: Decimal? {
        guard let displayPrice else { return nil }
        return stock.currentShares * displayPrice
    }

    private var displayHoldingProfitLoss: Decimal? {
        guard let displayMarketValue else { return nil }
        return displayMarketValue - stock.holdingCost
    }

    private var displayHoldingProfitRate: Decimal? {
        guard stock.holdingCost > 0, let displayHoldingProfitLoss else { return nil }
        return displayHoldingProfitLoss / stock.holdingCost
    }

    private var marketValueText: String {
        guard let value = displayMarketValue else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var positionSummaryText: String {
        var text = "\(StockValueFormatter.integerQuantity(stock.currentShares))股·\(marketValueText)"
        if let costShare {
            text += "(\(StockValueFormatter.allocationPercent(costShare)))"
        }
        return text
    }

    private var todayProfitLossText: String {
        guard let value = stock.todayProfitLoss else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var todayProfitLossColor: Color {
        quoteColor(stock.todayProfitLoss)
    }

    private var isExtendedHoursQuote: Bool {
        guard stock.market == .unitedStates else { return false }
        switch StockMarketTradingCalendar.session(for: stock.market) {
        case .preMarket: return extendedHours?.preMarketPrice != nil
        case .postMarket: return extendedHours?.postMarketPrice != nil
        case .regular, .closed: return false
        }
    }

    private var dailyMetricAccessibilityTitle: String {
        guard stock.market == .unitedStates else { return "今日" }
        switch StockMarketTradingCalendar.session(for: stock.market) {
        case .preMarket: return "昨日"
        case .regular, .postMarket, .closed: return "今日"
        }
    }

    private var displayHoldingProfitLossText: String {
        guard let value = displayHoldingProfitLoss else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var displayHoldingProfitColor: Color {
        guard let value = displayHoldingProfitLoss else { return .secondary }
        return StockTrendColor.color(for: value, market: stock.market, settings: stockAppearanceSettings, neutral: .secondary)
    }

    private var displayHoldingProfitRateText: String {
        displayHoldingProfitRate.map(StockValueFormatter.signedPercent) ?? "--"
    }

}

private struct StockCompactListRowStyle: ViewModifier {
    @Environment(\.appFontScale) private var fontScale

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: AppListMetrics.rowVerticalInset(fontScale: fontScale) * 0.8,
                leading: AppListMetrics.rowHorizontalInset,
                bottom: AppListMetrics.rowVerticalInset(fontScale: fontScale) * 0.8,
                trailing: AppListMetrics.rowHorizontalInset
            ))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }
}

struct StockMarketBadge: View {
    let market: StockMarket

    static func color(for market: StockMarket) -> Color {
        switch market {
        case .aShare: return .orange
        case .hongKong: return .purple
        case .unitedStates: return .indigo
        }
    }

    private var color: Color { Self.color(for: market) }

    var body: some View {
        Text(shortTitle)
            .appFont(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
    }

    private var shortTitle: String {
        switch market {
        case .aShare: return "A"
        case .hongKong: return "港"
        case .unitedStates: return "美"
        }
    }
}

#endif
