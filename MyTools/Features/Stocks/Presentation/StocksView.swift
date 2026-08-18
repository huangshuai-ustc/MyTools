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

private enum StockSortCriterion: String, CaseIterable, Identifiable {
    case name
    case firstPurchase

    var id: Self { self }

    var title: String {
        switch self {
        case .name: return "名称"
        case .firstPurchase: return "首购日期"
        }
    }
}

private enum StockSortDirection: String {
    case ascending
    case descending

    var indicator: String {
        switch self {
        case .ascending: return "↑"
        case .descending: return "↓"
        }
    }

    var title: String {
        switch self {
        case .ascending: return "顺序"
        case .descending: return "倒序"
        }
    }

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

private struct StockSorter {
    let criterion: StockSortCriterion
    let direction: StockSortDirection

    func sorted(_ stocks: [StockHolding]) -> [StockHolding] {
        stocks.sorted { lhs, rhs in
            switch criterion {
            case .name:
                return isOrderedBefore(nameComparison(lhs, rhs))
            case .firstPurchase:
                switch (lhs.firstPurchasedAt, rhs.firstPurchasedAt) {
                case let (left?, right?) where left != right:
                    return direction == .ascending ? left < right : left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return isOrderedBefore(nameComparison(lhs, rhs))
                }
            }
        }
    }

    private func nameComparison(_ lhs: StockHolding, _ rhs: StockHolding) -> ComparisonResult {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        return comparison == .orderedSame
            ? lhs.symbol.localizedStandardCompare(rhs.symbol)
            : comparison
    }

    private func isOrderedBefore(_ comparison: ComparisonResult) -> Bool {
        switch direction {
        case .ascending: return comparison == .orderedAscending
        case .descending: return comparison == .orderedDescending
        }
    }
}

private struct StockSortMenu: View {
    @Binding var criterionRawValue: String
    @Binding var directionRawValue: String

    private var selectedCriterion: StockSortCriterion {
        StockSortCriterion(rawValue: criterionRawValue) ?? .name
    }

    private var selectedDirection: StockSortDirection {
        StockSortDirection(rawValue: directionRawValue) ?? .ascending
    }

    var body: some View {
        Menu {
            ForEach(StockSortCriterion.allCases) { criterion in
                Button {
                    select(criterion)
                } label: {
                    if selectedCriterion == criterion {
                        Text("\(criterion.title)  \(selectedDirection.indicator)")
                    } else {
                        Text(criterion.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("股票排序：\(selectedCriterion.title)，\(selectedDirection.title)")
        .help("股票排序：\(selectedCriterion.title)，\(selectedDirection.title)")
    }

    private func select(_ criterion: StockSortCriterion) {
        if selectedCriterion == criterion {
            var direction = selectedDirection
            direction.toggle()
            directionRawValue = direction.rawValue
        } else {
            criterionRawValue = criterion.rawValue
            directionRawValue = StockSortDirection.ascending.rawValue
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
    @AppStorage(AppStorageKey.stockSortCriterion) private var sortCriterionRawValue = StockSortCriterion.name.rawValue
    @AppStorage(AppStorageKey.stockSortDirection) private var sortDirectionRawValue = StockSortDirection.ascending.rawValue

    private var stockSorter: StockSorter {
        StockSorter(
            criterion: StockSortCriterion(rawValue: sortCriterionRawValue) ?? .name,
            direction: StockSortDirection(rawValue: sortDirectionRawValue) ?? .ascending
        )
    }

    private var configuredStocks: [StockHolding] {
        store.stocks.filter(\.hasConfiguredSymbol)
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
        stockSorter.sorted(searchFilteredStocks.filter { $0.currentShares > 0 })
    }

    private var noPositionStocks: [StockHolding] {
        stockSorter.sorted(searchFilteredStocks.filter { $0.currentShares <= 0 })
    }

    private var summaryMarkets: [StockMarket] {
        if let market = marketFilter.market {
            return [market]
        }
        let openStocks = stocksInSelectedMarket.filter { $0.currentShares > 0 }
        return StockMarket.topLevelOrder.filter { market in
            openStocks.contains { $0.market == market }
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

    var body: some View {
        let allocations = allocationSnapshot

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

            if displayedStocks.isEmpty && noPositionStocks.isEmpty {
                Section("当前持仓（\(displayedStocks.count)）") {
                    ContentUnavailableView(
                        emptyStocksTitle,
                        systemImage: emptyStocksSystemImage
                    )
                }
            } else if !displayedStocks.isEmpty {
                Section("当前持仓（\(displayedStocks.count)）") {
                    stockLinks(displayedStocks)
                }
            }
            if !noPositionStocks.isEmpty {
                Section("无持仓或仅看盘（\(noPositionStocks.count)）") {
                    stockLinks(noPositionStocks)
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
        .navigationTitle(ToolModule.myStocks.title)
        .onChange(of: sortCriterionRawValue) { _, _ in
            NotificationCenter.default.post(name: .syncedAppPreferenceDidChange, object: nil)
        }
        .onChange(of: sortDirectionRawValue) { _, _ in
            NotificationCenter.default.post(name: .syncedAppPreferenceDidChange, object: nil)
        }
        .iOSLabeledBackButton("工具")
        .searchable(text: $query, prompt: "搜索股票名称或代码")
        .refreshable {
            await store.refreshQuotes(for: marketFilter.market)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StockSortMenu(
                    criterionRawValue: $sortCriterionRawValue,
                    directionRawValue: $sortDirectionRawValue
                )
                Button {
                    Task { await store.refreshQuotes(for: marketFilter.market) }
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

    private func stockLink(_ stock: StockHolding) -> some View {
        NavigationLink {
            StockDetailView(stockID: stock.id)
        } label: {
            StockRow(stock: stock)
        }
        .appListRowStyle()
        .appDeleteSwipeAction(isEnabled: auth.isEditSessionReady) {
            store.deleteStocks(ids: [stock.id])
        }
        .appSwipeActions(edge: .leading, style: AppSwipeActions.primary) {
            Button {
                watchRoute = WatchRoute(stockID: stock.id)
            } label: {
                Label("看盘", systemImage: "chart.xyaxis.line")
            }
            .tint(AppSwipeActions.primary.tint)
        }
    }

    @ViewBuilder
    private func stockLinks(_ stocks: [StockHolding]) -> some View {
        ForEach(stocks) { stock in
            stockLink(stock)
        }
    }

    private var emptyStocksTitle: String {
        if configuredStocks.isEmpty {
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

private struct RenminbiPortfolioSummaryRow: View {
    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
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
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack(spacing: 6) {
                Label("人民币合计", systemImage: "yensign.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Button {
                    showingConversionInfo = true
                } label: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityLabel("人民币合计说明")
                .help("人民币合计说明")
                Spacer()
                Text("CNY")
                    .font(.caption.monospaced())
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
            .font(.subheadline.weight(.semibold).monospacedDigit())
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
    let summary: StockPortfolioSummary
    let allocation: Decimal?
    let showsAllocation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack {
                StockMarketBadge(market: summary.market)
                Text(positionSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text(summary.market.currencyCode)
                    .font(.caption.monospaced())
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
            .font(.subheadline.weight(.semibold).monospacedDigit())
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
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StockRow: View {
    let stock: StockHolding

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StockMarketBadge(market: stock.market)
                Text(stock.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(stock.symbol)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    metric("持仓", value: holdingQuantityText)
                    metric("成本", value: holdingCostText)
                    metric("涨跌", value: changePercentText, color: changePercentColor)
                }
                GridRow {
                    metric("市值", value: marketValueText)
                    metric("盈亏", value: profitLossText, color: profitLossColor)
                    metric("盈率", value: profitRateText, color: profitRateColor)
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private func metric(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var changePercentText: String {
        stock.changePercent.map(StockValueFormatter.signedPercent) ?? "--"
    }

    private var changePercentColor: Color {
        guard let value = stock.changePercent else { return .secondary }
        return fixedProfitColor(value)
    }

    private var marketValueText: String {
        guard let value = stock.marketValue else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var holdingCostText: String {
        StockValueFormatter.money(stock.holdingCost, currencyCode: stock.market.currencyCode)
    }

    private var holdingQuantityText: String {
        return "\(StockValueFormatter.integerQuantity(stock.currentShares)) 股"
    }

    private var profitLossText: String {
        guard stock.currentShares > 0, let value = stock.holdingProfitLoss else { return "--" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var profitLossColor: Color {
        guard stock.currentShares > 0, let value = stock.holdingProfitLoss else { return .secondary }
        return fixedProfitColor(value)
    }

    private var profitRateText: String {
        stock.holdingProfitRate.map(StockValueFormatter.signedPercent) ?? "--"
    }

    private var profitRateColor: Color {
        guard let value = stock.holdingProfitRate else { return .secondary }
        return fixedProfitColor(value)
    }

    private func fixedProfitColor(_ value: Decimal) -> Color {
        if value > 0 { return .red }
        if value < 0 { return .green }
        return .secondary
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
            .font(.caption2.weight(.semibold))
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
