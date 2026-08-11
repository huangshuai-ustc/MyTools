#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
import SwiftUI

struct BankOfChinaExchangeRateStatus: View {
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore

    var body: some View {
        if let updatedAt = exchangeRateStore.updatedAt {
            LabeledContent(
                "中国银行牌价时间",
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
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
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
        .adminModeIndicator()
        .iOSLabeledBackButton("换汇记录")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exchangeRateStore.refresh()
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

            rateValue(exchangeRateStore.renminbiBuyingRates[currency])
            rateValue(exchangeRateStore.renminbiSellingRates[currency])
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
            : exchangeRateStore.renminbiBuyingRates[sourceCurrency]
        let targetSellingRate: Decimal? = targetCurrency == .cny
            ? 1
            : exchangeRateStore.renminbiSellingRates[targetCurrency]
        guard let sourceBuyingRate, let targetSellingRate, targetSellingRate > 0 else { return nil }
        return sourceBuyingRate / targetSellingRate
    }
}

#endif
