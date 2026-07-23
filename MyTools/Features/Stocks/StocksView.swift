import SwiftUI

@MainActor
private func stockValueColor(
    _ value: Decimal,
    market: StockMarket,
    settings: StockAppearanceSettings
) -> Color {
        let scheme = settings.scheme(for: market)
        switch (value >= 0, scheme) {
        case (true, .redRiseGreenFall), (false, .greenRiseRedFall): return .red
        case (true, .greenRiseRedFall), (false, .redRiseGreenFall): return .green
        }
}

private enum StockMarketFilter: String, CaseIterable, Identifiable {
    case all
    case aShare
    case unitedStates

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .aShare: return "A 股"
        case .unitedStates: return "美股"
        }
    }

    func includes(_ stock: StockHolding) -> Bool {
        switch self {
        case .all: return true
        case .aShare: return stock.market == .aShare
        case .unitedStates: return stock.market == .unitedStates
        }
    }
}

private enum StockSortOrder: String, CaseIterable, Identifiable {
    case nameAscending
    case firstPurchaseOldest

    var id: Self { self }

    var title: String {
        switch self {
        case .nameAscending: return "名称：A-Z"
        case .firstPurchaseOldest: return "最早购买时间"
        }
    }

    func sorted(_ stocks: [StockHolding]) -> [StockHolding] {
        stocks.sorted { lhs, rhs in
            switch self {
            case .nameAscending:
                return nameBefore(lhs, rhs)
            case .firstPurchaseOldest:
                switch (lhs.firstPurchasedAt, rhs.firstPurchasedAt) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return nameBefore(lhs, rhs)
                }
            }
        }
    }

    private func nameBefore(_ lhs: StockHolding, _ rhs: StockHolding) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        return comparison == .orderedSame
            ? lhs.symbol.localizedStandardCompare(rhs.symbol) == .orderedAscending
            : comparison == .orderedAscending
    }
}

private struct StockSortMenu: View {
    @Binding var selection: String

    var body: some View {
        Menu {
            Picker("排序方式", selection: $selection) {
                ForEach(StockSortOrder.allCases) { order in
                    Text(order.title).tag(order.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("股票排序")
        .help("股票排序")
    }
}

struct StocksView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var marketFilter: StockMarketFilter = .all
    @State private var editingStock: StockHolding?
    @AppStorage("stock-sort-order-v1") private var sortOrderRawValue = StockSortOrder.nameAscending.rawValue

    private var selectedSortOrder: StockSortOrder {
        StockSortOrder(rawValue: sortOrderRawValue) ?? .nameAscending
    }

    private var displayedStocks: [StockHolding] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.stocks
            .filter(marketFilter.includes)
            .filter { stock in
                searchTerm.isEmpty
                    || stock.symbol.localizedCaseInsensitiveContains(searchTerm)
                    || stock.displayName.localizedCaseInsensitiveContains(searchTerm)
            }
        return selectedSortOrder.sorted(filtered)
    }

    private var summaryMarkets: [StockMarket] {
        switch marketFilter {
        case .all:
            return StockMarket.allCases
        case .aShare:
            return [.aShare]
        case .unitedStates:
            return [.unitedStates]
        }
    }

    var body: some View {
        List {
            Section {
                Picker("市场", selection: $marketFilter) {
                    ForEach(StockMarketFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("资产总览") {
                RenminbiPortfolioSummaryRow(marketFilter: marketFilter)
                ForEach(summaryMarkets) { market in
                    StockMarketSummaryRow(
                        summary: StockPortfolioSummary(market: market, stocks: store.stocks)
                    )
                }
            }

            Section("我的股票") {
                if displayedStocks.isEmpty {
                    ContentUnavailableView(
                        store.stocks.isEmpty ? "暂无股票" : "没有匹配的股票",
                        systemImage: store.stocks.isEmpty ? "chart.line.uptrend.xyaxis" : "magnifyingglass"
                    )
                }
                if auth.isAdmin {
                    ForEach(displayedStocks) { stock in
                        stockLink(stock)
                    }
                    .onDelete(perform: deleteStocks)
                } else {
                    ForEach(displayedStocks) { stock in
                        stockLink(stock)
                    }
                }
            }

            Section {
                if store.isRefreshingQuotes {
                    Label("正在刷新行情", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                } else if let error = store.quoteRefreshError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let updatedAt = store.stocks.compactMap(\.lastQuoteAt).max() {
                    LabeledContent("最近刷新", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("行情通过新浪财经及东方财富公开接口获取，可能存在延迟，请以交易所和券商数据为准。")
            }
        }
        .navigationTitle("我的股票")
        .iOSLabeledBackButton("工具箱")
        .searchable(text: $query, prompt: "搜索股票名称或代码")
        .refreshable {
            await store.refreshStockQuotes()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StockSortMenu(selection: $sortOrderRawValue)
                Button {
                    Task { await store.refreshStockQuotes() }
                } label: {
                    if store.isRefreshingQuotes {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshingQuotes)
                .accessibilityLabel("刷新股票行情")

                AdminEditAccessButton {
                    editingStock = StockHolding()
                }

                if auth.isAdmin {
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
        .task {
            await store.refreshStockQuotes()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await store.refreshStockQuotes()
            }
        }
    }

    private func stockLink(_ stock: StockHolding) -> some View {
        NavigationLink {
            StockDetailView(stockID: stock.id)
        } label: {
            StockRow(stock: stock, quoteError: store.quoteErrors[stock.id])
        }
    }

    private func deleteStocks(at offsets: IndexSet) {
        let ids = Set(offsets.map { displayedStocks[$0].id })
        store.deleteStocks(ids: ids)
    }
}

private struct RenminbiPortfolioSummaryRow: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let marketFilter: StockMarketFilter

    private var includedStocks: [StockHolding] {
        store.stocks.filter(marketFilter.includes)
    }

    private var convertedValues: (netInvestment: Decimal, marketValue: Decimal, profitLoss: Decimal?)? {
        let containsUnitedStatesStock = includedStocks.contains { $0.market == .unitedStates }
        guard !containsUnitedStatesStock || store.usdRenminbiBuyingRate != nil else { return nil }
        let rate = store.usdRenminbiBuyingRate ?? 1
        var netInvestment = Decimal.zero
        var marketValue = Decimal.zero
        var missingQuote = false
        for stock in includedStocks {
            let multiplier: Decimal = stock.market == .unitedStates ? rate : 1
            netInvestment += stock.netInvestment * multiplier
            if let value = stock.marketValue {
                marketValue += value * multiplier
            } else if stock.currentShares > 0 {
                missingQuote = true
            }
        }
        return (netInvestment, marketValue, missingQuote ? nil : marketValue - netInvestment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("人民币合计", systemImage: "yensign.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                Text("CNY")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let values = convertedValues {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        metric("净投入", value: StockValueFormatter.money(values.netInvestment, currencyCode: "CNY"))
                        metric("持仓市值", value: StockValueFormatter.money(values.marketValue, currencyCode: "CNY"))
                        metric("总盈亏", value: profitLossText(values.profitLoss), color: profitLossColor(values.profitLoss))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        metric("净投入", value: StockValueFormatter.money(values.netInvestment, currencyCode: "CNY"))
                        metric("持仓市值", value: StockValueFormatter.money(values.marketValue, currencyCode: "CNY"))
                        metric("总盈亏", value: profitLossText(values.profitLoss), color: profitLossColor(values.profitLoss))
                    }
                }
            } else {
                Label("美元买入价待同步", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if marketFilter != .aShare {
                if let rate = store.usdRenminbiBuyingRate {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按中国银行美元现汇买入价换算：1 USD = \(StockValueFormatter.exchangeRate(rate)) CNY")
                        if let updatedAt = store.exchangeRateUpdatedAt {
                            Text("牌价时间：\(updatedAt.formatted(date: .abbreviated, time: .standard))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let error = store.exchangeRateError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("A 股资产无需换汇。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private func metric(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profitLossText(_ value: Decimal?) -> String {
        value.map { StockValueFormatter.money($0, currencyCode: "CNY") } ?? "待同步"
    }

    private func profitLossColor(_ value: Decimal?) -> Color {
        guard let value else { return .secondary }
        return aggregateProfitLossColor(value)
    }

    private func aggregateProfitLossColor(_ value: Decimal) -> Color {
        switch marketFilter {
        case .aShare:
            return stockValueColor(value, market: .aShare, settings: stockAppearanceSettings)
        case .unitedStates:
            return stockValueColor(value, market: .unitedStates, settings: stockAppearanceSettings)
        case .all:
            return stockValueColor(value, market: .aShare, settings: stockAppearanceSettings)
        }
    }
}

private struct StockMarketSummaryRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let summary: StockPortfolioSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StockMarketBadge(market: summary.market)
                Text("\(summary.openPositionCount) 只持仓")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summary.market.currencyCode)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    summaryMetric("净投入", value: StockValueFormatter.money(summary.netInvestment, currencyCode: summary.market.currencyCode))
                    summaryMetric("持仓市值", value: marketValueText)
                    summaryMetric("总盈亏", value: profitLossText, color: profitLossColor)
                }
                VStack(alignment: .leading, spacing: 8) {
                    summaryMetric("净投入", value: StockValueFormatter.money(summary.netInvestment, currencyCode: summary.market.currencyCode))
                    summaryMetric("持仓市值", value: marketValueText)
                    summaryMetric("总盈亏", value: profitLossText, color: profitLossColor)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var marketValueText: String {
        summary.hasMissingQuotes
            ? "待同步"
            : StockValueFormatter.money(summary.knownMarketValue, currencyCode: summary.market.currencyCode)
    }

    private var profitLossText: String {
        guard let profitLoss = summary.profitLoss else { return "待同步" }
        return StockValueFormatter.money(profitLoss, currencyCode: summary.market.currencyCode)
    }

    private var profitLossColor: Color {
        guard let profitLoss = summary.profitLoss else { return .secondary }
        return stockValueColor(profitLoss, market: summary.market, settings: stockAppearanceSettings)
    }

    private func summaryMetric(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StockRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stock: StockHolding
    let quoteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stock.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(stock.symbol)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                StockMarketBadge(market: stock.market)
            }

            HStack {
                Text("持仓 \(StockValueFormatter.quantity(stock.currentShares)) 股")
                    .foregroundStyle(.secondary)
                Spacer()
                if let latestPrice = stock.latestPrice {
                    Text(StockValueFormatter.price(latestPrice, currencyCode: stock.market.currencyCode))
                        .monospacedDigit()
                    if let changePercent = stock.changePercent {
                        Text(StockValueFormatter.percent(changePercent))
                            .foregroundStyle(stockValueColor(changePercent, market: stock.market, settings: stockAppearanceSettings))
                            .monospacedDigit()
                    }
                } else {
                    Text(quoteError == nil ? "待同步" : "刷新失败")
                        .foregroundStyle(quoteError == nil ? Color.secondary : Color.orange)
                }
            }
            .font(.subheadline)

            HStack {
                Text("市值：\(marketValueText)")
                Spacer()
                Text("盈亏：\(profitLossText)")
                    .foregroundStyle(profitLossColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var marketValueText: String {
        guard let value = stock.marketValue else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var profitLossText: String {
        guard let value = stock.totalProfitLoss else { return "待同步" }
        return StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var profitLossColor: Color {
        guard let value = stock.totalProfitLoss else { return .secondary }
        return stockValueColor(value, market: stock.market, settings: stockAppearanceSettings)
    }
}

struct StockMarketBadge: View {
    let market: StockMarket

    private var color: Color {
        market == .aShare ? .purple : .teal
    }

    var body: some View {
        Text(market.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct StockDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stockID: UUID
    @State private var editingStock: StockHolding?
    @State private var editingTransaction: StockTransaction?
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
        .iOSLabeledBackButton("我的股票")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await store.refreshStockQuotes() }
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

                if auth.isAdmin, let stock {
                    Button { editingStock = stock } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("编辑股票")
                }
            }
        }
        .sheet(item: $editingStock) { stock in
            StockEditorView(stock: stock, isNew: false)
                .id(stock.id)
                .iOSLargeSheet()
        }
        .sheet(item: $editingTransaction) { transaction in
            if let stock {
                StockTransactionEditorView(transaction: transaction, stock: stock)
                    .id(transaction.id)
                    .iOSLargeSheet()
            }
        }
        .alert("无法删除交易", isPresented: $showingTransactionError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(transactionError)
        }
    }

    private func stockList(_ stock: StockHolding) -> some View {
        let sortedTransactions = stock.transactions.sorted { $0.tradedAt > $1.tradedAt }

        return List {
            Section("行情") {
                LabeledContent("市场") { StockMarketBadge(market: stock.market) }
                LabeledContent("股票代码", value: stock.symbol)
                if !stock.name.isEmpty {
                    LabeledContent("自定义名称", value: stock.name)
                }
                LabeledContent("最新价", value: stock.latestPrice.map { StockValueFormatter.price($0, currencyCode: stock.market.currencyCode) } ?? "待同步")
                if let previousClose = stock.previousClose {
                    LabeledContent("昨收", value: StockValueFormatter.price(previousClose, currencyCode: stock.market.currencyCode))
                }
                if let changePercent = stock.changePercent {
                    LabeledContent("涨跌幅") {
                        Text(StockValueFormatter.percent(changePercent))
                            .foregroundStyle(stockValueColor(changePercent, market: stock.market, settings: stockAppearanceSettings))
                    }
                }
                if let lastQuoteAt = stock.lastQuoteAt {
                    LabeledContent("更新时间", value: lastQuoteAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = store.quoteErrors[stock.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("持仓总览") {
                LabeledContent("当前持仓", value: "\(StockValueFormatter.quantity(stock.currentShares)) 股")
                LabeledContent("累计买入", value: StockValueFormatter.money(stock.totalBuyCost, currencyCode: stock.market.currencyCode))
                LabeledContent("累计卖出", value: StockValueFormatter.money(stock.totalSellProceeds, currencyCode: stock.market.currencyCode))
                LabeledContent("净投入", value: StockValueFormatter.money(stock.netInvestment, currencyCode: stock.market.currencyCode))
                LabeledContent("持仓市值", value: stock.marketValue.map { StockValueFormatter.money($0, currencyCode: stock.market.currencyCode) } ?? "待同步")
                LabeledContent("总盈亏") {
                    if let value = stock.totalProfitLoss {
                        Text(StockValueFormatter.money(value, currencyCode: stock.market.currencyCode))
                            .foregroundStyle(stockValueColor(value, market: stock.market, settings: stockAppearanceSettings))
                    } else {
                        Text("待同步").foregroundStyle(.secondary)
                    }
                }
            }

            Section("交易记录") {
                if sortedTransactions.isEmpty {
                    Text("暂无交易记录").foregroundStyle(.secondary)
                }
                if auth.isAdmin {
                    ForEach(sortedTransactions) { transaction in
                        Button { editingTransaction = transaction } label: {
                            StockTransactionRow(transaction: transaction, market: stock.market)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        deleteTransactions(at: offsets, sortedTransactions: sortedTransactions)
                    }
                    Button { editingTransaction = StockTransaction() } label: {
                        Label("添加买入或卖出记录", systemImage: "plus.circle")
                    }
                } else {
                    ForEach(sortedTransactions) { transaction in
                        StockTransactionRow(transaction: transaction, market: stock.market)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("\(StockValueFormatter.quantity(transaction.quantity)) 股 × \(StockValueFormatter.price(transaction.unitPrice, currencyCode: market.currencyCode))")
                    .font(.subheadline.monospacedDigit())
                Text(transaction.tradedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(StockValueFormatter.money(transaction.grossAmount, currencyCode: market.currencyCode))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if transaction.fees > 0 {
                    Text("费用 \(StockValueFormatter.money(transaction.fees, currencyCode: market.currencyCode))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
