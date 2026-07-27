import SwiftUI

struct CurrencyExchangeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var editingRecord: CurrencyExchangeRecord?
    @State private var recordFilter: CurrencyExchangeRecordFilter = .all
    @State private var selectedYear: Int?
    @State private var primaryCurrencyFilter: CurrencyCode?
    @State private var pairedCurrencyFilter: CurrencyCode?
    @State private var query = ""

    private var allRecords: [CurrencyExchangeRecord] {
        // 默认按换汇日期降序排列，最近日期显示在最前面。
        store.currencyExchangeRecords.sorted { $0.exchangedAt > $1.exchangedAt }
    }

    private var records: [CurrencyExchangeRecord] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRecords.filter { record in
            yearMatches(record)
                && recordFilter.includes(record)
                && currenciesMatch(record)
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
                exchangeOverviewMetrics
                    .appListRowStyle()
            }

            Section("记录筛选") {
                Picker("记录分类", selection: $recordFilter) {
                    ForEach(CurrencyExchangeRecordFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                Picker("年份", selection: $selectedYear) {
                    Text("全部年份").tag(nil as Int?)
                    ForEach(availableYears, id: \.self) { year in
                        Text(verbatim: "\(year) 年").tag(year as Int?)
                    }
                }
                .pickerStyle(.menu)

                Picker("相关币种", selection: $primaryCurrencyFilter) {
                    Text("全部币种").tag(nil as CurrencyCode?)
                    ForEach(CurrencyCode.selectableCases) { currency in
                        Text(currency.title).tag(currency as CurrencyCode?)
                    }
                }
                .pickerStyle(.menu)

                if let primaryCurrencyFilter {
                    Picker("组合币种", selection: $pairedCurrencyFilter) {
                        Text("不限另一币种").tag(nil as CurrencyCode?)
                        ForEach(CurrencyCode.selectableCases.filter { $0 != primaryCurrencyFilter }) { currency in
                            Text(currency.title).tag(currency as CurrencyCode?)
                        }
                    }
                    .pickerStyle(.menu)
                }

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
                            .appListRowStyle()
                        }
                    }
                }
            }

            if store.exchangeRateUpdatedAt != nil || store.exchangeRateError != nil {
                Section {
                    BankOfChinaExchangeRateStatus()
                }
            }

            Section {
                Text("记录分类以人民币为标准：买表示买入人民币，卖表示卖出人民币，换表示两种非人民币币种之间的兑换。人民币损耗按当前中国银行现汇买入价动态计算，将交易前的人民币成本（含手续费）与当前可换回的人民币金额进行比较。录入价格仅用于记录交易时的汇率及理论买入数，不参与当前损耗计算。")
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
        .onChange(of: primaryCurrencyFilter) { _, currency in
            if currency == nil || currency == pairedCurrencyFilter {
                pairedCurrencyFilter = nil
            }
        }
        .onChange(of: pairedCurrencyFilter) { _, currency in
            if currency != nil {
                recordFilter = .all
            }
        }
        .onChange(of: recordFilter) { _, filter in
            if filter != .all {
                pairedCurrencyFilter = nil
            }
        }
    }

    private var currencyCountText: String {
        let currencies = Set(allRecords.flatMap { [$0.soldCurrency, $0.boughtCurrency] })
        return currencies.isEmpty ? "0 种" : "\(currencies.count) 种"
    }

    private var availableYears: [Int] {
        let calendar = CurrencyExchangeMonthGroup.calendar
        return Set(allRecords.map { calendar.component(.year, from: $0.exchangedAt) })
            .sorted(by: >)
    }

    private func yearMatches(_ record: CurrencyExchangeRecord) -> Bool {
        guard let selectedYear else { return true }
        return CurrencyExchangeMonthGroup.calendar.component(.year, from: record.exchangedAt) == selectedYear
    }

    private func currenciesMatch(_ record: CurrencyExchangeRecord) -> Bool {
        guard let primaryCurrencyFilter else { return true }
        guard let pairedCurrencyFilter else {
            return record.soldCurrency == primaryCurrencyFilter
                || record.boughtCurrency == primaryCurrencyFilter
        }
        return (record.soldCurrency == primaryCurrencyFilter && record.boughtCurrency == pairedCurrencyFilter)
            || (record.soldCurrency == pairedCurrencyFilter && record.boughtCurrency == primaryCurrencyFilter)
    }

    private var exchangeOverviewMetrics: some View {
        let resultValue: String
        let resultColor: Color
        if let totalRenminbiLoss {
            let result = CurrencyExchangeResult(amount: totalRenminbiLoss)
            resultValue = CurrencyExchangeValueFormatter.amount(
                result.displayValue(totalRenminbiLoss),
                currency: .cny
            )
            resultColor = self.resultColor(for: totalRenminbiLoss)
        } else {
            resultValue = "待同步"
            resultColor = .orange
        }

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                exchangeMetric("换汇记录", value: "\(allRecords.count) 笔")
                exchangeMetric("涉及币种", value: currencyCountText)
                exchangeMetric(totalResultTitle, value: resultValue, color: resultColor)
            }
            VStack(alignment: .leading, spacing: 9) {
                exchangeMetric("换汇记录", value: "\(allRecords.count) 笔")
                exchangeMetric("涉及币种", value: currencyCountText)
                exchangeMetric(totalResultTitle, value: resultValue, color: resultColor)
            }
        }
    }

    private func exchangeMetric(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    private func recordButton(_ record: CurrencyExchangeRecord) -> some View {
        Button { editingRecord = record } label: {
            CurrencyExchangeRecordRow(
                record: record,
                buyingRates: store.renminbiBuyingRates
            )
        }
        .buttonStyle(.plain)
        .appListRowStyle()
    }

    private func deleteRecords(at offsets: IndexSet, from records: [CurrencyExchangeRecord]) {
        store.deleteCurrencyExchangeRecords(ids: Set(offsets.map { records[$0].id }))
    }

    private var totalResultTitle: String {
        guard let totalRenminbiLoss else { return "人民币总损耗" }
        switch CurrencyExchangeResult(amount: totalRenminbiLoss) {
        case .loss, .even: return "人民币总损耗"
        case .profit: return "人民币总盈利"
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
    case buyRenminbi
    case sellRenminbi
    case crossCurrency

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .buyRenminbi: return "买"
        case .sellRenminbi: return "卖"
        case .crossCurrency: return "换"
        }
    }

    func includes(_ record: CurrencyExchangeRecord) -> Bool {
        switch self {
        case .all: return true
        case .buyRenminbi: return RenminbiExchangeDirection(record: record) == .buy
        case .sellRenminbi: return RenminbiExchangeDirection(record: record) == .sell
        case .crossCurrency: return RenminbiExchangeDirection(record: record) == .crossCurrency
        }
    }
}

private struct BankOfChinaExchangeRateStatus: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let updatedAt = store.exchangeRateUpdatedAt {
            LabeledContent(
                "中国银行牌价时间",
                value: updatedAt.formatted(date: .abbreviated, time: .shortened)
            )
        }
        if let error = store.exchangeRateError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
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
                exchangeRateHeader
                    .appListRowStyle()
                ForEach(CurrencyCode.selectableCases.filter { $0 != .cny }) { currency in
                    exchangeRateRow(currency)
                }
            } header: {
                Text("当前牌价")
            } footer: {
                Text("结汇采用中国银行现汇买入价，购汇采用中国银行现汇卖出价。上方显示方式决定两个价格的换算方向。")
            }

            Section {
                BankOfChinaExchangeRateStatus()
                Text("页面使用股票和换汇记录共用的中国银行牌价缓存；右上角刷新按钮会主动请求最新结售汇牌价。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 7) {
                    converterCurrencyMenu(for: .source)
                    converterValueField(
                        text: amountBinding(for: .source),
                        currency: sourceCurrency,
                        field: .source
                    )
                    Button(action: swapConverterCurrencies) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("交换换算币种")
                    converterValueField(
                        text: amountBinding(for: .target),
                        currency: targetCurrency,
                        field: .target
                    )
                    converterCurrencyMenu(for: .target)
                }
                .frame(maxWidth: .infinity)

                if leftToRightConversionRate == nil {
                    Label("所选币种的牌价待同步", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("币种换算")
            } footer: {
                Text("换算方向固定为卖出左侧币种、买入右侧币种。左侧外币按结汇价折算，右侧外币按购汇价买入；输入任意一侧均使用同一组牌价。")
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
        .appListRowStyle()
    }

    private func rateValue(_ rate: Decimal?) -> some View {
        Group {
            if let rate, rate > 0 {
                Text(convertedRateText(rate))
                    .foregroundStyle(.primary)
                    .copyableText(convertedRateText(rate))
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
            return CurrencyExchangeValueFormatter.price(100 / rate)
        case .foreignToRenminbi:
            return CurrencyExchangeValueFormatter.price(rate * 100)
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

    private func converterCurrencyMenu(for field: ExchangeConverterField) -> some View {
        Menu {
            ForEach(CurrencyCode.selectableCases) { currency in
                Button {
                    currencyBinding(for: field).wrappedValue = currency
                } label: {
                    if currency == (field == .source ? sourceCurrency : targetCurrency) {
                        Label(currency.title, systemImage: "checkmark")
                    } else {
                        Text(currency.title)
                    }
                }
            }
        } label: {
            Text((field == .source ? sourceCurrency : targetCurrency).rawValue)
                .font(.subheadline.weight(.semibold).monospaced())
                .frame(minWidth: 42)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(field == .source ? "选择左侧币种" : "选择右侧币种")
    }

    private func converterValueField(
        text: Binding<String>,
        currency: CurrencyCode,
        field: ExchangeConverterField
    ) -> some View {
        HStack(spacing: 3) {
            TextField("0", text: text)
                .multilineTextAlignment(.trailing)
                .focused($focusedConverterField, equals: field)
                .frame(minWidth: 45)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
            Text(currency.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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

        guard let rate = leftToRightConversionRate, rate > 0 else {
            if field == .source { targetAmountText = "" } else { sourceAmountText = "" }
            return
        }

        switch field {
        case .source:
            targetAmountText = CurrencyExchangeValueFormatter.rate(amount * rate)
        case .target:
            sourceAmountText = CurrencyExchangeValueFormatter.rate(amount / rate)
        }
    }

    private var leftToRightConversionRate: Decimal? {
        guard sourceCurrency != targetCurrency else { return 1 }
        let sourceBuyingRate: Decimal? = sourceCurrency == .cny
            ? 1
            : store.renminbiBuyingRates[sourceCurrency]
        let targetSellingRate: Decimal? = targetCurrency == .cny
            ? 1
            : store.renminbiSellingRates[targetCurrency]
        guard let sourceBuyingRate, let targetSellingRate, targetSellingRate > 0 else { return nil }
        return sourceBuyingRate / targetSellingRate
    }
}

private struct CurrencyExchangeRecordRow: View {
    let record: CurrencyExchangeRecord
    let buyingRates: [CurrencyCode: Decimal]

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
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
                Text("卖 \(CurrencyExchangeValueFormatter.amount(record.soldAmount, currency: record.soldCurrency))")
                Spacer()
                Text("买 \(CurrencyExchangeValueFormatter.amount(record.boughtAmount, currency: record.boughtCurrency))")
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
        .contentShape(Rectangle())
    }

    private var lossText: String {
        guard let loss = record.renminbiLoss(using: buyingRates) else {
            return "人民币损耗待同步"
        }
        let result = CurrencyExchangeResult(amount: loss)
        let amount = CurrencyExchangeValueFormatter.amount(result.displayValue(loss), currency: .cny)
        let title: String
        switch result {
        case .loss: title = "损耗"
        case .profit: title = "盈利"
        case .even: title = "持平"
        }
        guard let rate = record.renminbiLossRate(using: buyingRates) else {
            return "\(title) \(amount)"
        }
        return "\(title) \(amount) (\(CurrencyExchangeValueFormatter.percent(result.displayValue(rate))))"
    }

    private var direction: RenminbiExchangeDirection {
        RenminbiExchangeDirection(record: record)
    }

    private var directionColor: Color {
        switch direction {
        case .sell: return .blue
        case .buy: return .purple
        case .crossCurrency: return .teal
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
        case .hundredBoughtToSold:
            return "价格 100 \(record.boughtCurrency.rawValue) = \(CurrencyExchangeValueFormatter.price(record.quotedRate)) \(record.soldCurrency.rawValue)"
        case .hundredSoldToBought:
            return "价格 100 \(record.soldCurrency.rawValue) = \(CurrencyExchangeValueFormatter.price(record.quotedRate)) \(record.boughtCurrency.rawValue)"
        }
    }
}
