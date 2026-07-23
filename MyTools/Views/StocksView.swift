import SwiftUI

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

struct StocksView: View {
    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var marketFilter: StockMarketFilter = .all
    @State private var editingStock: StockHolding?

    private var displayedStocks: [StockHolding] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.stocks
            .filter(marketFilter.includes)
            .filter { stock in
                searchTerm.isEmpty
                    || stock.symbol.localizedCaseInsensitiveContains(searchTerm)
                    || stock.displayName.localizedCaseInsensitiveContains(searchTerm)
            }
            .sorted { lhs, rhs in
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return comparison == .orderedSame
                    ? lhs.symbol.localizedStandardCompare(rhs.symbol) == .orderedAscending
                    : comparison == .orderedAscending
            }
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
                Text("行情由东方财富公开接口提供，可能存在延迟，请以交易所和券商数据为准。")
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
                Button {
                    Task { await store.refreshStockQuotes() }
                } label: {
                    if store.isRefreshingQuotes {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshingQuotes || store.stocks.isEmpty)
                .accessibilityLabel("刷新股票行情")

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
                try? await Task.sleep(for: .seconds(60))
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

private struct StockMarketSummaryRow: View {
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
        return profitLoss >= 0 ? .green : .red
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
                            .foregroundStyle(changePercent >= 0 ? .green : .red)
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
        return value >= 0 ? .green : .red
    }
}

struct StockMarketBadge: View {
    let market: StockMarket

    private var color: Color {
        market == .aShare ? .red : .blue
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
    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
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
                            .foregroundStyle(changePercent >= 0 ? .green : .red)
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
                            .foregroundStyle(value >= 0 ? .green : .red)
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

private final class StockEditorDraft: ObservableObject {
    @Published var stock: StockHolding
    @Published var symbolText: String
    @Published var nameText: String
    @Published var initialTradedAt = Date()
    @Published var quantityText = ""
    @Published var unitPriceText = ""
    @Published var feesText = ""

    init(stock: StockHolding) {
        self.stock = stock
        symbolText = stock.symbol
        nameText = stock.name
    }
}

private struct StockEditorView: View {
    private enum Field: Hashable {
        case symbol, name, quantity, price, fees
    }

    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: StockEditorDraft
    @FocusState private var focusedField: Field?
    @State private var errorMessage = ""
    @State private var showingError = false
    @State private var showingAuthentication = false
    let isNew: Bool
    private let originalSymbol: String

    init(stock: StockHolding, isNew: Bool) {
        _draft = StateObject(wrappedValue: StockEditorDraft(stock: stock))
        self.isNew = isNew
        originalSymbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("股票信息") {
                    Picker("股票市场", selection: $draft.stock.market) {
                        ForEach(StockMarket.allCases) { market in
                            Text(market.title).tag(market)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!isNew)
                    LabeledContent("股票代码：") {
                        TextField(draft.stock.market == .aShare ? "例如 600519" : "例如 AAPL", text: $draft.symbolText)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .symbol)
                            .onSubmit { focusedField = .name }
#if os(iOS)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
#endif
                    }
                    LabeledContent("股票名称：") {
                        TextField("可选", text: $draft.nameText)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .name)
                            .onSubmit { if isNew { focusedField = .quantity } }
                    }
                }

                if isNew {
                    Section("首次买入") {
                        DatePicker(
                            "购买时间：",
                            selection: $draft.initialTradedAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        decimalField("购买股数：", placeholder: "必填", text: $draft.quantityText, field: .quantity)
                        decimalField("每股价格：", placeholder: "必填", text: $draft.unitPriceText, field: .price)
                        decimalField("交易费用：", placeholder: "可选", text: $draft.feesText, field: .fees)
                    }
                }
            }
            .navigationTitle(isNew ? "添加股票" : "编辑股票")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView()
                    .iOSLargeSheet()
            }
            .alert("无法保存", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func decimalField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
        }
    }

    private func requestSave() {
        commitPendingTextInput {
            save()
        }
    }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }

        var stock = draft.stock
        stock.symbol = StockHolding.normalizedSymbol(draft.symbolText, market: stock.market)
        stock.name = draft.nameText
        guard validSymbol(stock.symbol, market: stock.market) else {
            reportError(stock.market == .aShare ? "A 股代码需要填写 6 位数字。" : "请填写有效的美股代码。")
            return
        }
        guard !store.stockExists(market: stock.market, symbol: stock.symbol, excluding: stock.id) else {
            reportError("该市场中已经添加了这只股票。")
            return
        }

        if isNew {
            guard let quantity = decimal(from: draft.quantityText), quantity > 0,
                  let unitPrice = decimal(from: draft.unitPriceText), unitPrice > 0 else {
                reportError("购买股数和每股价格必须大于零。")
                return
            }
            guard let fees = optionalDecimal(from: draft.feesText) else {
                reportError("请输入有效的交易费用。")
                return
            }
            guard fees >= 0 else {
                reportError("交易费用不能小于零。")
                return
            }
            stock.transactions = [StockTransaction(
                type: .buy,
                tradedAt: draft.initialTradedAt,
                quantity: quantity,
                unitPrice: unitPrice,
                fees: fees
            )]
        } else if stock.symbol != originalSymbol {
            stock.latestPrice = nil
            stock.previousClose = nil
            stock.changePercent = nil
            stock.quoteName = ""
            stock.lastQuoteAt = nil
        }

        store.upsertStock(stock)
        Task { await store.refreshStockQuotes() }
        dismiss()
    }

    private func validSymbol(_ symbol: String, market: StockMarket) -> Bool {
        guard !symbol.isEmpty else { return false }
        if market == .aShare {
            return symbol.count == 6 && symbol.allSatisfy(\.isNumber)
        }
        return symbol.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    private func decimal(from text: String) -> Decimal? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        guard !normalized.isEmpty else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func optionalDecimal(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? 0 : decimal(from: trimmed)
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

private final class StockTransactionEditorDraft: ObservableObject {
    @Published var transaction: StockTransaction
    @Published var quantityText: String
    @Published var unitPriceText: String
    @Published var feesText: String

    init(transaction: StockTransaction) {
        self.transaction = transaction
        quantityText = transaction.quantity == 0 ? "" : NSDecimalNumber(decimal: transaction.quantity).stringValue
        unitPriceText = transaction.unitPrice == 0 ? "" : NSDecimalNumber(decimal: transaction.unitPrice).stringValue
        feesText = transaction.fees == 0 ? "" : NSDecimalNumber(decimal: transaction.fees).stringValue
    }
}

private struct StockTransactionEditorView: View {
    private enum Field: Hashable {
        case quantity, price, fees
    }

    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: StockTransactionEditorDraft
    @FocusState private var focusedField: Field?
    @State private var errorMessage = ""
    @State private var showingError = false
    @State private var showingAuthentication = false
    let stock: StockHolding

    init(transaction: StockTransaction, stock: StockHolding) {
        _draft = StateObject(wrappedValue: StockTransactionEditorDraft(transaction: transaction))
        self.stock = stock
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("交易") {
                    Picker("交易类型", selection: $draft.transaction.type) {
                        ForEach(StockTransactionType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    DatePicker(
                        "交易时间：",
                        selection: $draft.transaction.tradedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    decimalField("交易股数：", placeholder: "必填", text: $draft.quantityText, field: .quantity)
                    decimalField("每股价格：", placeholder: "必填", text: $draft.unitPriceText, field: .price)
                    decimalField("交易费用：", placeholder: "可选", text: $draft.feesText, field: .fees)
                }

                Section {
                    LabeledContent("当前持仓", value: "\(StockValueFormatter.quantity(stock.currentShares)) 股")
                    LabeledContent("结算币种", value: stock.market.currencyCode)
                }
            }
            .navigationTitle(draft.transaction.type == .buy ? "买入记录" : "卖出记录")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView()
                    .iOSLargeSheet()
            }
            .alert("无法保存", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func decimalField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
        }
    }

    private func requestSave() {
        commitPendingTextInput {
            save()
        }
    }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        guard let quantity = decimal(from: draft.quantityText), quantity > 0,
              let unitPrice = decimal(from: draft.unitPriceText), unitPrice > 0 else {
            reportError("交易股数和每股价格必须大于零。")
            return
        }
        guard let fees = optionalDecimal(from: draft.feesText) else {
            reportError("请输入有效的交易费用。")
            return
        }
        guard fees >= 0 else {
            reportError("交易费用不能小于零。")
            return
        }

        var transaction = draft.transaction
        transaction.quantity = quantity
        transaction.unitPrice = unitPrice
        transaction.fees = fees
        guard store.upsertStockTransaction(transaction, in: stock.id) else {
            reportError("这笔卖出会使持仓股数小于零，请检查交易股数。")
            return
        }
        dismiss()
    }

    private func decimal(from text: String) -> Decimal? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        guard !normalized.isEmpty else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func optionalDecimal(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? 0 : decimal(from: trimmed)
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
