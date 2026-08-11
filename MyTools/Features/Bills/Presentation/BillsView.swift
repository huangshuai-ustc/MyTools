#if MYTOOLS_FEATURE_BILLS
import SwiftUI

private enum BillDirectionFilter: Hashable {
    case all
    case direction(BillDirection)

    var title: String {
        switch self {
        case .all: return "全部"
        case .direction(let direction): return direction.title
        }
    }
}

private enum BillsPage: String, CaseIterable, Identifiable {
    case records
    case analysis

    var id: Self { self }

    var title: String {
        switch self {
        case .records: return "记录"
        case .analysis: return "分析"
        }
    }
}

struct BillsView: View {
    @EnvironmentObject private var store: BillsStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var directionFilter: BillDirectionFilter = .all
    @State private var editingRecord: BillRecord?
    @State private var showingOCRImport = false
    @State private var showingFileImport = false
    @State private var selectedPage: BillsPage = .records

    private var visibleRecords: [BillRecord] {
        store.records.filter { record in
            let matchesDirection: Bool
            switch directionFilter {
            case .all: matchesDirection = true
            case .direction(let direction): matchesDirection = record.direction == direction
            }
            return matchesDirection && record.matches(query)
        }
    }

    private var groupedRecords: [(Date, [BillRecord])] {
        Dictionary(grouping: visibleRecords) {
            Calendar.autoupdatingCurrent.startOfDay(for: $0.occurredAt)
        }
        .sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("账单页面", selection: $selectedPage) {
                ForEach(BillsPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            switch selectedPage {
            case .records:
                recordsView
            case .analysis:
                BillAnalysisView()
            }
        }
        .navigationTitle(ToolModule.bills.title)
        .iOSLabeledBackButton("工具")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
#endif
    }

    private var recordsView: some View {
        List {
            if !store.records.isEmpty {
                Section("本月 CNY") {
                    monthlySummary
                        .appListRowStyle()
                }
                Section("筛选") {
                    Picker("收支类型", selection: $directionFilter) {
                        Text("全部").tag(BillDirectionFilter.all)
                        ForEach(BillDirection.allCases) { direction in
                            Text(direction.title).tag(BillDirectionFilter.direction(direction))
                        }
                    }
                    .pickerStyle(.menu)
                    .appListRowStyle()
                }
            }

            if visibleRecords.isEmpty {
                Section {
                    ContentUnavailableView(
                        store.records.isEmpty ? "暂无账单" : "没有匹配的账单",
                        systemImage: store.records.isEmpty ? "receipt" : "magnifyingglass",
                        description: store.records.isEmpty ? Text("可手工添加，或从图片识别账单。") : nil
                    )
                }
            } else {
                ForEach(groupedRecords, id: \.0) { day, records in
                    Section(AppDateFormatter.string(from: day)) {
                        if auth.isAdmin {
                            ForEach(records) { record in
                                recordLink(record)
                            }
                            .onDelete { offsets in
                                store.delete(ids: Set(offsets.map { records[$0].id }))
                            }
                        } else {
                            ForEach(records) { record in
                                recordLink(record)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索商户、商品、账户或标签")
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton()
                if auth.isAdmin {
                    Button {
                        editingRecord = BillRecord()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("手工添加账单")

                    Menu {
                        Button {
                            showingOCRImport = true
                        } label: {
                            Label("图片识别", systemImage: "text.viewfinder")
                        }
                        Button {
                            showingFileImport = true
                        } label: {
                            Label("导入账单文件", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多账单操作")
                }
            }
        }
        .sheet(item: $editingRecord) { record in
            BillEditorView(record: record)
                .id(record.id)
                .iOSLargeSheet()
        }
        .sheet(isPresented: $showingOCRImport) {
            BillOCRImportView()
                .iOSLargeSheet()
        }
        .sheet(isPresented: $showingFileImport) {
            BillImportView()
                .iOSLargeSheet()
        }
    }

    private var monthlySummary: some View {
        let month = Date()
        let expense = store.total(direction: .expense, in: month)
        let income = store.total(direction: .income, in: month)
            + store.total(direction: .refund, in: month)
        return HStack(spacing: 12) {
            summaryValue("支出", amount: expense, color: .red)
            Divider()
            summaryValue("收入及退款", amount: income, color: .green)
            Divider()
            summaryValue("结余", amount: income - expense, color: .primary)
        }
        .padding(.vertical, 5)
    }

    private func summaryValue(_ title: String, amount: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(BillPresentation.amount(amount, currency: .cny))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordLink(_ record: BillRecord) -> some View {
        NavigationLink {
            BillDetailView(recordID: record.id)
        } label: {
            BillRow(record: record)
        }
        .appListRowStyle()
    }
}

private struct BillRow: View {
    let record: BillRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.category.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(record.direction.tint)
                .frame(width: 38, height: 38)
                .background(record.direction.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text(record.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(record.category.title)
                    if !record.paymentMethod.isEmpty {
                        Text("·")
                        Text(record.paymentMethod)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.formattedAmount)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(record.direction.tint)
                    .monospacedDigit()
                Text(record.occurredAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BillDetailView: View {
    @EnvironmentObject private var store: BillsStore
    @EnvironmentObject private var auth: AuthManager
    let recordID: UUID
    @State private var editingRecord: BillRecord?

    private var record: BillRecord? {
        store.records.first { $0.id == recordID }
    }

    var body: some View {
        Group {
            if let record {
                List {
                    Section("交易") {
                        LabeledContent("金额", value: record.formattedAmount)
                        LabeledContent("收支类型", value: record.direction.title)
                        LabeledContent("时间", value: AppDateFormatter.dateTimeString(from: record.occurredAt))
                        LabeledContent("状态", value: record.status.title)
                        LabeledContent("分类", value: record.category.title)
                    }
                    detailSection(record)
                    if !record.tags.isEmpty {
                        Section("标签") { Text(record.tags.joined(separator: "、")) }
                    }
                    if !record.note.isEmpty {
                        Section("备注") { Text(record.note) }
                    }
                    Section("来源") {
                        LabeledContent("录入方式", value: record.origin.kind.title)
                        if !record.origin.providerName.isEmpty {
                            LabeledContent("来源", value: record.origin.providerName)
                        }
                        if !record.providerTransactionType.isEmpty {
                            LabeledContent("平台交易类型", value: record.providerTransactionType)
                        }
                        if !record.providerCategory.isEmpty {
                            LabeledContent("平台分类", value: record.providerCategory)
                        }
                        if !record.counterpartyAccount.isEmpty {
                            LabeledContent("对方账号", value: record.counterpartyAccount)
                                .textSelection(.enabled)
                        }
                        if !record.providerStatus.isEmpty {
                            LabeledContent("平台状态", value: record.providerStatus)
                        }
                        if let externalID = record.origin.externalTransactionID {
                            LabeledContent("外部交易号", value: externalID)
                                .textSelection(.enabled)
                        }
                        if !record.merchantTransactionID.isEmpty {
                            LabeledContent("商户订单号", value: record.merchantTransactionID)
                                .textSelection(.enabled)
                        }
                    }
                }
#if os(iOS)
                .listStyle(.insetGrouped)
#endif
                .navigationTitle(record.displayTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        AdminEditAccessButton()
                        if auth.isAdmin {
                            Button {
                                editingRecord = record
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("编辑账单")
                        }
                    }
                }
            } else {
                ContentUnavailableView("账单不存在", systemImage: "receipt")
            }
        }
        .sheet(item: $editingRecord) { record in
            BillEditorView(record: record)
                .id(record.id)
                .iOSLargeSheet()
        }
    }

    @ViewBuilder
    private func detailSection(_ record: BillRecord) -> some View {
        if !record.merchant.isEmpty || !record.counterparty.isEmpty || !record.itemDescription.isEmpty
            || !record.paymentMethod.isEmpty || !record.accountHint.isEmpty {
            Section("明细") {
                if !record.merchant.isEmpty { LabeledContent("商户", value: record.merchant) }
                if !record.counterparty.isEmpty { LabeledContent("交易对方", value: record.counterparty) }
                if !record.itemDescription.isEmpty { LabeledContent("商品说明", value: record.itemDescription) }
                if !record.paymentMethod.isEmpty { LabeledContent("支付方式", value: record.paymentMethod) }
                if !record.accountHint.isEmpty { LabeledContent("付款账户", value: record.accountHint) }
            }
        }
    }
}

enum BillPresentation {
    static func amount(_ amount: Decimal, currency: CurrencyCode) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.locale = .autoupdatingCurrent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount))
            ?? "\(currency.rawValue) \(amount)"
    }
}

private extension BillDirection {
    var tint: Color {
        switch self {
        case .expense: return .red
        case .income: return .green
        case .refund: return .blue
        case .neutral: return .orange
        }
    }
}

#endif
