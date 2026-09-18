#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

enum StockMarketFilter: Hashable, Identifiable {
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

/// Push route for the full chart page. A top-level type so both home pages can
/// hand it back to the container that owns the navigation destination.
struct StockWatchRoute: Hashable {
    let stockID: UUID
}

/// 股票投资首页容器。
///
/// 页面本身只做三件事：用系统 `TabView` 在持仓页与看盘页之间切换、组合筛选结果、
/// 持有全部导航与生命周期钩子。底部栏交给 `TabView` + `Tab` 由系统绘制，和「合伙
/// 记账」一致，这样 iOS 26 的 Liquid Glass 标签栏样式、macOS 的顶部标签样式都不用
/// 自己维护。`navigationTitle`、`.searchable`、`.refreshable`、`.toolbar`、
/// `.onAppear`/`.onDisappear` 和刷新协调器的可见性登记都挂在 `TabView` 之外，只生效
/// 一次，否则切页会打乱后台刷新状态。
struct StocksView: View {
    private struct ValueHistoryRoute: Hashable {
        let market: StockMarket?
    }

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @State private var query = ""
    @State private var marketFilter: StockMarketFilter = .all
    @State private var selectedPage: StocksHomePage = .positions
    @State private var didAutoSelectMarket = false
    @State private var didRefreshOnCurrentAppearance = false
    @State private var enteringRefreshTask: Task<Void, Never>?
    @State private var editingStock: StockHolding?
    @State private var watchRoute: StockWatchRoute?
    @State private var valueHistoryRoute: ValueHistoryRoute?
    @State private var showsArchivedStocks = false
    @ObservedObject private var refreshCoordinator = StockRefreshCoordinator.shared

    private var configuredStocks: [StockHolding] {
        store.stocks.filter(\.hasConfiguredSymbol)
    }

    private var activeConfiguredStocks: [StockHolding] {
        configuredStocks.filter { !$0.isArchived }
    }

    /// 只有一个市场有买入记录时不再给出「全部」——它与那个市场的结果完全一样，
    /// 白占一格分段控件。没有任何股票时仍留一个「全部」，分段控件不会空掉。
    private var availableMarketFilters: [StockMarketFilter] {
        let availableMarkets = Set(configuredStocks.map(\.market))
        let marketFilters = StockMarketFilter.marketCases.filter { filter in
            filter.market.map(availableMarkets.contains) ?? false
        }
        guard marketFilters.count > 1 else {
            return marketFilters.isEmpty ? [.all] : marketFilters
        }
        return [.all] + marketFilters
    }

    /// 一支持仓都没有时只剩看盘页，底部标签栏也就没必要出现。
    private var hasAnyPosition: Bool {
        configuredStocks.contains { $0.currentShares > 0 }
    }

    /// 只有持仓页存在时 `selectedPage` 才有意义；否则一律按看盘页解释，工具栏才不会
    /// 因为残留的选中值显示成持仓页的按钮。
    private var effectivePage: StocksHomePage {
        hasAnyPosition ? selectedPage : .watchlist
    }

    private var stocksInSelectedMarket: [StockHolding] {
        marketFilter.filtered(configuredStocks)
    }

    private var searchTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchFilteredStocks: [StockHolding] {
        let searchTerm = searchTerm
        return stocksInSelectedMarket.filter { stock in
            searchTerm.isEmpty
                || stock.symbol.localizedCaseInsensitiveContains(searchTerm)
                || stock.displayName.localizedCaseInsensitiveContains(searchTerm)
        }
    }

    private var displayedStocks: [StockHolding] {
        alphabeticallySorted(searchFilteredStocks.filter { $0.currentShares > 0 })
    }

    /// The watchlist covers every active stock, holdings included, so a position
    /// can be watched without leaving the positions table.
    private var watchlistStocks: [StockHolding] {
        alphabeticallySorted(searchFilteredStocks.filter { !$0.isArchived })
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
        return StockAllocationSnapshot(
            stocks: stocks,
            marketValueMultipliers: multipliers,
            extendedHours: store.extendedHoursPerformance
        )
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

    /// Recomputes the watchlist sparklines when the visible set or the last
    /// quote refresh changes. Cache-only, so this never causes a network call.
    private var sparklineRefreshKey: String {
        let ids = (watchlistStocks + archivedStocks)
            .map(\.id.uuidString)
            .joined(separator: ",")
        let latestRefresh = store.lastRefreshAtByMarket.values.max()
        return "\(ids)|\(latestRefresh?.timeIntervalSince1970 ?? 0)"
    }

    private var positionsPage: some View {
        StockPositionsPage(
            marketFilter: $marketFilter,
            watchRoute: $watchRoute,
            availableMarketFilters: availableMarketFilters,
            positions: displayedStocks,
            summaryStocks: stocksInSelectedMarket,
            summaryMarkets: summaryMarkets,
            allocations: allocationSnapshot,
            costAllocations: costAllocationSnapshot,
            searchTerm: searchTerm,
            hasConfiguredStocks: !activeConfiguredStocks.isEmpty
        )
    }

    private var watchlistPage: some View {
        StockWatchlistPage(
            marketFilter: $marketFilter,
            watchRoute: $watchRoute,
            availableMarketFilters: availableMarketFilters,
            watchlist: watchlistStocks,
            archivedStocks: archivedStocks,
            showsArchivedStocks: showsArchivedStocks,
            searchTerm: searchTerm,
            hasConfiguredStocks: !activeConfiguredStocks.isEmpty
        )
    }

    @ViewBuilder
    private var pages: some View {
        if hasAnyPosition {
            stockTabView
        } else {
            watchlistPage
        }
    }

    private var stockTabView: some View {
            TabView(selection: $selectedPage) {
                Tab(
                    StocksHomePage.positions.title,
                    systemImage: StocksHomePage.positions.systemImage,
                    value: StocksHomePage.positions
                ) {
                    positionsPage
                }
                Tab(
                    StocksHomePage.watchlist.title,
                    systemImage: StocksHomePage.watchlist.systemImage,
                    value: StocksHomePage.watchlist
                ) {
                    watchlistPage
                }
            }
    }


    var body: some View {
        pages

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
            // 分时缓存要一起强刷，否则迷你图和盘前盘后派生值仍是轮询时的旧数据。
            await store.refreshIntradayCharts(for: marketFilter.market)
            await store.refreshExtendedHoursPerformance()
            await store.refreshSparklines()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if effectivePage == .positions {
                    Button {
                        valueHistoryRoute = ValueHistoryRoute(market: marketFilter.market)
                    } label: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                    }
                    .accessibilityLabel("持仓总价值走势")
                    .help("持仓总价值走势")
                }
                if effectivePage == .watchlist {
                    Button {
                        showsArchivedStocks.toggle()
                    } label: {
                        Image(systemName: showsArchivedStocks ? "archivebox.fill" : "archivebox")
                    }
                    .accessibilityLabel(showsArchivedStocks ? "隐藏历史股票" : "显示历史股票")
                    .help(showsArchivedStocks ? "隐藏历史股票" : "显示历史股票")
                }
                Button {
                    Task {
                        await store.refreshQuotes(
                            for: marketFilter.market,
                            forceRefresh: true
                        )
                        await store.refreshIntradayCharts(for: marketFilter.market)
                        await store.refreshExtendedHoursPerformance()
                        await store.refreshSparklines()
                    }
                } label: {
                    if store.isRefreshingQuotes || store.isRefreshingCharts {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshingQuotes || store.isRefreshingCharts)
                .accessibilityLabel("刷新股票行情")

                Button { editingStock = StockHolding() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加股票")
            }
        }

#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
#endif
        .sheet(item: $editingStock) { stock in
            StockEditorView(stock: stock, isNew: true)
                .id(stock.id)
                .iOSLargeSheet()
        }
        .navigationDestination(item: $watchRoute) { route in
            StockWatchView(stockID: route.stockID)
        }
        .navigationDestination(item: $valueHistoryRoute) { route in
            PortfolioValueHistoryView(market: route.market)
                .environmentObject(store)
                .environmentObject(exchangeRateStore)
        }
        .task(id: sparklineRefreshKey) {
            await store.refreshSparklines()
        }
        .onChange(of: availableMarketFilters) { _, filters in
            if !filters.contains(marketFilter) {
                marketFilter = filters.first ?? .all
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
            Task {
                await store.refreshExtendedHoursPerformance()
                await store.refreshSparklines()
            }
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
            // 只有一个市场时 `availableMarketFilters` 里没有「全部」，回落到首项。
            marketFilter = availableMarketFilters.first ?? .all
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
            await store.refreshSparklines()
            StockRefreshCoordinator.shared.triggerClosingRefreshIfNeeded()
        }
    }
}

/// 列表行的移除操作。规则只有一条：**有交易或分红记录的股票不给删除**——
/// 删除会连同全部交易与分红一起抹掉，没有撤销，还会同步到 iCloud。
///
/// 清仓后想让它从看盘列表里消失，用「存档」：记录留在 App 里，只是不再盯盘。
/// 仍在持仓的股票连存档也不给（`StockPortfolioEditor.archiving` 只接受零持仓，
/// 否则总览的合计里会藏着一只列表上看不到的股票），先去详情页卖出。
///
/// 真要彻底删掉一只误录的股票，先在详情页删净它的交易与分红，记录清空后
/// 删除操作会自己回来。
struct StockListRemovalActions: ViewModifier {
    let stock: StockHolding
    let isEnabled: Bool
    let onArchive: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if stock.hasHistoricalActivity {
            if stock.currentShares <= 0 {
                content.appSwipeActions(edge: .trailing, style: AppSwipeActions.secondary) {
                    Button(action: onArchive) {
                        Label("存档", systemImage: "archivebox")
                    }
                    .tint(AppSwipeActions.secondary.tint)
                }
            } else {
                content
            }
        } else {
            content.appDeleteSwipeAction(action: onDelete)
        }
    }
}

struct StockCompactListRowStyle: ViewModifier {
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

struct StockMarketSessionLabel: View {
    let market: StockMarket
    var usesCompactIcon = false

    var body: some View {
        let presentation = presentation
        HStack(spacing: usesCompactIcon ? 3 : 4) {
            Image(systemName: presentation.icon)
                .font(usesCompactIcon ? .caption2 : .caption)
            Text(presentation.title)
                .appFont(.caption)
        }
        .foregroundStyle(presentation.color)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var presentation: (title: String, icon: String, color: Color) {
        switch StockMarketTradingCalendar.session(for: market) {
        case .regular:
            return ("交易中", "circle.fill", .green)
        case .preMarket where market.supportsExtendedHoursChart:
            return ("盘前交易", "clock.arrow.2.circlepath", .orange)
        case .postMarket where market.supportsExtendedHoursChart:
            return ("盘后交易", "clock", .blue)
        case .preMarket, .postMarket, .closed:
            return ("已休市", "moon.zzz", .secondary)
        }
    }
}

#endif
