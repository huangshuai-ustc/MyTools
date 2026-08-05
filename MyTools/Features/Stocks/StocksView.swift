import SwiftUI

@MainActor
private func stockValueColor(
    _ value: Decimal,
    market: StockMarket,
    settings: StockAppearanceSettings
) -> Color {
        guard value != 0 else { return .primary }
        let scheme = settings.scheme(for: market)
        switch (value >= 0, scheme) {
        case (true, .redRiseGreenFall), (false, .greenRiseRedFall): return .red
        case (true, .greenRiseRedFall), (false, .redRiseGreenFall): return .green
        }
}

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
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var marketFilter: StockMarketFilter = .all
    @State private var didAutoSelectMarket = false
    @State private var didRefreshOnCurrentAppearance = false
    @State private var enteringRefreshTask: Task<Void, Never>?
    @State private var editingStock: StockHolding?
    @State private var showsNoPositionStocks = false
    @AppStorage("stock-sort-criterion-v2") private var sortCriterionRawValue = StockSortCriterion.name.rawValue
    @AppStorage("stock-sort-direction-v2") private var sortDirectionRawValue = StockSortDirection.ascending.rawValue

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
            if let rate = store.renminbiBuyingRates[.hkd] {
                renminbiMultipliers[.hongKong] = rate
            }
            if let rate = store.renminbiBuyingRates[.usd] {
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

            Section(ToolModule.myStocks.title) {
                if displayedStocks.isEmpty {
                    ContentUnavailableView(
                        emptyStocksTitle,
                        systemImage: emptyStocksSystemImage
                    )
                }
                stockLinks(displayedStocks, allocations: allocations)
                if !showsNoPositionStocks, !noPositionStocks.isEmpty {
                    HiddenItemsVisibilityButton(
                        itemsDescription: "\(noPositionStocks.count) 只无持仓股票",
                        isShowing: $showsNoPositionStocks
                    )
                }
            }
            if showsNoPositionStocks, !noPositionStocks.isEmpty {
                Section("无持仓股票（\(noPositionStocks.count)）") {
                    HiddenItemsVisibilityButton(
                        itemsDescription: "\(noPositionStocks.count) 只无持仓股票",
                        isShowing: $showsNoPositionStocks
                    )
                    stockLinks(noPositionStocks, allocations: allocations)
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
                    if let updatedAt = store.lastStockRefreshAt(for: marketFilter.market) {
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
        .iOSLabeledBackButton("工具箱")
        .searchable(text: $query, prompt: "搜索股票名称或代码")
        .refreshable {
            await store.refreshStockQuotes(for: marketFilter.market)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StockSortMenu(
                    criterionRawValue: $sortCriterionRawValue,
                    directionRawValue: $sortDirectionRawValue
                )
                Button {
                    Task { await store.refreshStockQuotes(for: marketFilter.market) }
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
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
#endif
        .sheet(item: $editingStock) { stock in
            StockEditorView(stock: stock, isNew: true)
                .id(stock.id)
                .iOSLargeSheet()
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
        .onChange(of: store.isInitialDataLoaded) { _, isLoaded in
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
            showsNoPositionStocks = false
            didRefreshOnCurrentAppearance = false
        }
    }

    private func stockLink(_ stock: StockHolding, allocation: Decimal?) -> some View {
        NavigationLink {
            StockDetailView(stockID: stock.id)
        } label: {
            StockRow(
                stock: stock,
                allocation: allocation
            )
        }
        .appListRowStyle()
    }

    @ViewBuilder
    private func stockLinks(
        _ stocks: [StockHolding],
        allocations: StockAllocationSnapshot
    ) -> some View {
        if auth.isEditSessionReady {
            ForEach(stocks) { stock in
                stockLink(stock, allocation: allocations.holdingShare(for: stock.id))
            }
            .onDelete { deleteStocks(at: $0, from: stocks) }
        } else {
            ForEach(stocks) { stock in
                stockLink(stock, allocation: allocations.holdingShare(for: stock.id))
            }
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

    private func deleteStocks(at offsets: IndexSet, from stocks: [StockHolding]) {
        let ids = Set(offsets.map { stocks[$0].id })
        store.deleteStocks(ids: ids)
    }

    private func autoSelectMarketIfNeeded() {
        guard store.isInitialDataLoaded, !didAutoSelectMarket else { return }

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
        guard store.isInitialDataLoaded, !didRefreshOnCurrentAppearance else { return }
        didRefreshOnCurrentAppearance = true
        enteringRefreshTask?.cancel()
        enteringRefreshTask = Task { @MainActor in
            await store.refreshStockQuotes(for: marketFilter.market)
        }
    }
}

private struct RenminbiPortfolioSummaryRow: View {
    @EnvironmentObject private var store: AppStore
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
        let missing = requiredForeignCurrencies.filter { store.renminbiBuyingRates[$0] == nil }
        guard !missing.isEmpty else { return "外币买入价待同步" }
        return "中国银行\(missing.map(\.title).joined(separator: "、"))现汇买入价待同步"
    }

    private func renminbiMultiplier(for market: StockMarket) -> Decimal? {
        switch market {
        case .aShare: return 1
        case .hongKong: return store.renminbiBuyingRates[.hkd]
        case .unitedStates: return store.renminbiBuyingRates[.usd]
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
            guard let rate = store.renminbiBuyingRates[currency] else { return nil }
            return "按中国银行\(currency.title)现汇买入价换算：1 \(currency.rawValue) = \(StockValueFormatter.exchangeRate(rate)) CNY"
        }
        let missingCurrencies = requiredForeignCurrencies.filter { store.renminbiBuyingRates[$0] == nil }
        if !missingCurrencies.isEmpty {
            lines.append("\(missingCurrencies.map(\.title).joined(separator: "、"))牌价待同步。")
        }
        if let updatedAt = store.exchangeRateUpdatedAt {
            lines.append("牌价时间：\(AppDateFormatter.dateTimeString(from: updatedAt))")
        }
        if let error = store.exchangeRateError, !missingCurrencies.isEmpty {
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
        return stockValueColor(value, market: market, settings: stockAppearanceSettings)
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
        return stockValueColor(totalProfitLoss, market: summary.market, settings: stockAppearanceSettings)
    }

    private var profitLossText: String {
        guard let profitLoss = summary.profitLoss else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(profitLoss, currencyCode: summary.market.currencyCode)
    }

    private var profitLossColor: Color {
        guard let profitLoss = summary.profitLoss else { return .secondary }
        return stockValueColor(profitLoss, market: summary.market, settings: stockAppearanceSettings)
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
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stock: StockHolding
    let allocation: Decimal?

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

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("持仓 \(StockValueFormatter.quantity(stock.currentShares)) 股")
                    Text("市值 \(marketValueText) (\(allocationText))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 4) {
                    metric("涨跌", value: changePercentText, color: changePercentColor)
                    metric(profitLossLabel, value: profitLossText, color: profitLossColor)
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private func metric(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 28, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(width: 66, alignment: .trailing)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 100, alignment: .leading)
    }

    private var changePercentText: String {
        stock.changePercent.map(StockValueFormatter.percent) ?? "--"
    }

    private var changePercentColor: Color {
        guard let value = stock.changePercent else { return .secondary }
        return stockValueColor(value, market: stock.market, settings: stockAppearanceSettings)
    }

    private var marketValueText: String {
        guard let value = stock.marketValue else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var profitLossText: String {
        guard stock.currentShares > 0, let value = stock.holdingProfitLoss else { return "--" }
        return StockValueFormatter.moneyMagnitude(value, currencyCode: stock.market.currencyCode)
    }

    private var allocationText: String {
        allocation.map(StockValueFormatter.allocationPercent) ?? "待同步"
    }

    private var profitLossLabel: String {
        "盈亏"
    }

    private var profitLossColor: Color {
        guard stock.currentShares > 0, let value = stock.holdingProfitLoss else { return .secondary }
        return stockValueColor(value, market: stock.market, settings: stockAppearanceSettings)
    }
}

struct StockMarketBadge: View {
    let market: StockMarket

    private var color: Color {
        switch market {
        case .aShare: return .purple
        case .hongKong: return .orange
        case .unitedStates: return .teal
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

private struct StockDetailView: View {
    private enum EditorRoute: Identifiable {
        case stock(StockHolding)
        case transaction(StockTransaction)
        case dividend(StockDividend)

        var id: String {
            switch self {
            case .stock(let stock):
                return "stock-\(stock.id.uuidString)"
            case .transaction(let transaction):
                return "transaction-\(transaction.id.uuidString)"
            case .dividend(let dividend):
                return "dividend-\(dividend.id.uuidString)"
            }
        }
    }

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stockID: UUID
    @State private var editorRoute: EditorRoute?
    @State private var showingTransactionOrderEditor = false
    @State private var transactionError = ""
    @State private var showingTransactionError = false

    private var stock: StockHolding? {
        store.stocks.first { $0.id == stockID }
    }

    var body: some View {
        Group {
            if let stock {
                stockList(stock)
            } else {
                ContentUnavailableView("股票已不存在", systemImage: "chart.line.downtrend.xyaxis")
            }
        }
        .navigationTitle(stock?.displayName ?? "股票详情")
        .iOSLabeledBackButton(ToolModule.myStocks.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await store.refreshStockQuotes(for: stock?.market) }
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

                if auth.isEditSessionReady, let stock {
                    Button { editorRoute = .stock(stock) } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("编辑股票")
                }
            }
        }
        .sheet(item: $editorRoute) { route in
            switch route {
            case .stock(let stock):
                StockEditorView(stock: stock, isNew: false)
                    .id(stock.id)
                    .iOSLargeSheet()
            case .transaction(let transaction):
                if let stock {
                    StockTransactionEditorView(transaction: transaction, stock: stock)
                        .id(transaction.id)
                        .iOSLargeSheet()
                }
            case .dividend(let dividend):
                if let stock {
                    StockDividendEditorView(dividend: dividend, stock: stock)
                        .id(dividend.id)
                        .iOSLargeSheet()
                }
            }
        }
        .sheet(isPresented: $showingTransactionOrderEditor) {
            StockTransactionOrderEditorView(stockID: stockID)
                .iOSLargeSheet()
        }
        .alert("无法删除交易", isPresented: $showingTransactionError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(transactionError)
        }
        .onAppear {
            StockRefreshCoordinator.shared.setStocksPageVisible(false)
        }
    }

    private func stockList(_ stock: StockHolding) -> some View {
        let sortedTransactions = stock.transactionsNewestFirst
        let sortedDividends = stock.dividends.sorted { $0.receivedAt > $1.receivedAt }

        return List {
            Section("行情") {
                LabeledContent("市场") { StockMarketBadge(market: stock.market) }
                LabeledContent("股票代码", value: stock.symbol)
                if !stock.name.isEmpty {
                    LabeledContent("自定义名称", value: stock.name)
                }
                LabeledContent("最新价", value: stock.latestPrice.map { StockValueFormatter.price($0, currencyCode: stock.market.currencyCode) } ?? "待同步")
                if let changePercent = stock.changePercent {
                    LabeledContent("涨跌幅") {
                        Text(StockValueFormatter.percent(changePercent))
                            .foregroundStyle(stockValueColor(changePercent, market: stock.market, settings: stockAppearanceSettings))
                    }
                }
                if let lastQuoteAt = stock.lastQuoteAt {
                    LabeledContent("更新时间", value: AppDateFormatter.string(from: lastQuoteAt))
                }
                if let source = store.quoteSources[stock.id] {
                    LabeledContent("行情来源", value: source)
                }
                if let error = store.quoteErrors[stock.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("持仓总览") {
                LabeledContent("当前持仓", value: "\(StockValueFormatter.quantity(stock.currentShares)) 股")
                LabeledContent("累计买入金额", value: StockValueFormatter.money(stock.totalBuyCost, currencyCode: stock.market.currencyCode))
                LabeledContent(
                    "单股持有成本",
                    value: stock.averageHoldingCost.map {
                        StockValueFormatter.price($0, currencyCode: stock.market.currencyCode)
                    } ?? "无持仓"
                )
                LabeledContent("持仓市值", value: stock.marketValue.map { StockValueFormatter.money($0, currencyCode: stock.market.currencyCode) } ?? "待同步")
                LabeledContent("持仓盈亏") {
                    if let value = stock.holdingProfitLoss {
                        Text(StockValueFormatter.moneyMagnitude(value, currencyCode: stock.market.currencyCode))
                            .foregroundStyle(stockValueColor(value, market: stock.market, settings: stockAppearanceSettings))
                    } else {
                        Text("待同步").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("已变现利润（含分红）") {
                    Text(StockValueFormatter.money(stock.realizedProfitLoss, currencyCode: stock.market.currencyCode))
                        .foregroundStyle(stockValueColor(stock.realizedProfitLoss, market: stock.market, settings: stockAppearanceSettings))
                }
                LabeledContent("累计总收益（含已变现）") {
                    if let totalProfitLoss = stock.totalProfitLoss {
                        Text(StockValueFormatter.money(totalProfitLoss, currencyCode: stock.market.currencyCode))
                            .foregroundStyle(stockValueColor(totalProfitLoss, market: stock.market, settings: stockAppearanceSettings))
                    } else {
                        Text("待同步").foregroundStyle(.secondary)
                    }
                }
            }

            Section("交易记录") {
                if sortedTransactions.isEmpty {
                    Text("暂无交易记录").foregroundStyle(.secondary)
                }
                if auth.isEditSessionReady {
                    ForEach(sortedTransactions) { transaction in
                        Button { editorRoute = .transaction(transaction) } label: {
                            StockTransactionRow(transaction: transaction, market: stock.market)
                        }
                        .buttonStyle(.plain)
                        .appListRowStyle()
                    }
                    .onDelete { offsets in
                        deleteTransactions(at: offsets, sortedTransactions: sortedTransactions)
                    }
                    Button { editorRoute = .transaction(StockTransaction()) } label: {
                        Label("添加买入或卖出记录", systemImage: "plus.circle")
                    }
                    if !stock.reorderableTransactionDayGroups.isEmpty {
                        Button { showingTransactionOrderEditor = true } label: {
                            Label("调整同日交易顺序", systemImage: "arrow.up.arrow.down")
                        }
                    }
                } else {
                    ForEach(sortedTransactions) { transaction in
                        StockTransactionRow(transaction: transaction, market: stock.market)
                            .appListRowStyle()
                    }
                }
            }

            Section("分红记录") {
                if sortedDividends.isEmpty {
                    Text("暂无分红记录").foregroundStyle(.secondary)
                }
                if auth.isEditSessionReady {
                    ForEach(sortedDividends) { dividend in
                        Button { editorRoute = .dividend(dividend) } label: {
                            StockDividendRow(dividend: dividend, market: stock.market)
                        }
                        .buttonStyle(.plain)
                        .appListRowStyle()
                    }
                    .onDelete { offsets in
                        deleteDividends(at: offsets, sortedDividends: sortedDividends)
                    }
                    Button { editorRoute = .dividend(StockDividend()) } label: {
                        Label("添加分红记录", systemImage: "plus.circle")
                    }
                } else {
                    ForEach(sortedDividends) { dividend in
                        StockDividendRow(dividend: dividend, market: stock.market)
                            .appListRowStyle()
                    }
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
    }

    private func deleteTransactions(at offsets: IndexSet, sortedTransactions: [StockTransaction]) {
        let ids = Set(offsets.map { sortedTransactions[$0].id })
        guard store.deleteStockTransactions(ids: ids, from: stockID) else {
            transactionError = "删除这些记录后持仓股数会小于零，请先调整相应的卖出记录。"
            showingTransactionError = true
            return
        }
    }

    private func deleteDividends(at offsets: IndexSet, sortedDividends: [StockDividend]) {
        let ids = Set(offsets.map { sortedDividends[$0].id })
        store.deleteStockDividends(ids: ids, from: stockID)
    }
}

private struct StockTransactionDayGroup: Identifiable {
    let date: Date
    let transactions: [StockTransaction]

    var id: Date { date }
}

private extension StockHolding {
    var reorderableTransactionDayGroups: [StockTransactionDayGroup] {
        let groups = Dictionary(grouping: transactionsChronologically) {
            StockTransaction.normalizedDate($0.tradedAt)
        }
        return groups
            .compactMap { date, transactions in
                guard transactions.count > 1 else { return nil }
                return StockTransactionDayGroup(date: date, transactions: transactions)
            }
            .sorted { $0.date > $1.date }
    }
}

private struct StockTransactionOrderEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @State private var editMode: EditMode = .active
#endif
    @State private var errorMessage = ""
    @State private var showingError = false
    let stockID: UUID

    private var stock: StockHolding? {
        store.stocks.first { $0.id == stockID }
    }

    private var groups: [StockTransactionDayGroup] {
        stock?.reorderableTransactionDayGroups ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(AppDateFormatter.string(from: group.date)) {
                        ForEach(group.transactions) { transaction in
                            StockTransactionOrderRow(
                                transaction: transaction,
                                order: group.transactions.firstIndex(where: { $0.id == transaction.id }) ?? 0,
                                currencyCode: stock?.market.currencyCode ?? ""
                            )
                        }
                        .onMove { offsets, destination in
                            moveTransactions(
                                in: group,
                                from: offsets,
                                to: destination
                            )
                        }
                    }
                }
            }
            .navigationTitle("当日交易顺序")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("无法调整顺序", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
#if os(iOS)
        .environment(\.editMode, $editMode)
#endif
    }

    private func moveTransactions(
        in group: StockTransactionDayGroup,
        from offsets: IndexSet,
        to destination: Int
    ) {
        var orderedIDs = group.transactions.map(\.id)
        orderedIDs.move(fromOffsets: offsets, toOffset: destination)
        guard store.reorderStockTransactions(orderedIDs, in: stockID) else {
            errorMessage = "该顺序会使某笔卖出发生在可用持仓之前。"
            showingError = true
            return
        }
    }
}

private struct StockTransactionOrderRow: View {
    let transaction: StockTransaction
    let order: Int
    let currencyCode: String

    var body: some View {
        HStack(spacing: 12) {
            Text("第 \(order + 1) 笔")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(transaction.type.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(transaction.type == .buy ? .blue : .orange)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(StockValueFormatter.quantity(transaction.quantity)) 股")
                Text(StockValueFormatter.price(transaction.unitPrice, currencyCode: currencyCode))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

private struct StockTransactionRow: View {
    let transaction: StockTransaction
    let market: StockMarket

    private var color: Color {
        transaction.type == .buy ? .blue : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(transaction.type.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text("\(StockValueFormatter.quantity(transaction.quantity)) 股 × \(StockValueFormatter.price(transaction.unitPrice, currencyCode: market.currencyCode))")
                    .font(.subheadline.monospacedDigit())
                Text(AppDateFormatter.string(from: transaction.tradedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: AppListMetrics.recordContentSpacing) {
                Text(StockValueFormatter.money(transaction.grossAmount, currencyCode: market.currencyCode))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if transaction.fees > 0 {
                    Text("费用 \(StockValueFormatter.money(transaction.fees, currencyCode: market.currencyCode))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

private struct StockDividendRow: View {
    let dividend: StockDividend
    let market: StockMarket

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text(AppDateFormatter.string(from: dividend.receivedAt))
                    .font(.subheadline)
                if dividend.hasPerShareBreakdown {
                    Text("\(StockValueFormatter.quantity(dividend.quantity)) 股 × \(StockValueFormatter.price(dividend.dividendPerShare, currencyCode: market.currencyCode))/股")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !dividend.note.isEmpty {
                    Text(dividend.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: AppListMetrics.recordContentSpacing) {
                Text(StockValueFormatter.money(dividend.netAmount, currencyCode: market.currencyCode))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if dividend.totalDeductions > 0 {
                    Text("税前 \(StockValueFormatter.money(dividend.grossAmount, currencyCode: market.currencyCode)) · 扣除 \(StockValueFormatter.money(dividend.totalDeductions, currencyCode: market.currencyCode))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
