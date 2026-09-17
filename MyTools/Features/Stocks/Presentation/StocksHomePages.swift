#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

/// The two pages reachable from the stocks home tab bar.
///
/// Both pages are plain `List`s hosted by `StocksView`'s `TabView`; the container
/// keeps the navigation title, search, pull-to-refresh and every lifecycle hook so
/// page switching never disturbs the refresh coordinator's visibility bookkeeping.
enum StocksHomePage: Hashable, CaseIterable, Identifiable {
    case positions
    case watchlist

    var id: Self { self }

    var title: String {
        switch self {
        case .positions: return "持仓"
        case .watchlist: return "看盘"
        }
    }

    /// The system tab bar renders the filled variant for the selected tab on its
    /// own, so only the outline name is needed here.
    var systemImage: String {
        switch self {
        case .positions: return "chart.pie"
        case .watchlist: return "list.bullet.rectangle"
        }
    }
}

/// Wraps a home row with the navigation link and swipe actions shared by both
/// pages. Extracted so the positions and watchlist rows only describe layout.
struct StockHomeRowLink<Content: View>: View {
    @EnvironmentObject private var store: StockStore
    let stock: StockHolding
    @Binding var watchRoute: StockWatchRoute?
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        let link = NavigationLink {
            StockDetailView(stockID: stock.id)
        } label: {
            content()
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
                        watchRoute = StockWatchRoute(stockID: stock.id)
                    } label: {
                        Label("看盘", systemImage: "chart.xyaxis.line")
                    }
                }
        }
    }
}

/// The market segmented control shared by both pages. Selection lives in the
/// container so switching pages preserves the filter.
///
/// 只有一个可选市场时整段控件都不画——单段分段控件点不出任何变化，只是占位。
struct StockMarketFilterPicker: View {
    @Binding var selection: StockMarketFilter
    let filters: [StockMarketFilter]

    static func isMeaningful(_ filters: [StockMarketFilter]) -> Bool {
        filters.count > 1
    }

    @ViewBuilder
    var body: some View {
        if Self.isMeaningful(filters) {
            Picker("股票市场", selection: $selection) {
                ForEach(filters) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// List chrome that has to travel with the `List` itself rather than stay on the
/// container, now that each page owns its own scroll view.
struct StockHomeListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
#if os(iOS)
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
#endif
    }
}

/// Refresh state, last fetch time and the quote-source disclosure. Shown at the
/// bottom of both pages so the disclosure is never more than one screen away.
struct StockQuoteStatusSection: View {
    @EnvironmentObject private var store: StockStore
    let market: StockMarket?

    var body: some View {
        Section {
            if store.isRefreshingQuotes || store.isRefreshingCharts {
                Label("正在刷新行情", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            if let error = store.quoteRefreshError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            AppLabeledContentRow("最新数据获取时间") {
                if let updatedAt = store.lastRefreshAt(for: market) {
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
}

/// 看盘页顶部的交易时段条：每个在列表里出现的市场一枚市场角标 + 当前时段。
///
/// 复用 `StockMarketSessionLabel`（`StocksView.swift`）而不是另写一套判定，时段文案
/// 与股票详情页保持一致；A 股与港股没有盘前盘后，那里会自然落到「已休市」。
struct StockWatchlistSessionStrip: View {
    let markets: [StockMarket]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(markets, id: \.self) { market in
                HStack(spacing: 5) {
                    StockMarketBadge(market: market)
                    StockMarketSessionLabel(market: market, usesCompactIcon: true)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 持仓页：净清算价值与当日盈亏置顶，下面是券商风格的五列持仓表。
struct StockPositionsPage: View {
    @EnvironmentObject private var store: StockStore
    @Binding var marketFilter: StockMarketFilter
    @Binding var watchRoute: StockWatchRoute?
    let availableMarketFilters: [StockMarketFilter]
    let positions: [StockHolding]
    let summaryStocks: [StockHolding]
    let summaryMarkets: [StockMarket]
    let allocations: StockAllocationSnapshot
    let costAllocations: StockCostAllocationSnapshot
    let searchTerm: String
    let hasConfiguredStocks: Bool

    var body: some View {
        List {
            if StockMarketFilterPicker.isMeaningful(availableMarketFilters) {
                Section {
                    StockMarketFilterPicker(
                        selection: $marketFilter,
                        filters: availableMarketFilters
                    )
                }
            }

            Section {
                StockPortfolioOverviewRow(
                    marketFilter: marketFilter,
                    summaryStocks: summaryStocks,
                    summaryMarkets: summaryMarkets,
                    allocations: allocations
                )
                .appListRowStyle()
            }

            Section("当前持仓（\(positions.count)）") {
                if positions.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
                } else {
                    StockPositionColumnHeader()
                        .modifier(StockCompactListRowStyle())
                    ForEach(positions) { stock in
                        StockHomeRowLink(stock: stock, watchRoute: $watchRoute) {
                            StockPositionRow(
                                stock: stock,
                                costShare: costAllocations.holdingShare(for: stock.id),
                                extendedHours: store.extendedHoursPerformance[stock.id]
                            )
                        }
                    }
                }
            }

            StockQuoteStatusSection(market: marketFilter.market)
        }
        .modifier(StockHomeListStyle())
    }

    private var emptyTitle: String {
        if !searchTerm.isEmpty { return "没有匹配的持仓股票" }
        return hasConfiguredStocks ? "暂无持仓股票" : "暂无股票"
    }

    private var emptySystemImage: String {
        searchTerm.isEmpty ? "chart.line.uptrend.xyaxis" : "magnifyingglass"
    }
}

/// 看盘页：列出全部在册标的（持仓与纯看盘一起，可选追加历史股票），每行带当日分时
/// 迷你图。持仓股票默认也在这里，这样看盘不需要先清仓。
struct StockWatchlistPage: View {
    @EnvironmentObject private var store: StockStore
    @Binding var marketFilter: StockMarketFilter
    @Binding var watchRoute: StockWatchRoute?
    let availableMarketFilters: [StockMarketFilter]
    let watchlist: [StockHolding]
    let archivedStocks: [StockHolding]
    let showsArchivedStocks: Bool
    let searchTerm: String
    let hasConfiguredStocks: Bool

    var body: some View {
        List {
            if StockMarketFilterPicker.isMeaningful(availableMarketFilters) || !sessionMarkets.isEmpty {
                Section {
                    StockMarketFilterPicker(
                        selection: $marketFilter,
                        filters: availableMarketFilters
                    )
                    if !sessionMarkets.isEmpty {
                        StockWatchlistSessionStrip(markets: sessionMarkets)
                    }
                }
            }

            Section("看盘（\(watchlist.count)）") {
                if watchlist.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
                } else {
                    ForEach(watchlist) { stock in
                        watchRow(stock)
                    }
                }
            }

            if showsArchivedStocks && !archivedStocks.isEmpty {
                Section("历史股票（\(archivedStocks.count)）") {
                    ForEach(archivedStocks) { stock in
                        watchRow(stock)
                    }
                }
            }

            StockQuoteStatusSection(market: marketFilter.market)
        }
        .modifier(StockHomeListStyle())
    }

    /// 需要显示交易时段的市场：筛选到具体市场时只显示它，「全部」时按固定顺序显示
    /// 当前列表里真正出现过的市场。
    private var sessionMarkets: [StockMarket] {
        if let market = marketFilter.market { return [market] }
        let listed = watchlist + (showsArchivedStocks ? archivedStocks : [])
        return StockMarket.topLevelOrder.filter { market in
            listed.contains { $0.market == market }
        }
    }

    @ViewBuilder
    private func watchRow(_ stock: StockHolding) -> some View {
        StockHomeRowLink(stock: stock, watchRoute: $watchRoute) {
            StockWatchlistRow(
                stock: stock,
                extendedHours: store.extendedHoursPerformance[stock.id],
                sparkline: store.intradaySparklines[stock.id]
            )
        }
    }

    private var emptyTitle: String {
        if !searchTerm.isEmpty { return "没有匹配的看盘股票" }
        return hasConfiguredStocks ? "暂无看盘股票" : "暂无股票"
    }

    private var emptySystemImage: String {
        searchTerm.isEmpty ? "chart.xyaxis.line" : "magnifyingglass"
    }
}
#endif
