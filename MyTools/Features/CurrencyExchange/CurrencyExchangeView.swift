import SwiftUI

struct CurrencyExchangeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var editingRecord: CurrencyExchangeRecord?
    @State private var recordFilter: CurrencyExchangeRecordFilter = .all
    @State private var query = ""

    private var allRecords: [CurrencyExchangeRecord] {
        // 默认按换汇日期降序排列，最近日期显示在最前面。
        store.currencyExchangeRecords.sorted { $0.exchangedAt > $1.exchangedAt }
    }

    private var records: [CurrencyExchangeRecord] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRecords.filter { record in
            recordFilter.includes(record)
                && (searchTerm.isEmpty
                    || record.soldCurrency.title.localizedCaseInsensitiveContains(searchTerm)
                    || record.boughtCurrency.title.localizedCaseInsensitiveContains(searchTerm)
                    || record.soldCurrency.rawValue.localizedCaseInsensitiveContains(searchTerm)
                    || record.boughtCurrency.rawValue.localizedCaseInsensitiveContains(searchTerm))
        }
    }

    private var recordGroups: [CurrencyExchangeMonthGroup] {
        let grouped = Dictionary(grouping: records) { record in
            CurrencyExchangeMonthGroup.calendar.date(
                from: CurrencyExchangeMonthGroup.calendar.dateComponents([.year, .month], from: record.exchangedAt)
            ) ?? record.exchangedAt
        }
        return grouped
            .map { CurrencyExchangeMonthGroup(month: $0.key, records: $0.value) }
            .sorted { $0.month > $1.month }
    }

    var body: some View {
        List {
            Section("中国银行牌价") {
                NavigationLink {
                    BankOfChinaExchangeRatesView()
                } label: {
                    Label("查看当前结售汇牌价", systemImage: "yensign.arrow.trianglehead.counterclockwise.rotate.90")
                }
            }

            Section("换汇概览") {
                LabeledContent("累计记录", value: "\(allRecords.count) 笔")
                LabeledContent("涉及币种", value: currencyCountText)
                LabeledContent(totalResultTitle) {
                    if let totalRenminbiLoss {
                        Text(CurrencyExchangeValueFormatter.amount(
                            CurrencyExchangeResult(amount: totalRenminbiLoss).displayValue(totalRenminbiLoss),
                            currency: .cny
                        ))
                            .foregroundStyle(resultColor(for: totalRenminbiLoss))
                    } else {
                        Text("牌价待同步").foregroundStyle(.orange)
                    }
                }
                if let latestRecord = allRecords.first {
                    LabeledContent("最近换汇", value: latestRecord.exchangedAt.formatted(date: .abbreviated, time: .omitted))
                }
                exchangeRateStatus
            }

            Section("查找换汇记录") {
                Picker("记录分类", selection: $recordFilter) {
                    ForEach(CurrencyExchangeRecordFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if records.isEmpty {
                    ContentUnavailableView(
                        allRecords.isEmpty ? "暂无换汇记录" : "没有匹配的换汇记录",
                        systemImage: allRecords.isEmpty ? "arrow.left.arrow.right.circle" : "magnifyingglass"
                    )
                }

            }

            ForEach(recordGroups) { group in
                Section(group.title) {
                    if auth.isAdmin {
                        ForEach(group.records) { record in
                            recordButton(record)
                        }
                        .onDelete { offsets in
                            deleteRecords(at: offsets, from: group.records)
                        }
                    } else {
                        ForEach(group.records) { record in
                            CurrencyExchangeRecordRow(
                                record: record,
                                buyingRates: store.renminbiBuyingRates
                            )
                        }
                    }
                }
            }

            Section {
                Text("人民币损耗会随中国银行现汇买入价更新：把换汇前卖出的本金与手续费、换汇后实际到账的外币分别按当前中国银行买入价折算为人民币，再计算差额。录入价格只用于保存交易与展示当时的理论买入数，不再作为累计损耗基准。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("计算口径")
            }

        }
        .navigationTitle("换汇记录")
        .iOSLabeledBackButton("工具箱")
        .searchable(text: $query, prompt: "搜索币种或代码")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton {
                    editingRecord = CurrencyExchangeRecord()
                }

                if auth.isAdmin {
                    Button { editingRecord = CurrencyExchangeRecord() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加换汇记录")
                }
            }
        }
        .sheet(item: $editingRecord) { record in
            CurrencyExchangeEditorView(record: record)
                .id(record.id)
                .iOSLargeSheet()
        }
        .refreshable {
            store.refreshExchangeRateIfNeeded()
        }
        .task {
            store.refreshExchangeRateIfNeeded()
        }
    }

    private var currencyCountText: String {
        let currencies = Set(allRecords.flatMap { [$0.soldCurrency, $0.boughtCurrency] })
        return currencies.isEmpty ? "0 种" : "\(currencies.count) 种"
    }

    private var totalRenminbiLoss: Decimal? {
        guard !allRecords.isEmpty else { return 0 }
        var total = Decimal.zero
        for record in allRecords {
            guard let loss = record.renminbiLoss(using: store.renminbiBuyingRates) else {
                return nil
            }
            total += loss
        }
        return total
    }

    @ViewBuilder
    private var exchangeRateStatus: some View {
        if let updatedAt = store.exchangeRateUpdatedAt {
            LabeledContent("中国银行牌价时间", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
        } else if let error = store.exchangeRateError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func recordButton(_ record: CurrencyExchangeRecord) -> some View {
        Button { editingRecord = record } label: {
            CurrencyExchangeRecordRow(
                record: record,
                buyingRates: store.renminbiBuyingRates
            )
        }
        .buttonStyle(.plain)
    }

    private func deleteRecords(at offsets: IndexSet, from records: [CurrencyExchangeRecord]) {
        store.deleteCurrencyExchangeRecords(ids: Set(offsets.map { records[$0].id }))
    }

    private var totalResultTitle: String {
        guard let totalRenminbiLoss else { return "当前人民币总损耗" }
        switch CurrencyExchangeResult(amount: totalRenminbiLoss) {
        case .loss: return "亏损 · 人民币总损耗"
        case .profit: return "盈利 · 人民币总增益"
        case .even: return "持平 · 人民币总损耗"
        }
    }

    private func resultColor(for loss: Decimal) -> Color {
        switch CurrencyExchangeResult(amount: loss) {
        case .loss: return .green
        case .profit: return .red
        case .even: return .secondary
        }
    }
}

private struct CurrencyExchangeMonthGroup: Identifiable {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    let month: Date
    let records: [CurrencyExchangeRecord]
    var id: Date { month }

    var title: String {
        let components = Self.calendar.dateComponents([.year, .month], from: month)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }
}

private enum CurrencyExchangeRecordFilter: String, CaseIterable, Identifiable {
    case all
    case sellRenminbi
    case buyRenminbi

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .sellRenminbi: return "卖出"
        case .buyRenminbi: return "买入"
        }
    }

    func includes(_ record: CurrencyExchangeRecord) -> Bool {
        switch self {
        case .all: return true
        case .sellRenminbi: return RenminbiExchangeDirection(record: record) == .sell
        case .buyRenminbi: return RenminbiExchangeDirection(record: record) == .buy
        }
    }
}

private enum BankExchangeRateDisplayMode: String, CaseIterable, Identifiable {
    case foreignToRenminbi
    case renminbiToForeign

    var id: Self { self }

    var title: String {
        switch self {
        case .renminbiToForeign: return "100 CNY → 外币"
        case .foreignToRenminbi: return "100 外币 → CNY"
        }
    }
}

private enum ExchangeConverterField: Hashable {
    case source
    case target
}

private struct BankOfChinaExchangeRatesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var displayMode: BankExchangeRateDisplayMode = .foreignToRenminbi
    @State private var sourceCurrency: CurrencyCode = .cny
    @State private var targetCurrency: CurrencyCode = .usd
    @State private var sourceAmountText = ""
    @State private var targetAmountText = ""
    @State private var lastEditedConverterField: ExchangeConverterField = .source
    @FocusState private var focusedConverterField: ExchangeConverterField?

    var body: some View {
        List {
            Section {
                Picker("显示方式", selection: $displayMode) {
                    ForEach(BankExchangeRateDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("币种 A", selection: currencyBinding(for: .source)) {
                    ForEach(CurrencyCode.selectableCases) { currency in
                        Text(currency.title).tag(currency)
                    }
                }
                converterAmountRow(
                    "金额 A",
                    currency: sourceCurrency,
                    text: amountBinding(for: .source),
                    field: .source
                )

                HStack {
                    Spacer()
                    Button(action: swapConverterCurrencies) {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("交换换算币种")
                    Spacer()
                }

                Picker("币种 B", selection: currencyBinding(for: .target)) {
                    ForEach(CurrencyCode.selectableCases) { currency in
                        Text(currency.title).tag(currency)
                    }
                }
                converterAmountRow(
                    "金额 B",
                    currency: targetCurrency,
                    text: amountBinding(for: .target),
                    field: .target
                )

                if conversionRate(from: sourceCurrency, to: targetCurrency) == nil {
                    Label("所选币种的牌价待同步", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("币种换算")
            } footer: {
                Text("外币卖出按结汇价计算，外币买入按购汇价计算。")
            }

            Section {
                exchangeRateHeader
                ForEach(CurrencyCode.selectableCases.filter { $0 != .cny }) { currency in
                    exchangeRateRow(currency)
                }
            } header: {
                Text("当前牌价")
            } footer: {
                Text("结汇采用中国银行现汇买入价，购汇采用中国银行现汇卖出价。上方显示方式决定两个价格的换算方向。")
            }

            Section {
                if let updatedAt = store.exchangeRateUpdatedAt {
                    LabeledContent("牌价时间", value: updatedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let error = store.exchangeRateError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("页面使用股票和换汇记录共用的中国银行牌价缓存；右上角刷新按钮会主动请求最新结售汇牌价。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("中国银行结售汇牌价")
        .iOSLabeledBackButton("换汇记录")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refreshExchangeRates()
                } label: {
                    if store.isRefreshingExchangeRate {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshingExchangeRate)
                .accessibilityLabel("刷新中国银行结售汇牌价")
                .help("刷新中国银行结售汇牌价")
            }
        }
        .task {
            store.refreshExchangeRateIfNeeded()
        }
        .onChange(of: store.exchangeRateUpdatedAt) { _, _ in
            updateConversion(from: lastEditedConverterField)
        }
    }

    private var exchangeRateHeader: some View {
        HStack(spacing: 12) {
            Text("币种")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("结汇")
                .frame(width: 88, alignment: .trailing)
            Text("购汇")
                .frame(width: 88, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func exchangeRateRow(_ currency: CurrencyCode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currency.bankOfChinaName ?? currency.title)
                    .font(.subheadline.weight(.medium))
                Text(currency.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rateValue(store.renminbiBuyingRates[currency])
            rateValue(store.renminbiSellingRates[currency])
        }
        .padding(.vertical, 3)
    }

    private func rateValue(_ rate: Decimal?) -> some View {
        Group {
            if let rate, rate > 0 {
                Text(convertedRateText(rate))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text("--")
                    .foregroundStyle(.orange)
            }
        }
        .font(.headline.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: 88, alignment: .trailing)
    }

    private func convertedRateText(_ rate: Decimal) -> String {
        switch displayMode {
        case .renminbiToForeign:
            return CurrencyExchangeValueFormatter.rate(100 / rate)
        case .foreignToRenminbi:
            return CurrencyExchangeValueFormatter.rate(rate * 100)
        }
    }

    private func currencyBinding(for field: ExchangeConverterField) -> Binding<CurrencyCode> {
        Binding {
            field == .source ? sourceCurrency : targetCurrency
        } set: { newCurrency in
            switch field {
            case .source:
                if newCurrency == targetCurrency { targetCurrency = sourceCurrency }
                sourceCurrency = newCurrency
            case .target:
                if newCurrency == sourceCurrency { sourceCurrency = targetCurrency }
                targetCurrency = newCurrency
            }
            updateConversion(from: lastEditedConverterField)
        }
    }

    private func amountBinding(for field: ExchangeConverterField) -> Binding<String> {
        Binding {
            field == .source ? sourceAmountText : targetAmountText
        } set: { newValue in
            switch field {
            case .source: sourceAmountText = newValue
            case .target: targetAmountText = newValue
            }
            updateConversion(from: field)
        }
    }

    private func converterAmountRow(
        _ title: String,
        currency: CurrencyCode,
        text: Binding<String>,
        field: ExchangeConverterField
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField("0", text: text)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedConverterField, equals: field)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                Text(currency.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func swapConverterCurrencies() {
        let previousSourceCurrency = sourceCurrency
        let previousSourceAmount = sourceAmountText
        sourceCurrency = targetCurrency
        targetCurrency = previousSourceCurrency
        sourceAmountText = targetAmountText
        targetAmountText = previousSourceAmount
        lastEditedConverterField = .source
        updateConversion(from: .source)
    }

    private func updateConversion(from field: ExchangeConverterField) {
        lastEditedConverterField = field
        let sourceText = field == .source ? sourceAmountText : targetAmountText
        guard let amount = DecimalTextParser.decimal(from: sourceText), amount >= 0 else {
            if field == .source { targetAmountText = "" } else { sourceAmountText = "" }
            return
        }

        let fromCurrency = field == .source ? sourceCurrency : targetCurrency
        let toCurrency = field == .source ? targetCurrency : sourceCurrency
        guard let rate = conversionRate(from: fromCurrency, to: toCurrency) else {
            if field == .source { targetAmountText = "" } else { sourceAmountText = "" }
            return
        }

        let result = CurrencyExchangeValueFormatter.rate(amount * rate)
        if field == .source { targetAmountText = result } else { sourceAmountText = result }
    }

    private func conversionRate(from source: CurrencyCode, to target: CurrencyCode) -> Decimal? {
        guard source != target else { return 1 }
        let sourceBuyingRate: Decimal? = source == .cny ? 1 : store.renminbiBuyingRates[source]
        let targetSellingRate: Decimal? = target == .cny ? 1 : store.renminbiSellingRates[target]
        guard let sourceBuyingRate, let targetSellingRate, targetSellingRate > 0 else { return nil }
        return sourceBuyingRate / targetSellingRate
    }
}

private struct CurrencyExchangeRecordRow: View {
    let record: CurrencyExchangeRecord
    let buyingRates: [CurrencyCode: Decimal]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(record.soldCurrency.rawValue) → \(record.boughtCurrency.rawValue)", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Text(direction.shortTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(directionColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(directionColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel(direction.title)
                Spacer()
                Text(record.exchangedAt, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("卖出 \(CurrencyExchangeValueFormatter.amount(record.soldAmount, currency: record.soldCurrency))")
                Spacer()
                Text("买入 \(CurrencyExchangeValueFormatter.amount(record.boughtAmount, currency: record.boughtCurrency))")
            }
            .font(.subheadline)

            HStack {
                Text(priceText)
                Spacer()
                Text(lossText)
                    .foregroundStyle(lossColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var lossText: String {
        guard let loss = record.renminbiLoss(using: buyingRates) else {
            return "人民币损耗待同步"
        }
        let result = CurrencyExchangeResult(amount: loss)
        let amount = CurrencyExchangeValueFormatter.amount(result.displayValue(loss), currency: .cny)
        guard let rate = record.renminbiLossRate(using: buyingRates) else {
            return "当前损耗 \(amount)"
        }
        return "\(result.title) · 当前损耗 \(amount)（\(CurrencyExchangeValueFormatter.percent(result.displayValue(rate)))）"
    }

    private var direction: RenminbiExchangeDirection {
        RenminbiExchangeDirection(record: record)
    }

    private var directionColor: Color {
        switch direction {
        case .sell: return .blue
        case .buy: return .purple
        case .crossCurrency: return .secondary
        }
    }

    private var lossColor: Color {
        guard let loss = record.renminbiLoss(using: buyingRates) else { return .orange }
        switch CurrencyExchangeResult(amount: loss) {
        case .loss: return .green
        case .profit: return .red
        case .even: return .secondary
        }
    }

    private var priceText: String {
        switch record.quoteConvention {
        case .oneSoldToBought:
            return "价格 1 \(record.soldCurrency.rawValue) = \(CurrencyExchangeValueFormatter.rate(record.quotedRate)) \(record.boughtCurrency.rawValue)"
        case .hundredBoughtToSold:
            return "价格 100 \(record.boughtCurrency.rawValue) = \(CurrencyExchangeValueFormatter.rate(record.quotedRate)) \(record.soldCurrency.rawValue)"
        }
    }
}
