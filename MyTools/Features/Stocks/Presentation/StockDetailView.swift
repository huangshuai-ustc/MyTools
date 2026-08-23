#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

struct StockDetailView: View {
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

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stockID: UUID
    @State private var editorRoute: EditorRoute?
    @State private var showingStockWatch = false
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
            ToolbarItem(placement: .principal) {
                if let stock {
                    Button {
                        showingStockWatch = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(stock.displayName)
                                .lineLimit(1)
                            Image(systemName: "chart.xyaxis.line")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看\(stock.displayName)行情")
                    .help("查看股票行情")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await store.refreshQuotes(
                            for: stock?.market,
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

                if auth.isEditSessionReady, let stock {
                    Button { editorRoute = .stock(stock) } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("编辑股票")
                }
            }
        }
        .navigationDestination(isPresented: $showingStockWatch) {
            StockWatchView(stockID: stockID)
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
                StockQuoteOverview(
                    stock: stock,
                    quoteSource: store.quoteSources[stock.id],
                    quoteError: store.quoteErrors[stock.id],
                    appearanceSettings: stockAppearanceSettings
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("持仓总览") {
                StockHoldingOverview(
                    stock: stock,
                    appearanceSettings: stockAppearanceSettings
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
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
                        .appDeleteSwipeAction(isEnabled: auth.isEditSessionReady) {
                            deleteTransaction(id: transaction.id, from: sortedTransactions)
                        }
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
                        .appDeleteSwipeAction(isEnabled: auth.isEditSessionReady) {
                            deleteDividend(id: dividend.id, from: sortedDividends)
                        }
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

    private func deleteTransactions(ids: Set<UUID>) {
        guard store.deleteTransactions(ids: ids, from: stockID) else {
            transactionError = "删除这些记录后持仓股数会小于零，请先调整相应的卖出记录。"
            showingTransactionError = true
            return
        }
    }

    private func deleteTransaction(id: UUID, from transactions: [StockTransaction]) {
        guard transactions.contains(where: { $0.id == id }) else { return }
        deleteTransactions(ids: [id])
    }

    private func deleteDividends(ids: Set<UUID>) {
        store.deleteDividends(ids: ids, from: stockID)
    }

    private func deleteDividend(id: UUID, from dividends: [StockDividend]) {
        guard dividends.contains(where: { $0.id == id }) else { return }
        deleteDividends(ids: [id])
    }
}

private struct StockQuoteOverview: View {
    let stock: StockHolding
    let quoteSource: String?
    let quoteError: String?
    let appearanceSettings: StockAppearanceSettings

    private var changeColor: Color {
        guard let changePercent = stock.changePercent else { return .secondary }
        return StockTrendColor.color(
            for: changePercent,
            market: stock.market,
            settings: appearanceSettings
        )
    }

    private var changeAmount: Decimal? {
        guard let latestPrice = stock.latestPrice,
              let previousClose = stock.previousClose else { return nil }
        return latestPrice - previousClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最新价")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(stock.latestPrice.map {
                        StockValueFormatter.price($0, currencyCode: stock.market.currencyCode)
                    } ?? "待同步")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("今日涨跌")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let changePercent = stock.changePercent {
                        HStack(spacing: 6) {
                            if let changeAmount {
                                Text(StockValueFormatter.price(
                                    changeAmount,
                                    currencyCode: stock.market.currencyCode
                                ))
                            }
                            Text(StockValueFormatter.signedPercent(changePercent))
                        }
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(changeColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    } else {
                        Text("待同步")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                StockDetailMetricCell(title: "市场", value: stock.market.title)
                StockDetailMetricCell(title: "股票代码", value: stock.symbol)
                if !stock.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    StockDetailMetricCell(title: "自定义名称", value: stock.name)
                }
                if let lastQuoteAt = stock.lastQuoteAt {
                    StockDetailMetricCell(
                        title: "更新时间",
                        value: AppDateFormatter.string(from: lastQuoteAt)
                    )
                }
                if let quoteSource {
                    StockDetailMetricCell(title: "行情来源", value: quoteSource)
                }
            }

            if let quoteError {
                Label(quoteError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct StockHoldingOverview: View {
    let stock: StockHolding
    let appearanceSettings: StockAppearanceSettings

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            alignment: .leading,
            spacing: 14
        ) {
            StockDetailMetricCell(
                title: "持仓",
                value: "\(StockValueFormatter.integerQuantity(stock.currentShares)) 股"
            )
            StockDetailMetricCell(
                title: "持仓成本",
                value: StockValueFormatter.money(
                    stock.holdingCost,
                    currencyCode: stock.market.currencyCode
                )
            )
            StockDetailMetricCell(
                title: "单股成本",
                value: stock.averageHoldingCost.map {
                    StockValueFormatter.price($0, currencyCode: stock.market.currencyCode)
                } ?? "无持仓"
            )
            StockDetailMetricCell(
                title: "持仓市值",
                value: stock.marketValue.map {
                    StockValueFormatter.money($0, currencyCode: stock.market.currencyCode)
                } ?? "待同步"
            )
            StockDetailMetricCell(
                title: "持仓盈亏",
                value: stock.holdingProfitLoss.map {
                    StockValueFormatter.money($0, currencyCode: stock.market.currencyCode)
                } ?? "待同步",
                color: color(for: stock.holdingProfitLoss)
            )
            StockDetailMetricCell(
                title: "盈亏率",
                value: stock.holdingProfitRate.map(StockValueFormatter.signedPercent) ?? "待同步",
                color: color(for: stock.holdingProfitRate)
            )
            StockDetailMetricCell(
                title: "累计买入",
                value: StockValueFormatter.money(
                    stock.totalBuyCost,
                    currencyCode: stock.market.currencyCode
                )
            )
            StockDetailMetricCell(
                title: "已变现（含分红）",
                value: StockValueFormatter.money(
                    stock.realizedProfitLoss,
                    currencyCode: stock.market.currencyCode
                ),
                color: color(stock.realizedProfitLoss)
            )
            StockDetailMetricCell(
                title: "累计总收益",
                value: stock.totalProfitLoss.map {
                    StockValueFormatter.money($0, currencyCode: stock.market.currencyCode)
                } ?? "待同步",
                color: color(for: stock.totalProfitLoss)
            )
        }
    }

    private func color(for value: Decimal?) -> Color {
        guard let value else { return .secondary }
        return StockTrendColor.color(
            for: value,
            market: stock.market,
            settings: appearanceSettings
        )
    }

    private func color(_ value: Decimal) -> Color {
        StockTrendColor.color(
            for: value,
            market: stock.market,
            settings: appearanceSettings
        )
    }
}

private struct StockDetailMetricCell: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
    @EnvironmentObject private var store: StockStore
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
        guard store.reorderTransactions(orderedIDs, in: stockID) else {
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

#endif
