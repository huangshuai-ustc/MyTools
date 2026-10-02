#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
import SwiftUI
import Charts

struct BankOfChinaExchangeRateStatus: View {
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore

    var body: some View {
        if let updatedAt = exchangeRateStore.updatedAt {
            DetailValueRow(
                title: "中国银行牌价时间",
                value: AppDateFormatter.dateTimeString(from: updatedAt)
            )
        }
        if let error = exchangeRateStore.error {
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

struct BankOfChinaExchangeRatesView: View {
    private let rateColumnWidth: CGFloat = 96
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @State private var displayMode: BankExchangeRateDisplayMode = .foreignToRenminbi
    @State private var sourceCurrency: CurrencyCode = .cny
    @State private var targetCurrency: CurrencyCode = .usd
    @State private var sourceAmountText = ""
    @State private var targetAmountText = ""
    @State private var lastEditedConverterField: ExchangeConverterField = .source
    @FocusState private var focusedConverterField: ExchangeConverterField?
    @State private var historyBase: CurrencyCode = .usd
    @State private var historyQuote: CurrencyCode = .cny
    @State private var isHistoryExpanded = false
    @State private var selectedHistoryDate: Date?
    @State private var lastHistorySelectionUpdateTime: TimeInterval = 0

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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isHistoryExpanded.toggle() }
                } label: {
                    HStack {
                        Label("历史参考汇率 · 近一年", systemImage: "chart.xyaxis.line")
                            .font(.headline)
                        Spacer()
                        Image(systemName: isHistoryExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if isHistoryExpanded {
                    historyChart
                    Text("来源：Frankfurter / 欧洲央行每日参考汇率。以人民币为基准交叉换算，不代表中行结售汇成交价；非发布日不补造报价。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(CurrencyCode.selectableCases.filter { $0 != .cny }) { currency in
                    exchangeRateRow(currency)
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前牌价").font(.title3.weight(.bold))
                    exchangeRateHeader
                }
            } footer: {
                Text("结汇采用中国银行现汇买入价，购汇采用中国银行现汇卖出价。上方显示方式决定两个价格的换算方向。")
            }

            Section {
                BankOfChinaExchangeRateStatus()
                Text("页面使用股票和换汇记录共用的中国银行牌价缓存；右上角刷新按钮会主动请求最新结售汇牌价。")
                    .appFont(.footnote)
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
                            .appFont(.caption.weight(.semibold))
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
                        .appFont(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("币种换算")
            } footer: {
                Text("换算方向固定为卖出左侧币种、买入右侧币种。左侧外币按结汇价折算，右侧外币按购汇价买入；输入任意一侧均使用同一组牌价。")
            }
        }
        .appNavigationTitle("中国银行结售汇牌价")
        .diagnosticScreen("中国银行结售汇牌价")
        .iOSLabeledBackButton("换汇记录")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exchangeRateStore.refresh()
                    Task { await exchangeRateStore.refreshReferenceHistory() }
                } label: {
                    if exchangeRateStore.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(exchangeRateStore.isRefreshing)
                .accessibilityLabel("刷新中国银行结售汇牌价")
                .help("刷新中国银行结售汇牌价")
            }
        }
        .task {
            exchangeRateStore.refreshIfNeeded()
            await exchangeRateStore.refreshReferenceHistory()
        }
        .onChange(of: exchangeRateStore.updatedAt) { _, _ in
            updateConversion(from: lastEditedConverterField)
        }
    }

    private var exchangeRateHeader: some View {
        HStack(spacing: 12) {
            Text("币种")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("结汇")
                .frame(width: rateColumnWidth, alignment: .leading)
                .foregroundStyle(.green)
            Text("购汇")
                .frame(width: rateColumnWidth, alignment: .leading)
                .foregroundStyle(.orange)
        }
        .font(.subheadline.weight(.bold))
    }

    private var historyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                historyCurrencyMenu($historyBase, excluding: historyQuote)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                historyCurrencyMenu($historyQuote, excluding: historyBase)
            }
            Text("1 \(historyBase.rawValue) → \(historyQuote.rawValue)")
                .appFont(.caption).foregroundStyle(.secondary)
            if exchangeRateStore.isLoadingHistory { ProgressView("正在补充历史汇率…") }
            if let error = exchangeRateStore.historyError {
                Text(error).appFont(.caption).foregroundStyle(.orange)
            }
            if !HistoricalExchangeRateService.supportedCodes.contains(historyBase.rawValue) || !HistoricalExchangeRateService.supportedCodes.contains(historyQuote.rawValue) {
                Text("来源暂不支持所选币种的历史数据。不会使用其他币种替代。")
                    .foregroundStyle(.secondary)
            } else if historyPoints.isEmpty {
                ContentUnavailableView("暂无历史牌价", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity)
            } else {
                Chart(historyPoints) { point in
                    LineMark(x: .value("日期", point.date), y: .value("汇率", point.value))
                        .foregroundStyle(.tint)
                    PointMark(x: .value("日期", point.date), y: .value("汇率", point.value)).symbolSize(5)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 180)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            if let selectedHistoryDate,
                               let selected = nearestHistoryPoint(to: selectedHistoryDate),
                               let plotFrame = proxy.plotFrame,
                               let rawX = proxy.position(forX: selected.date),
                               let rawY = proxy.position(forY: selected.value) {
                                let frame = geometry[plotFrame]
                                Path { path in
                                    path.move(to: CGPoint(x: rawX + frame.minX, y: frame.minY))
                                    path.addLine(to: CGPoint(x: rawX + frame.minX, y: frame.maxY))
                                }
                                .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 9, height: 9)
                                    .position(x: rawX + frame.minX, y: rawY + frame.minY)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(selected.date, format: .dateTime.year().month().day())
                                    Text(selected.value, format: .number.precision(.fractionLength(4))).fontWeight(.semibold)
                                }
                                .font(.caption2)
                                .padding(6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .position(x: min(max(rawX + frame.minX + 42, frame.minX + 42), frame.maxX - 42), y: frame.minY + 18)
                            }
                            Rectangle().fill(.clear).contentShape(Rectangle())
                        }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let now = Date.timeIntervalSinceReferenceDate
                                guard now - lastHistorySelectionUpdateTime >= (1 / 30) else { return }
                                let x = value.location.x - geometry[plotFrame].origin.x
                                if let date: Date = proxy.value(atX: x), let nearest = nearestHistoryPoint(to: date), nearest.id != selectedHistoryDate {
                                    lastHistorySelectionUpdateTime = now
                                    selectedHistoryDate = nearest.date
                                }
                            })
                    }
                }
            }
        }
    }

    private func historyCurrencyMenu(_ selection: Binding<CurrencyCode>, excluding: CurrencyCode) -> some View {
        Menu {
            ForEach(CurrencyCode.selectableCases.filter { $0 != excluding }) { currency in
                Button(currency.title) { selection.wrappedValue = currency }
            }
        } label: {
            Text(selection.wrappedValue.rawValue)
                .font(.subheadline.weight(.semibold).monospaced())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }

    private var historyPoints: [BankHistoryChartPoint] {
        exchangeRateStore.referenceHistory.compactMap { point in
            guard let base = rate(for: historyBase, in: point.renminbiPerUnit),
                  let quote = rate(for: historyQuote, in: point.renminbiPerUnit), quote > 0 else { return nil }
            return BankHistoryChartPoint(date: point.date, value: NSDecimalNumber(decimal: base / quote).doubleValue)
        }
    }

    private func nearestHistoryPoint(to date: Date) -> BankHistoryChartPoint? {
        historyPoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func rate(for currency: CurrencyCode, in rates: [CurrencyCode: Decimal]) -> Decimal? {
        currency == .cny ? 1 : rates[currency]
    }

    private func exchangeRateRow(_ currency: CurrencyCode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currency.bankOfChinaName ?? currency.title)
                    .font(.subheadline.weight(.semibold))
                Text(currency.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            rateValue(exchangeRateStore.renminbiBuyingRates[currency], tint: .green)
                .frame(width: rateColumnWidth, alignment: .leading)
            rateValue(exchangeRateStore.renminbiSellingRates[currency], tint: .orange)
                .frame(width: rateColumnWidth, alignment: .leading)
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.visible)
    }

    private func rateValue(_ rate: Decimal?, tint: Color = .accentColor) -> some View {
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
        .appFont(.subheadline.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .padding(.horizontal, 5)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .appFont(.subheadline.weight(.semibold).monospaced())
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
                .appFont(.caption2.monospaced())
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
            : exchangeRateStore.renminbiBuyingRates[sourceCurrency]
        let targetSellingRate: Decimal? = targetCurrency == .cny
            ? 1
            : exchangeRateStore.renminbiSellingRates[targetCurrency]
        guard let sourceBuyingRate, let targetSellingRate, targetSellingRate > 0 else { return nil }
        return sourceBuyingRate / targetSellingRate
    }
}

private struct BankHistoryChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

#endif
