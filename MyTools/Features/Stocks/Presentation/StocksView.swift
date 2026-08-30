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
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var marketFilter: StockMarketFilter = .all
    @State private var didAutoSelectMarket = false
    @State private var didRefreshOnCurrentAppearance = false
    @State private var enteringRefreshTask: Task<Void, Never>?
    @State private var editingStock: StockHolding?
    @State private var watchRoute: WatchRoute?
    @State private var showsArchivedStocks = false

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
        let multipliers: [StockMarket: Decimal]
        if let market = marketFilter.market {
            multipliers = [market: 1]
        } else {
            var renminbiMultipliers: [StockMarket: Decimal] = [.aShare: 1]
            if let rate = exchangeRateStore.renminbiBuyingRates[.hkd] {
                renminbiMultipliers[.hongKong] = rate
            }
            if let rate = exchangeRateStore.renminbiBuyingRates[.usd] {
                renminbiMultipliers[.unitedStates] = rate
            }
            multipliers = renminbiMultipliers
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

            Section {
                RenminbiPortfolioSummaryRow(marketFilter: marketFilter)
                    .appListRowStyle()
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
                LabeledContent("最新数据获取时间") {
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
        .searchable(text: $query, prompt: "搜索股票名称或代码")
        .refreshable {
            await store.refreshQuotes(
                for: marketFilter.market,
                forceRefresh: true
            )
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

                AdminEditAccessButton()

                if auth.isEditSessionReady {
                    Button { editingStock = StockHolding() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加股票")
                }
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
                costShare: costAllocation.holdingShare(for: stock.id)
            )
        }
        if stock.isArchived {
            link
                .appListRowStyle()
                .appSwipeActions(edge: .leading, style: AppSwipeActions.secondary) {
                    Button {
                        _ = store.restoreArchivedStock(id: stock.id)
                    } label: {
                        Label("恢复看盘", systemImage: "arrow.uturn.backward")
                    }
                }
                .appDeleteSwipeAction(isEnabled: auth.isEditSessionReady) {
                    store.deleteStocks(ids: [stock.id])
                }
        } else {
            link
                .appListRowStyle()
                .modifier(StockListRemovalActions(
                    stock: stock,
                    isEnabled: auth.isEditSessionReady,
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
        if let openMarket = StockMarket.displayOrder.first(where: {
            availableMarkets.contains($0)
                && StockMarketTradingCalendar.isOpen($0, at: now)
        }) {
            marketFilter = StockMarketFilter(openMarket)
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

    private var convertedValues: (
        holdingCost: Decimal,
        profitLoss: Decimal?,
        totalProfitLoss: Decimal?
    )? {
        var holdingCost = Decimal.zero
        var holdingProfitLoss = Decimal.zero
        var realizedProfitLoss = Decimal.zero
        var missingQuote = false
        for stock in selectedStocks {
            guard let multiplier = renminbiMultiplier(for: stock.market) else { return nil }
            holdingCost += stock.holdingCost * multiplier
            realizedProfitLoss += stock.realizedProfitLoss * multiplier
            if let value = stock.holdingProfitLoss {
                holdingProfitLoss += value * multiplier
            } else if stock.latestPrice == nil && stock.currentShares > 0 {
                missingQuote = true
            }
        }
        let profitLoss = missingQuote ? nil : holdingProfitLoss
        return (
            holdingCost,
            profitLoss,
            profitLoss.map { $0 + realizedProfitLoss }
        )
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

    private func renminbiMultiplier(for market: StockMarket) -> Decimal? {
        switch market {
        case .aShare: return 1
        case .hongKong: return exchangeRateStore.renminbiBuyingRates[.hkd]
        case .unitedStates: return exchangeRateStore.renminbiBuyingRates[.usd]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack(spacing: 6) {
                Label("人民币合计", systemImage: "yensign.circle.fill")
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
            StockSummaryMetricsHeader()
            if let values = convertedValues {
                HStack(spacing: 12) {
                    metric("持仓成本", value: StockValueFormatter.money(values.holdingCost, currencyCode: "CNY"))
                    metric("持仓盈亏", value: profitLossText(values.profitLoss), color: profitLossColor(values.profitLoss))
                    metric("总盈亏", value: profitLossText(values.totalProfitLoss), color: profitLossColor(values.totalProfitLoss))
                }
            } else {
                Label(missingRateText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
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

    private func metric(_ title: String, value: String, color: Color = .primary) -> some View {
        Text(value)
            .appFont(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .accessibilityLabel("\(title)，\(value)")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profitLossText(_ value: Decimal?) -> String {
        value.map { StockValueFormatter.moneyMagnitude($0, currencyCode: "CNY") } ?? "待同步"
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

            HStack(spacing: 12) {
                summaryMetric("持仓成本", value: StockValueFormatter.money(summary.holdingCost, currencyCode: summary.market.currencyCode))
                summaryMetric("持仓盈亏", value: profitLossText, color: profitLossColor)
                summaryMetric("总盈亏", value: totalProfitLossText, color: totalProfitLossColor)
            }
        }
    }

    private var positionSummaryText: String {
        let positionCount = "\(summary.openPositionCount) 只持仓"
        guard showsAllocation else { return positionCount }
        let allocationText = allocation.map(StockValueFormatter.allocationPercent) ?? "待同步"
        return "\(positionCount) · 占比 \(allocationText)"
    }

    private var totalProfitLossText: String {
        guard let totalProfitLoss = summary.totalProfitLoss else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(totalProfitLoss, currencyCode: summary.market.currencyCode)
    }

    private var totalProfitLossColor: Color {
        guard let totalProfitLoss = summary.totalProfitLoss else { return .secondary }
        return StockTrendColor.color(
            for: totalProfitLoss,
            market: summary.market,
            settings: stockAppearanceSettings
        )
    }

    private var profitLossText: String {
        guard let profitLoss = summary.profitLoss else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(profitLoss, currencyCode: summary.market.currencyCode)
    }

    private var profitLossColor: Color {
        guard let profitLoss = summary.profitLoss else { return .secondary }
        return StockTrendColor.color(
            for: profitLoss,
            market: summary.market,
            settings: stockAppearanceSettings
        )
    }

    private func summaryMetric(_ title: String, value: String, color: Color = .primary) -> some View {
        Text(value)
            .appFont(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .accessibilityLabel("\(title)，\(value)")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StockSummaryMetricsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            header("持仓成本")
            header("持仓盈亏")
            header("总盈亏")
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .appFont(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StockRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let stock: StockHolding
    let costShare: Decimal?

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    metric("持仓", value: holdingQuantityText)
                    metric("成本", value: holdingCostText, leadingInset: 8)
                    metric(
                        "今日涨跌",
                        value: changePercentText,
                        color: changePercentColor,
                        leadingInset: 8
                    )
                }
                GridRow {
                    metric("市值", value: marketValueText)
                    metric(
                        "盈亏",
                        value: profitLossText,
                        color: profitLossColor,
                        leadingInset: 8
                    )
                    metric(
                        "盈率",
                        value: profitRateText,
                        color: profitRateColor,
                        leadingInset: 8
                    )
                }
            }
            .appFont(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private func metric(
        _ label: String,
        value: String,
        color: Color = .primary,
        leadingInset: CGFloat = 0
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .padding(.leading, leadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var changePercentText: String {
        stock.changePercent.map(StockValueFormatter.signedPercent) ?? "--"
    }

    private var changePercentColor: Color {
        guard let value = stock.changePercent else { return .secondary }
        return StockTrendColor.color(for: value, market: stock.market, settings: stockAppearanceSettings, neutral: .secondary)
    }

    private var marketValueText: String {
        guard let value = stock.marketValue else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var holdingCostText: String {
        StockValueFormatter.money(stock.holdingCost, currencyCode: stock.market.currencyCode)
    }

    private var holdingQuantityText: String {
        let quantity = "\(StockValueFormatter.integerQuantity(stock.currentShares)) 股"
        guard let costShare else { return quantity }
        return "\(quantity) (\(StockValueFormatter.allocationPercent(costShare)))"
    }

    private var profitLossText: String {
        guard stock.currentShares > 0, let value = stock.holdingProfitLoss else { return "--" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var profitLossColor: Color {
        guard stock.currentShares > 0, let value = stock.holdingProfitLoss else { return .secondary }
        return StockTrendColor.color(for: value, market: stock.market, settings: stockAppearanceSettings, neutral: .secondary)
    }

    private var profitRateText: String {
        stock.holdingProfitRate.map(StockValueFormatter.signedPercent) ?? "--"
    }

    private var profitRateColor: Color {
        guard let value = stock.holdingProfitRate else { return .secondary }
        return StockTrendColor.color(for: value, market: stock.market, settings: stockAppearanceSettings, neutral: .secondary)
    }
}

struct StockMarketBadge: View {
    let market: StockMarket

    private var color: Color {
        switch market {
        case .aShare: return .orange
        case .hongKong: return .purple
        case .unitedStates: return .indigo
        }
    }

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
