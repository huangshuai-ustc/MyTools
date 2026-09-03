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

private enum BillCategoryFilter: Hashable {
    case all
    case category(BillCategory)

    var title: String {
        switch self {
        case .all: return "全部分类"
        case .category(let category): return category.title
        }
    }
}

enum BillsPage: String, CaseIterable, Identifiable {
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

struct BillsPagePicker: View {
    @Binding var selection: BillsPage

    var body: some View {
        Picker("账单页面", selection: $selection) {
            ForEach(BillsPage.allCases) { page in
                Text(page.title).tag(page)
            }
        }
        .pickerStyle(.segmented)
    }
}

struct BillsView: View {
    private static let pageSize = 30
    @EnvironmentObject private var store: BillsStore
    @State private var query = ""
    @State private var directionFilter: BillDirectionFilter = .all
    @State private var categoryFilter: BillCategoryFilter = .all
    @State private var selectedTag = ""
    @State private var editingRecord: BillRecord?
    @State private var showingOCRImport = false
    @State private var showingFileImport = false
    @State private var selectedPage: BillsPage = .records
    @State private var pagination = AppListPagination(pageSize: BillsView.pageSize)

    private var visibleRecords: [BillRecord] {
        store.records.filter { record in
            let matchesDirection: Bool
            switch directionFilter {
            case .all: matchesDirection = true
            case .direction(let direction): matchesDirection = record.direction == direction
            }
            let matchesCategory: Bool
            switch categoryFilter {
            case .all: matchesCategory = true
            case .category(let category): matchesCategory = record.category == category
            }
            let matchesTag = selectedTag.isEmpty || record.tags.contains(selectedTag)
            return matchesDirection && matchesCategory && matchesTag && record.matches(query)
        }
    }

    private var pagedRecords: [BillRecord] {
        pagination.visibleItems(from: visibleRecords)
    }

    private var availableCategories: [BillCategory] {
        Set(store.records.map(\.category)).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var availableTags: [String] {
        AppTagSupport.normalize(store.records.flatMap(\.tags))
    }

    private var groupedRecords: [(Date, [BillRecord])] {
        Dictionary(grouping: pagedRecords) {
            Calendar.autoupdatingCurrent.startOfDay(for: $0.occurredAt)
        }
        .sorted { $0.key > $1.key }
    }

    var body: some View {
        Group {
            switch selectedPage {
            case .records:
                recordsList
            case .analysis:
                BillAnalysisView(pageSelection: $selectedPage)
            }
        }
        .appNavigationTitle(ToolModule.bills.title)
        .iOSLabeledBackButton("工具")
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
#endif
        .toolbar { billsToolbar }
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

    @ViewBuilder
    private var recordsList: some View {
        List {
            Section {
                BillsPagePicker(selection: $selectedPage)
            }

            if !store.records.isEmpty {
                Section("本月 CNY 概览") {
                    monthlySummary
                        .appListRowStyle()
                }
                Section("筛选") {
                    AppLabeledContentRow(
                        "收支类型",
                        systemImage: "arrow.up.arrow.down"
                    ) {
                        Picker("收支类型", selection: $directionFilter) {
                            Text("全部").tag(BillDirectionFilter.all)
                            ForEach(BillDirection.allCases) { direction in
                                Text(direction.title).tag(BillDirectionFilter.direction(direction))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    if !availableCategories.isEmpty {
                        AppLabeledContentRow(
                            "分类",
                            systemImage: "square.grid.2x2"
                        ) {
                            Picker("分类", selection: $categoryFilter) {
                                Text(BillCategoryFilter.all.title).tag(BillCategoryFilter.all)
                                ForEach(availableCategories) { category in
                                    Text(category.title).tag(BillCategoryFilter.category(category))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                    if !availableTags.isEmpty {
                        AppTagFilterCapsules(tags: availableTags, selectedTag: $selectedTag)
                            .appListRowStyle()
                    }
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
                        ForEach(records) { record in
                            recordLink(record)
                                .onAppear { loadMoreIfNeeded(record) }
                        }
                    }
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
        .searchable(text: $query, prompt: "搜索商户、商品、账户或标签")
        .onChange(of: query) { _, _ in resetPagination() }
        .onChange(of: directionFilter) { _, _ in resetPagination() }
        .onChange(of: categoryFilter) { _, _ in resetPagination() }
        .onChange(of: selectedTag) { _, _ in resetPagination() }
    }

    @ToolbarContentBuilder
    private var billsToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editingRecord = BillRecord()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("手工添加账单")
                .contextMenu {
                    Menu {
                        Button {
                            showingOCRImport = true
                        } label: {
                            Label("图片识别", systemImage: "text.viewfinder")
                        }
                        Button {
                            showingFileImport = true
                        } label: {
                            Label("账单文件", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Label("从文件导入", systemImage: "square.and.arrow.down")
                    }
                }
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

    private func resetPagination() {
        pagination.reset()
    }

    private func loadMoreIfNeeded(_ record: BillRecord) {
        pagination.loadMoreIfNeeded(
            currentItemID: record.id,
            lastVisibleItemID: pagedRecords.last?.id,
            totalItemCount: visibleRecords.count
        )
    }

    private func summaryValue(_ title: String, amount: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(BillPresentation.amount(amount, currency: .cny))
                .appFont(.subheadline.weight(.semibold))
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
        .appDeleteSwipeAction(isEnabled: true) {
            store.delete(ids: [record.id])
        }
    }
}

private struct BillRow: View {
    @Environment(\.appFontScale) private var fontScale
    let record: BillRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.category.systemImage)
                .appFont(.body.weight(.semibold))
                .foregroundStyle(record.direction.tint)
                .frame(width: 38, height: 38)
                .background(record.direction.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
                Text(record.displayTitle)
                    .appFont(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(record.category.title)
                    if !record.paymentMethod.isEmpty {
                        Text("·")
                        Text(record.paymentMethod)
                    }
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                AppTagCapsules(tags: record.tags, limit: 3)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.formattedAmount)
                    .appFont(.body.weight(.semibold))
                    .foregroundStyle(record.direction.tint)
                    .monospacedDigit()
                Text(record.occurredAt, format: .dateTime.hour().minute())
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BillDetailView: View {
    @EnvironmentObject private var store: BillsStore
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
                        DetailValueRow(title: "金额", value: record.formattedAmount)
                        DetailValueRow(title: "收支类型", value: record.direction.title)
                        DetailValueRow(
                            title: "时间",
                            value: AppDateFormatter.dateTimeWithoutSecondsString(from: record.occurredAt)
                        )
                        DetailValueRow(title: "状态", value: record.status.title)
                        DetailValueRow(title: "分类", value: record.category.title)
                    }
                    detailSection(record)
                    if !record.tags.isEmpty {
                        Section("标签") { AppTagCapsules(tags: record.tags) }
                    }
                    if !record.note.isEmpty {
                        Section("备注") { Text(record.note) }
                    }
                    Section("来源") {
                        DetailValueRow(title: "录入方式", value: record.origin.kind.title)
                        if !record.origin.providerName.isEmpty {
                            DetailValueRow(title: "来源", value: record.origin.providerName)
                        }
                        if !record.providerTransactionType.isEmpty {
                            DetailValueRow(title: "平台交易类型", value: record.providerTransactionType)
                        }
                        if !record.providerCategory.isEmpty {
                            DetailValueRow(title: "平台分类", value: record.providerCategory)
                        }
                        if !record.counterpartyAccount.isEmpty {
                            DetailValueRow(title: "对方账号", value: record.counterpartyAccount)
                                .textSelection(.enabled)
                        }
                        if !record.providerStatus.isEmpty {
                            DetailValueRow(title: "平台状态", value: record.providerStatus)
                        }
                        if let externalID = record.origin.externalTransactionID {
                            DetailValueRow(title: "外部交易号", value: externalID)
                                .textSelection(.enabled)
                        }
                        if !record.merchantTransactionID.isEmpty {
                            DetailValueRow(title: "商户订单号", value: record.merchantTransactionID)
                                .textSelection(.enabled)
                        }
                    }
                }
#if os(iOS)
                .listStyle(.insetGrouped)
#endif
                .appNavigationTitle(record.displayTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            editingRecord = record
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("编辑账单")
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
                if !record.merchant.isEmpty { DetailValueRow(title: "商户", value: record.merchant) }
                if !record.counterparty.isEmpty {
                    DetailValueRow(title: "交易对方", value: record.counterparty)
                }
                if !record.itemDescription.isEmpty {
                    DetailValueRow(title: "商品说明", value: record.itemDescription)
                }
                if !record.paymentMethod.isEmpty {
                    DetailValueRow(title: "支付方式", value: record.paymentMethod)
                }
                if !record.accountHint.isEmpty {
                    DetailValueRow(title: "付款账户", value: record.accountHint)
                }
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

private enum BillExportSource: Hashable {
    case all
    case provider(String)

    var title: String {
        switch self {
        case .all: return "全部来源"
        case .provider(let name): return name
        }
    }
}

private enum BillExportCategory: Hashable {
    case all
    case category(BillCategory)

    var title: String {
        switch self {
        case .all: return "全部分类"
        case .category(let category): return category.title
        }
    }
}

private enum BillExportDirection: Hashable {
    case all
    case direction(BillDirection)

    var title: String {
        switch self {
        case .all: return "全部收支"
        case .direction(let direction): return direction.title
        }
    }
}

struct BillsExportSettingsView: View {
    @EnvironmentObject private var store: BillsStore
    @State private var period: BillExportPeriod = .oneMonth
    @State private var customStart = Calendar.autoupdatingCurrent.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var source: BillExportSource = .all
    @State private var category: BillExportCategory = .all
    @State private var direction: BillExportDirection = .all
    @State private var exportDocument: BillExchangeFileDocument?
    @State private var exportFilename = "账单.json"
    @State private var errorMessage: String?

    private var sourceNames: [String] {
        Set(store.records.map { $0.origin.providerName }.filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredRecords: [BillRecord] {
        exportFilter.records(from: store.records)
    }

    private var exportFilter: BillExportFilter {
        BillExportFilter(
            period: period,
            customStart: customStart,
            customEnd: customEnd,
            providerName: source.providerName,
            category: category.value,
            direction: direction.value
        )
    }

    var body: some View {
        Form {
            Section("导出范围") {
                PickerFieldRow(title: "时间区间", selection: $period) {
                    ForEach(BillExportPeriod.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                if period == .custom {
                    DateFieldRow(title: "开始日期", date: $customStart)
                    DateFieldRow(title: "结束日期", date: $customEnd)
                }
                DetailValueRow(title: "符合条件", value: "\(filteredRecords.count) 笔")
            }

            Section("筛选条件") {
                PickerFieldRow(title: "来源", selection: $source) {
                    Text(BillExportSource.all.title).tag(BillExportSource.all)
                    ForEach(sourceNames, id: \.self) { name in
                        Text(name).tag(BillExportSource.provider(name))
                    }
                }
                PickerFieldRow(title: "分类", selection: $category) {
                    Text(BillExportCategory.all.title).tag(BillExportCategory.all)
                    ForEach(BillCategory.allCases) { value in
                        Text(value.title).tag(BillExportCategory.category(value))
                    }
                }
                PickerFieldRow(title: "收支", selection: $direction) {
                    Text(BillExportDirection.all.title).tag(BillExportDirection.all)
                    ForEach(BillDirection.allCases) { value in
                        Text(value.title).tag(BillExportDirection.direction(value))
                    }
                }
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label("导出账单", systemImage: "square.and.arrow.up")
                }
                .disabled(filteredRecords.isEmpty)
            }
        }
        .appNavigationTitle("账单导出")
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportDocument = nil
        }
        .alert("无法导出", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepareExport() {
        guard !filteredRecords.isEmpty else { return }
        if period == .custom && Calendar.autoupdatingCurrent.startOfDay(for: customStart)
            > Calendar.autoupdatingCurrent.startOfDay(for: customEnd) {
            errorMessage = "开始日期不能晚于结束日期。"
            return
        }
        do {
            exportDocument = try BillExchangeFileDocument(
                document: BillExchangeMapper.document(from: filteredRecords)
            )
            exportFilename = "账单-\(exportDateSuffix()).json"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportDateSuffix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }
}

private extension BillExportSource {
    var providerName: String? {
        if case .provider(let name) = self { return name }
        return nil
    }
}

private extension BillExportCategory {
    var value: BillCategory? {
        if case .category(let category) = self { return category }
        return nil
    }
}

private extension BillExportDirection {
    var value: BillDirection? {
        if case .direction(let direction) = self { return direction }
        return nil
    }
}

#endif
