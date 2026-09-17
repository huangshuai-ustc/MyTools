#if MYTOOLS_FEATURE_PARTNERSHIP
import SwiftUI
import Charts

enum PartnershipFormat {
    static func money(_ value: Decimal, currency: CurrencyCode = partnershipCurrency) -> String {
        value.formatted(.currency(code: currency.rawValue))
    }
}

struct PartnershipView: View {
    @EnvironmentObject private var store: PartnershipStore
    @State private var creating = false
    @State private var deleting: PartnershipBook?

    var body: some View {
        List {
            if store.books.isEmpty {
                ContentUnavailableView("还没有合伙账本", systemImage: "chart.pie.fill",
                                       description: Text("新建账本，记录成员出资与盈亏分配。"))
            }
            ForEach(store.books) { book in
                NavigationLink {
                    PartnershipDetailView(bookID: book.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.name).appFont(.headline)
                        Text(PartnershipFormat.money(PartnershipCalculator.stockSummary(book).cash))
                            .monospacedDigit()
                        Text("\(book.type.title) · \(book.members.count) 位成员 · 抽成/补偿 \(book.adjustmentRate.formatted(.percent))")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu { Button("删除账本", role: .destructive) { deleting = book } }
                .appDeleteSwipeAction { deleting = book }
                .appListRowStyle()
            }
        }
        .appNavigationTitle("合伙记账")
        .iOSLabeledBackButton("工具")
        .toolbar { Button { creating = true } label: { Label("新建账本", systemImage: "plus") } }
        .sheet(isPresented: $creating) { PartnershipCreateView().iOSLargeSheet() }
        .confirmationDialog("删除账本及其全部记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let deleting { store.delete(id: deleting.id) }; deleting = nil }
        }
    }
}
private enum PartnershipTab: Hashable { case overview, trades, flow }

private struct PartnershipDetailView: View {
    @EnvironmentObject private var store: PartnershipStore
    let bookID: UUID
    @State private var action: PartnershipAction?
    @State private var pagination = AppListPagination(pageSize: 30)
    @State private var undo = false
    @State private var error: String?
    @State private var selectedTab: PartnershipTab = .overview
    @State private var showingAdd = false

    var body: some View {
        Group {
            if let book = store.books.first(where: { $0.id == bookID }) {
                content(book)
                    .appNavigationTitle(book.name)
                    .toolbar { toolbarContent(book) }
            } else {
                ContentUnavailableView("账本已删除", systemImage: "book.closed")
            }
        }
        .sheet(item: $action) { item in
            NavigationStack {
                PartnershipActionView(bookID: bookID, action: item, finish: { action = nil })
            }
            .iOSLargeSheet()
        }
        .sheet(isPresented: $showingAdd) {
            PartnershipAddRecordView(bookID: bookID, finish: { showingAdd = false })
                .iOSLargeSheet()
        }
        .alert("确认撤回最近一次修改？", isPresented: $undo) {
            Button("撤回", role: .destructive) {
                do { try store.undoLatestChange(bookID: bookID) } catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("相关计算将恢复至修改前；随后可通过“取消撤回”恢复这次修改。")
        }
        .alert("无法撤销", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("确定", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ book: PartnershipBook) -> some ToolbarContent {
        switch selectedTab {
        case .overview:
            ToolbarItem {
                Menu {
                    Button("清账收益池") { action = .settle }
                    Button("修改账本名称") { action = .rename }
                } label: { Label("账本操作", systemImage: "ellipsis.circle") }
            }
        case .trades:
            ToolbarItem {
                Button { showingAdd = true } label: { Label("新增记录", systemImage: "plus") }
            }
        case .flow:
            ToolbarItem {
                Button { showingAdd = true } label: { Label("新增记录", systemImage: "plus") }
            }
            ToolbarItem {
                Menu {
                    NavigationLink("操作记录") { PartnershipAuditLogView(bookID: bookID) }
                    Button("撤销最近一次修改", role: .destructive) { undo = true }
                        .disabled(book.records.count <= 2)
                    Button("取消撤回") {
                        do { try store.cancelUndoLatestChange(bookID: bookID) } catch { self.error = error.localizedDescription }
                    }
                    .disabled(!store.canCancelUndo(bookID: bookID))
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
    }

    private func content(_ book: PartnershipBook) -> some View {
        TabView(selection: $selectedTab) {
            overviewTab(book)
                .tag(PartnershipTab.overview)
                .tabItem { Label("总览", systemImage: "chart.pie") }
            tradesTab(book)
                .tag(PartnershipTab.trades)
                .tabItem { Label("交易", systemImage: "chart.line.uptrend.xyaxis") }
            flowTab(book)
                .tag(PartnershipTab.flow)
                .tabItem { Label("流水", systemImage: "list.bullet.rectangle") }
        }
    }

    private func overviewTab(_ book: PartnershipBook) -> some View {
        let stockSummary = PartnershipCalculator.stockSummary(book)
        let availableCashItems = stockSummary.memberAvailableCash.enumerated().map { index, allocation in
            PartnershipEquityChartItem(
                memberID: allocation.memberID,
                name: book.members.first { $0.id == allocation.memberID }?.name ?? "成员",
                amount: allocation.actual,
                color: equityColor(at: index)
            )
        }
        let profitItems = stockSummary.memberProfits.enumerated().map { index, allocation in
            PartnershipEquityChartItem(
                memberID: allocation.memberID,
                name: book.members.first { $0.id == allocation.memberID }?.name ?? "成员",
                amount: allocation.actual,
                color: equityColor(at: index)
            )
        }
        return List {
            Section("账户概览与成员权益") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("可用资金").appFont(.caption).foregroundStyle(.secondary)
                            Text(PartnershipFormat.money(stockSummary.cash))
                                .appFont(.title2).fontWeight(.semibold).monospacedDigit()
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("已实现盈亏").appFont(.caption).foregroundStyle(.secondary)
                            Text(PartnershipFormat.money(stockSummary.realizedProfit))
                                .fontWeight(.medium).monospacedDigit()
                                .foregroundStyle(stockSummary.realizedProfit == 0 ? Color.secondary : (stockSummary.realizedProfit > 0 ? Color.red : Color.green))
                        }
                    }
                    HStack {
                        Label(book.currency.title, systemImage: "banknote")
                        Spacer()
                        Label("持仓 \(stockSummary.positions.count) 只", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .appFont(.caption)
                    .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 16) {
                        PartnershipDistributionChart(title: "可用资金占比", items: availableCashItems)
                        PartnershipDistributionChart(title: "当前盈利分成", items: profitItems)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func tradesTab(_ book: PartnershipBook) -> some View {
        List {
            Section("持仓与交易") {
                if stockItems(book: book).isEmpty {
                    Text("还没有买入记录").foregroundStyle(.secondary)
                }
                ForEach(stockItems(book: book)) { item in
                    NavigationLink {
                        PartnershipStockRecordDetailView(bookID: book.id, symbol: item.symbol)
                    } label: {
                        HStack(spacing: 12) {
                            PartnershipSymbolBadge(symbol: item.symbol)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(item.name) · \(item.symbol)").fontWeight(.medium)
                                Text(item.shares > 0
                                     ? "成本 \(PartnershipFormat.money(item.cost)) · \(item.purchaseCount) 笔买入"
                                     : "\(item.purchaseCount) 笔买入 · 已全部卖出")
                                    .appFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.shares > 0 {
                                Text("\(item.shares) 股").monospacedDigit()
                            } else {
                                Text("已清仓").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func flowTab(_ book: PartnershipBook) -> some View {
        let sorted = book.records.sorted {
            $0.date != $1.date ? $0.date > $1.date : ($0.recordedAt ?? $0.date) > ($1.recordedAt ?? $1.date)
        }
        let records = pagination.visibleItems(from: sorted)
        return List {
            Section("资金流水（最新在前）") {
                if records.isEmpty {
                    Text("暂无流水").foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    PartnershipRecordRow(book: book, record: record)
                        .onAppear {
                            pagination.loadMoreIfNeeded(currentItemID: record.id, lastVisibleItemID: records.last?.id, totalItemCount: book.records.count)
                        }
                }
            }
        }
    }

    private func stockItems(book: PartnershipBook) -> [PartnershipStockListItem] {
        let purchases = book.records.filter(\.isPurchase)
        let groups = Dictionary(grouping: purchases, by: \.symbol)
        let positions = PartnershipCalculator.stockSummary(book).positions
        return groups.values.map { records in
            let first = records[0]
            let position = positions.first { $0.symbol == first.symbol }
            return PartnershipStockListItem(
                symbol: first.symbol,
                name: records.last?.name ?? first.symbol,
                shares: position?.shares ?? 0,
                cost: position?.cost ?? 0,
                purchaseCount: records.count,
                latestDate: records.map(\.date).max() ?? .distantPast
            )
        }.sorted { $0.latestDate > $1.latestDate }
    }

    private func equityColor(at index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .indigo, .yellow]
        return colors[index % colors.count]
    }
}
private struct PartnershipKindTag: View {
    let kind: PartnershipRecordKind

    private var color: Color {
        switch kind {
        case .contribution: .green
        case .withdrawal: .orange
        case .buy: .blue
        case .sell: .red
        case .dividend: .teal
        case .settlement: .purple
        }
    }

    var body: some View {
        Text(kind.title)
            .appFont(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Circular monogram avatar for a stock, giving each holding a stable color.
private struct PartnershipSymbolBadge: View {
    let symbol: String
    var size: CGFloat = 38

    private let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .indigo, .teal]
    private var color: Color {
        let sum = symbol.uppercased().unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[palette.isEmpty ? 0 : sum % palette.count]
    }
    private var monogram: String { String(symbol.uppercased().prefix(2)) }

    var body: some View {
        Text(monogram)
            .appFont(.caption.weight(.bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: Circle())
    }
}

/// Small circular icon badge used to give each ledger record a glanceable glyph.
private struct PartnershipKindIcon: View {
    let kind: PartnershipRecordKind
    var size: CGFloat = 32

    private var config: (symbol: String, color: Color) {
        switch kind {
        case .contribution: ("plus", .green)
        case .withdrawal: ("minus", .orange)
        case .buy: ("cart.fill", .blue)
        case .sell: ("banknote.fill", .red)
        case .dividend: ("gift.fill", .teal)
        case .settlement: ("checkmark.seal.fill", .purple)
        }
    }

    var body: some View {
        Image(systemName: config.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(config.color)
            .frame(width: size, height: size)
            .background(config.color.opacity(0.15), in: Circle())
    }
}

private struct PartnershipRecordRow: View {
    let book: PartnershipBook
    let record: PartnershipRecord

    private var headlineAmount: Decimal {
        switch record.kind {
        case .contribution, .withdrawal: record.amount
        case .buy, .sell: record.cashAmount
        case .dividend: record.dividendNet
        case .settlement: record.settlementChoices.reduce(Decimal.zero) { $0 + $1.amount }
        }
    }
    // Signed headline: expense (买入/取出) shows as negative, the rest as positive.
    private var amountText: String {
        let money = PartnershipFormat.money(headlineAmount)
        switch record.kind {
        case .buy, .withdrawal: return "-\(money)"
        case .contribution, .sell, .dividend, .settlement: return money
        }
    }
    private var titleLine: String? {
        switch record.kind {
        case .contribution, .withdrawal:
            book.members.first { $0.id == record.memberID }?.name
        case .buy, .sell, .dividend:
            "\(record.name) · \(record.symbol)"
        case .settlement:
            "\(record.settlementChoices.count) 位成员"
        }
    }

    /// 成员冻结分配比例（按各自 |actual| 占比）。
    private func ratioText(_ allocations: [PartnershipAllocation]) -> String? {
        let total = allocations.reduce(Decimal.zero) { $0 + abs($1.actual) }
        guard total > 0 else { return nil }
        let parts = allocations.map { allocation -> String in
            let name = book.members.first { $0.id == allocation.memberID }?.name ?? "成员"
            let ratio = abs(allocation.actual) / total
            return "\(name) \(ratio.formatted(.percent.precision(.fractionLength(0))))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private var detailParts: [String] {
        var parts: [String] = [record.date.formatted(date: .abbreviated, time: .omitted)]
        switch record.kind {
        case .buy:
            parts.append("\(record.shares) 股")
            if let ratio = ratioText(record.allocations) { parts.append(ratio) }
        case .sell:
            parts.append("\(record.shares) 股")
            if let ratio = ratioText(record.allocations) { parts.append(ratio) }
            parts.append("抽成/补偿 \(book.adjustmentRate.formatted(.percent))")
        case .dividend:
            if let ratio = ratioText(record.allocations) { parts.append(ratio) }
        case .settlement:
            let choices = record.settlementChoices.map { choice -> String in
                let name = book.members.first { $0.id == choice.memberID }?.name ?? "成员"
                return "\(name) \(choice.reinvest ? "重投" : "取回")"
            }
            if !choices.isEmpty { parts.append(choices.joined(separator: " / ")) }
            parts.append("抽成/补偿 \(book.adjustmentRate.formatted(.percent))")
        case .contribution, .withdrawal:
            if !record.note.isEmpty { parts.append(record.note) }
        }
        return parts
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PartnershipKindIcon(kind: record.kind)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PartnershipKindTag(kind: record.kind)
                    if let titleLine {
                        Text(titleLine).lineLimit(1)
                    }
                    Spacer()
                    Text(amountText).monospacedDigit()
                }
                Text(detailParts.joined(separator: " · "))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PartnershipEquityChartItem: Identifiable {
    var id: UUID { memberID }
    var memberID: UUID
    var name: String
    var amount: Decimal
    var color: Color
}

private struct PartnershipDistributionChart: View {
    let title: String
    let items: [PartnershipEquityChartItem]

    private var hasValues: Bool { items.contains { $0.amount != 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).appFont(.caption).foregroundStyle(.secondary)
            Group {
                if hasValues {
                    Chart(items) { item in
                        SectorMark(
                            angle: .value(title, NSDecimalNumber(decimal: abs(item.amount)).doubleValue),
                            innerRadius: .ratio(0.58),
                            angularInset: 2
                        )
                        .cornerRadius(4)
                        .foregroundStyle(item.color)
                    }
                    .chartLegend(.hidden)
                } else {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 22)
                        Text("暂无").appFont(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            .frame(height: 128)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(items) { item in
                    HStack(spacing: 5) {
                        Circle().fill(item.color).frame(width: 8, height: 8)
                        Text(item.name)
                        Text(PartnershipFormat.money(item.amount))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .appFont(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PartnershipStockListItem: Identifiable {
    var id: String { symbol }
    var symbol: String
    var name: String
    var shares: Decimal
    var cost: Decimal
    var purchaseCount: Int
    var latestDate: Date
}

private struct PartnershipAuditLogView: View {
    @EnvironmentObject private var store: PartnershipStore
    let bookID: UUID

    var body: some View {
        Group {
            if let book = store.books.first(where: { $0.id == bookID }) {
                List {
                    if book.auditLog.isEmpty {
                        ContentUnavailableView("暂无操作记录", systemImage: "clock.arrow.circlepath")
                    }
                    ForEach(book.auditLog.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.action)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .appNavigationTitle("操作记录")
            } else {
                ContentUnavailableView("账本已删除", systemImage: "book.closed")
            }
        }
    }
}
private struct PartnershipStockRecordDetailView: View {
    @EnvironmentObject private var store: PartnershipStore
    let bookID: UUID
    let symbol: String

    var body: some View {
        Group {
            if let book = store.books.first(where: { $0.id == bookID }) {
                content(book)
            } else {
                ContentUnavailableView("账本已删除", systemImage: "book.closed")
            }
        }
    }

    private func content(_ book: PartnershipBook) -> some View {
        let purchases = book.records
            .filter { $0.isPurchase && $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }
            .sorted { $0.date > $1.date }
        let dividends = book.records
            .filter { $0.kind == .dividend && $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }
            .sorted { $0.date > $1.date }
        let name = purchases.first?.name ?? symbol
        return List {
            ForEach(purchases) { purchase in
                let sales = matchedSales(for: purchase, in: book)
                let soldShares = sales.reduce(Decimal.zero) { sum, sale in
                    sum + sale.saleMatches.filter { $0.purchaseID == purchase.id }.reduce(Decimal.zero) { $0 + $1.shares }
                }
                let remaining = max(0, purchase.shares - soldShares)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            PartnershipKindIcon(kind: .buy)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("买入 \(purchase.shares) 股 @ \(PartnershipFormat.money(purchase.price))")
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(PartnershipFormat.money(purchase.cashAmount)).monospacedDigit()
                                }
                                Text(buySubtitle(purchase: purchase, remaining: remaining))
                                    .appFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(sales.enumerated()), id: \.element.id) { index, sale in
                            let shares = sale.saleMatches.filter { $0.purchaseID == purchase.id }.reduce(Decimal.zero) { $0 + $1.shares }
                            let profit = sale.allocations.reduce(Decimal.zero) { $0 + $1.actual }
                            HStack(alignment: .top, spacing: 8) {
                                PartnershipTreeConnector(isLast: index == sales.count - 1)
                                    .frame(width: 16)
                                PartnershipKindIcon(kind: .sell, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("卖出 \(shares) 股 @ \(PartnershipFormat.money(sale.price))")
                                        Spacer()
                                        Text(PartnershipFormat.money(profit))
                                            .monospacedDigit()
                                            .foregroundStyle(profit == 0 ? Color.secondary : (profit > 0 ? Color.red : Color.green))
                                    }
                                    Text(sellSubtitle(sale: sale))
                                        .appFont(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if !dividends.isEmpty {
                Section("股息") {
                    ForEach(dividends) { dividend in
                        HStack {
                            Text(dividend.date.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(PartnershipFormat.money(dividend.dividendNet))
                                .monospacedDigit().foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .appNavigationTitle(name)
    }

    private func matchedSales(for purchase: PartnershipRecord, in book: PartnershipBook) -> [PartnershipRecord] {
        book.records
            .filter { $0.isSale && $0.saleMatches.contains { $0.purchaseID == purchase.id } }
            .sorted { $0.date < $1.date }
    }

    /// Buy caption: remaining shares + date, plus the buy fee folded into cost when present.
    private func buySubtitle(purchase: PartnershipRecord, remaining: Decimal) -> String {
        var parts = ["剩余 \(remaining > 0 ? "\(remaining) 股" : "已清仓")",
                     purchase.date.formatted(date: .abbreviated, time: .omitted)]
        if purchase.fee > 0 { parts.append("含手续费 \(PartnershipFormat.money(purchase.fee))") }
        return parts.joined(separator: " · ")
    }

    /// Sell caption: date, plus the sell fee already deducted from proceeds when present.
    private func sellSubtitle(sale: PartnershipRecord) -> String {
        var parts = [sale.date.formatted(date: .abbreviated, time: .omitted)]
        if sale.fee > 0 { parts.append("手续费 \(PartnershipFormat.money(sale.fee))") }
        return parts.joined(separator: " · ")
    }
}

/// Draws the ├ / └ elbow that connects an indented sell row back to its parent
/// buy record. The vertical runs full height for middle rows and stops at the
/// elbow for the last one.
private struct PartnershipTreeConnector: View {
    let isLast: Bool

    var body: some View {
        GeometryReader { geo in
            let midX = geo.size.width / 2
            let elbowY: CGFloat = 11
            Path { path in
                path.move(to: CGPoint(x: midX, y: 0))
                path.addLine(to: CGPoint(x: midX, y: isLast ? elbowY : geo.size.height))
                path.move(to: CGPoint(x: midX, y: elbowY))
                path.addLine(to: CGPoint(x: geo.size.width, y: elbowY))
            }
            .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}

#endif
