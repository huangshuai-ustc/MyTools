#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
import SwiftUI

private final class CurrencyExchangeEditorDraft: ObservableObject {
    @Published var record: CurrencyExchangeRecord
    @Published var quotedRateText: String
    @Published var soldAmountText: String
    @Published var boughtAmountText: String
    @Published var feeText: String

    init(record: CurrencyExchangeRecord) {
        self.record = record
        quotedRateText = Self.text(record.quotedRate)
        soldAmountText = Self.text(record.soldAmount)
        boughtAmountText = Self.text(record.boughtAmount)
        feeText = Self.text(record.fee)
    }

    private static func text(_ value: Decimal) -> String {
        value == 0 ? "" : NSDecimalNumber(decimal: value).stringValue
    }
}

struct CurrencyExchangeEditorView: View {
    private enum Field: Hashable {
        case quotedRate, soldAmount, boughtAmount, fee
    }

    @EnvironmentObject private var store: CurrencyExchangeStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: CurrencyExchangeEditorDraft
    @FocusState private var focusedField: Field?
    @State private var errorMessage = ""
    @State private var showingError = false

    init(record: CurrencyExchangeRecord) {
        _draft = StateObject(wrappedValue: CurrencyExchangeEditorDraft(record: record))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("币种与日期") {
                    DateFieldRow(title: "换汇日期：", date: exchangeDate)
                    currencyPicker("卖出币种：", selection: $draft.record.soldCurrency)
                    currencyPicker("买入币种：", selection: $draft.record.boughtCurrency)
                }

                Section {
                    PickerFieldRow(title: "价格口径：", selection: $draft.record.quoteConvention) {
                        ForEach(CurrencyExchangeQuoteConvention.allCases) { convention in
                            Text(convention.title(
                                soldCurrency: draft.record.soldCurrency,
                                boughtCurrency: draft.record.boughtCurrency
                            ))
                            .tag(convention)
                        }
                    }
                    decimalField(
                        "价格：",
                        placeholder: "必填",
                        text: $draft.quotedRateText,
                        field: .quotedRate
                    )
                    decimalField("卖出数：", placeholder: "必填", text: $draft.soldAmountText, field: .soldAmount)
                    decimalField("实际买入数：", placeholder: "必填", text: $draft.boughtAmountText, field: .boughtAmount)
                    decimalField("手续费：", placeholder: "可选", text: $draft.feeText, field: .fee)
                } header: {
                    Text("换汇金额")
                } footer: {
                    Text("实际买入数请填写银行最终到账金额，用来和按价格计算出的理论买入数比较。手续费币种为 \(draft.record.soldCurrency.rawValue)，按额外支付计算。")
                }

                Section("损耗预览") {
                    if let preview {
                        DetailValueRow(title: "理论买入", value: CurrencyExchangeValueFormatter.amount(preview.expectedBoughtAmount, currency: preview.boughtCurrency))
                        DetailValueRow(title: "实际买入", value: CurrencyExchangeValueFormatter.amount(preview.boughtAmount, currency: preview.boughtCurrency))
                        if let effectiveRate = preview.effectiveRate {
                            DetailValueRow(title: "含手续费实际汇率", value: CurrencyExchangeValueFormatter.rate(effectiveRate))
                        }
                        if let currentValue = preview.currentRenminbiValue(using: exchangeRateStore.renminbiBuyingRates),
                           let loss = preview.renminbiLoss(using: exchangeRateStore.renminbiBuyingRates) {
                            DetailValueRow(title: "按中国银行买入价可换回", value: CurrencyExchangeValueFormatter.amount(currentValue, currency: .cny))
                            AppLabeledContentRow("\(CurrencyExchangeResult(amount: loss).title) · 当前人民币损耗") {
                                Text(CurrencyExchangeValueFormatter.amount(
                                    CurrencyExchangeResult(amount: loss).displayValue(loss),
                                    currency: .cny
                                ))
                                    .foregroundStyle(resultColor(for: loss))
                            }
                            if let lossRate = preview.renminbiLossRate(using: exchangeRateStore.renminbiBuyingRates) {
                                DetailValueRow(
                                    title: "当前损耗率",
                                    value: CurrencyExchangeValueFormatter.percent(
                                        CurrencyExchangeResult(amount: loss).displayValue(lossRate)
                                    )
                                )
                            }
                        } else {
                            Label("所选币种的中国银行买入价待同步", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("填写价格、卖出数和买入数后自动计算。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .appNavigationTitle(store.records.contains { $0.id == draft.record.id } ? "编辑换汇" : "新增换汇")
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
            .alert("无法保存", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .task {
                exchangeRateStore.refreshIfNeeded()
            }
        }
    }

    private var preview: CurrencyExchangeRecord? {
        guard let quotedRate = DecimalTextParser.decimal(from: draft.quotedRateText), quotedRate > 0,
              let soldAmount = DecimalTextParser.decimal(from: draft.soldAmountText), soldAmount > 0,
              let boughtAmount = DecimalTextParser.decimal(from: draft.boughtAmountText), boughtAmount > 0,
              let fee = DecimalTextParser.optionalDecimal(from: draft.feeText), fee >= 0 else { return nil }
        var record = draft.record
        record.quotedRate = quotedRate
        record.soldAmount = soldAmount
        record.boughtAmount = boughtAmount
        record.fee = fee
        return record
    }

    private var exchangeDate: Binding<Date> {
        Binding(
            get: { draft.record.exchangedAt },
            set: { draft.record.exchangedAt = CurrencyExchangeRecord.noon(on: $0) }
        )
    }

    private func currencyPicker(_ title: String, selection: Binding<CurrencyCode>) -> some View {
        PickerFieldRow(title: title, selection: selection) {
            ForEach(CurrencyCode.selectableCases(including: selection.wrappedValue)) { currency in
                Text(currency.title).tag(currency)
            }
        }
    }

    private func decimalField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        NumericFieldRow(title: title, prompt: placeholder, text: text)
            .focused($focusedField, equals: field)
    }

    private func requestSave() {
        commitPendingTextInput { save() }
    }

    private func save() {
        guard draft.record.soldCurrency != draft.record.boughtCurrency else {
            reportError("卖出币种和买入币种不能相同。")
            return
        }
        guard let record = preview else {
            reportError("价格、卖出数和实际买入数必须大于零，手续费必须为有效的非负数。")
            return
        }
        var datedRecord = record
        datedRecord.exchangedAt = CurrencyExchangeRecord.noon(on: record.exchangedAt)
        store.upsertRecord(datedRecord)
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private func resultColor(for loss: Decimal) -> Color {
        switch CurrencyExchangeResult(amount: loss) {
        case .loss: return .green
        case .profit: return .red
        case .even: return .secondary
        }
    }
}

#endif
