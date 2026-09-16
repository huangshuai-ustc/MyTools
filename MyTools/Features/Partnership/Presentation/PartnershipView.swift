#if MYTOOLS_FEATURE_PARTNERSHIP
import SwiftUI
import Charts

enum PartnershipFormat {
    static func money(_ value: Decimal, currency: CurrencyCode) -> String {
        value.formatted(.currency(code: currency.rawValue))
    }
}

struct PartnershipView: View {
    @EnvironmentObject private var store: PartnershipStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false
    @State private var verifying = false
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
                        Text(PartnershipFormat.money(PartnershipCalculator.summary(book).netValue, currency: book.currency))
                            .monospacedDigit()
                        Text("\(book.members.count) 位成员 · 调整比例 \(book.adjustmentRate.formatted(.percent))")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu { Button("删除账本", role: .destructive) { deleting = book } }
                .appDeleteSwipeAction { deleting = book }
                .appListRowStyle()
            }
        }
        .redacted(reason: revealed ? [] : .privacy)
        .disabled(!revealed)
        .overlay {
            if !revealed {
                Rectangle().fill(.background).overlay {
                    VStack(spacing: 16) {
                        Label("验证身份后查看合伙账本", systemImage: "lock.shield")
                        Button(verifying ? "正在验证…" : "解锁") {
                            verifying = true
                            Task {
                                revealed = await auth.verifyWithBiometrics(reason: "查看合伙净值与成员资金")
                                verifying = false
                            }
                        }.disabled(verifying)
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { revealed = false; creating = false; deleting = nil }
        }
        .appNavigationTitle("合伙净值")
        .iOSLabeledBackButton("工具")
        .toolbar { Button { creating = true } label: { Label("新建账本", systemImage: "plus") }.disabled(!revealed) }
        .sheet(isPresented: $creating) { PartnershipCreateView().iOSLargeSheet() }
        .confirmationDialog("删除账本及其全部记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let deleting { store.delete(id: deleting.id) }; deleting = nil }
        }
    }
}

private struct PartnershipDetailView: View {
    @EnvironmentObject private var store: PartnershipStore
    let bookID: UUID
    @State private var action: PartnershipAction?
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var needsUnlock = false
    @State private var pagination = AppListPagination(pageSize: 30)
    @State private var undo = false
    @State private var error: String?

    var body: some View {
        Group {
            if let book = store.books.first(where: { $0.id == bookID }) {
                content(book)
                    .appNavigationTitle(book.name)
                    .toolbar {
                        Menu {
                            ForEach(PartnershipAction.allCases) { item in
                                Button(item.title) { action = item }
                            }
                            Button("撤销最后一笔", role: .destructive) { undo = true }
                                .disabled(book.entries.count <= 2)
                        } label: { Label("账本操作", systemImage: "ellipsis.circle") }
                    }
            } else {
                ContentUnavailableView("账本已删除", systemImage: "book.closed")
            }
        }
        .disabled(needsUnlock)
        .overlay {
            if needsUnlock {
                Rectangle().fill(.background).overlay {
                    Button("验证身份后继续查看") {
                        Task { needsUnlock = !(await auth.verifyWithBiometrics(reason: "查看合伙账本")) }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { needsUnlock = true; action = nil; undo = false }
        }
        .sheet(item: $action) { item in
            PartnershipActionView(bookID: bookID, action: item).iOSLargeSheet()
        }
        .confirmationDialog("撤销最后一笔记录？历史分配将恢复至该笔之前。", isPresented: $undo) {
            Button("撤销", role: .destructive) {
                do { try store.undoLast(bookID: bookID) } catch { self.error = error.localizedDescription }
            }
        }
        .alert("无法撤销", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("确定", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func content(_ book: PartnershipBook) -> some View {
        let summary = PartnershipCalculator.summary(book)
        let entries = pagination.visibleItems(from: Array(book.entries.reversed()))
        return List {
            Section("账户概览") {
                row("当前净值", summary.netValue, book)
                row("累计注资", summary.contributed, book)
                row("累计取出", summary.withdrawn, book)
                row("累计已结盈亏", summary.settledProfit, book)
                row("待结算盈亏", summary.pendingProfit, book)
            }
            Section {
                Button("按当前比例注资") { action = .proportional }
                Button("单人注资") { action = .contribution }
                Button("记录盈亏") { action = .settlement }
                Button("更新净值") { action = .valuation }
            }
            Section("成员权益") {
                Chart(summary.positions) { position in
                    SectorMark(angle: .value("权益", NSDecimalNumber(decimal: max(0, position.equity)).doubleValue),
                               innerRadius: .ratio(0.6), angularInset: 2)
                        .foregroundStyle(by: .value("成员", position.name))
                }.frame(height: 180)
                ForEach(summary.positions) { position in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(position.name + (position.isManager ? " · 管理方" : ""))
                            Spacer()
                            Text(PartnershipFormat.money(position.equity, currency: book.currency)).monospacedDigit()
                        }
                        let ratio = summary.totalCapital > 0 ? position.capital / summary.totalCapital : 0
                        Text("出资比例 \(ratio.formatted(.percent.precision(.fractionLength(2)))) · 留存盈亏 \(PartnershipFormat.money(position.profit, currency: book.currency))")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }.appListRowStyle()
                }
            }
            Section("流水（最新在前）") {
                ForEach(entries) { entry in
                    DisclosureGroup {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        if !entry.note.isEmpty { Text(entry.note) }
                        ForEach(entry.allocations, id: \.memberID) { allocation in
                            let name = book.members.first { $0.id == allocation.memberID }?.name ?? "成员"
                            LabeledContent(name, value: PartnershipFormat.money(allocation.actual, currency: book.currency))
                            Text("原分配 \(PartnershipFormat.money(allocation.base, currency: book.currency)) · 扣减调整 \(PartnershipFormat.money(allocation.adjustment, currency: book.currency))")
                                .appFont(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Text(entry.kind.title)
                            if let name = book.members.first(where: { $0.id == entry.memberID })?.name {
                                Text(name).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(PartnershipFormat.money(entry.amount, currency: book.currency)).monospacedDigit()
                        }
                    }
                    .onAppear {
                        pagination.loadMoreIfNeeded(currentItemID: entry.id, lastVisibleItemID: entries.last?.id, totalItemCount: book.entries.count)
                    }
                }
            }
            Section("分配规则") {
                Text("非管理方按出资比例分配盈亏，再扣减其分配额的 \(book.adjustmentRate.formatted(.percent))；亏损时扣减负数，即由管理方补偿。")
                Text("注资、取出或新成员加入前，请更新账户净值并结算。取出按个人权益同比例赎回本金与留存盈亏；后续比例按剩余资本计算。仅卖出股票但未转出账户资金，无需记录个人取出。")
                    .foregroundStyle(.secondary)
            }
        }
    }
    private func row(_ title: String, _ amount: Decimal, _ book: PartnershipBook) -> some View {
        DetailValueRow(title: title, value: PartnershipFormat.money(amount, currency: book.currency), isMonospaced: true)
    }
}
#endif
