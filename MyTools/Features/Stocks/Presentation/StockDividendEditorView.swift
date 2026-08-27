#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

private final class StockDividendEditorDraft: ObservableObject {
    @Published var dividend: StockDividend
    @Published var quantityText: String
    @Published var dividendPerShareText: String
    @Published var withholdingTaxText: String
    @Published var feesText: String

    init(dividend: StockDividend, defaultQuantity: Decimal) {
        self.dividend = dividend
        let savedQuantityText = Self.text(for: dividend.quantity)
        quantityText = dividend.grossAmount == 0 && savedQuantityText.isEmpty
            ? Self.text(for: defaultQuantity)
            : savedQuantityText
        dividendPerShareText = Self.text(for: dividend.dividendPerShare)
        withholdingTaxText = Self.text(for: dividend.withholdingTax)
        feesText = Self.text(for: dividend.fees)
    }

    private static func text(for value: Decimal) -> String {
        value == 0 ? "" : NSDecimalNumber(decimal: value).stringValue
    }
}

struct StockDividendEditorView: View {
    private enum Field: Hashable {
        case quantity, dividendPerShare, withholdingTax, fees
    }

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var fontScale
    @StateObject private var draft: StockDividendEditorDraft
    @FocusState private var focusedField: Field?
    @State private var errorMessage = ""
    @State private var showingError = false
    @State private var showingAuthentication = false
    let stock: StockHolding

    init(dividend: StockDividend, stock: StockHolding) {
        _draft = StateObject(wrappedValue: StockDividendEditorDraft(
            dividend: dividend,
            defaultQuantity: stock.currentShares
        ))
        self.stock = stock
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("分红信息") {
                    DateFieldRow(title: "到账日期：", date: $draft.dividend.receivedAt)
                    decimalField(
                        "分红股数：",
                        placeholder: "必填",
                        text: $draft.quantityText,
                        field: .quantity
                    )
                    decimalField(
                        "每股分红：",
                        placeholder: "必填",
                        text: $draft.dividendPerShareText,
                        field: .dividendPerShare
                    )
                    LabeledContent("税前分红", value: grossAmountText)
                        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
                    decimalField(
                        "预扣税：",
                        placeholder: "可选",
                        text: $draft.withholdingTaxText,
                        field: .withholdingTax
                    )
                    decimalField(
                        "其他费用：",
                        placeholder: "可选",
                        text: $draft.feesText,
                        field: .fees
                    )
                }

                Section("结算") {
                    LabeledContent("结算币种", value: stock.market.currencyCode)
                    LabeledContent("净到账", value: netAmountText)
                }

                Section("备注") {
                    IMESafeMultilineTextField(prompt: "可选", text: $draft.dividend.note)
                }
            }
            .appNavigationTitle(draft.dividend.grossAmount == 0 ? "添加分红" : "编辑分红")
            .adminModeIndicator()
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
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSAuthenticationSheet()
            }
            .alert("无法保存", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var grossAmountText: String {
        guard let grossAmount = calculatedGrossAmount else { return "待填写" }
        return StockValueFormatter.money(grossAmount, currencyCode: stock.market.currencyCode)
    }

    private var netAmountText: String {
        guard let grossAmount = calculatedGrossAmount,
              let withholdingTax = DecimalTextParser.optionalDecimal(from: draft.withholdingTaxText),
              let fees = DecimalTextParser.optionalDecimal(from: draft.feesText) else {
            return "待填写"
        }
        return StockValueFormatter.money(
            grossAmount - withholdingTax - fees,
            currencyCode: stock.market.currencyCode
        )
    }

    private var calculatedGrossAmount: Decimal? {
        guard let quantity = DecimalTextParser.decimal(from: draft.quantityText), quantity > 0,
              let dividendPerShare = DecimalTextParser.decimal(from: draft.dividendPerShareText),
              dividendPerShare > 0 else {
            return nil
        }
        return quantity * dividendPerShare
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
        commitPendingTextInput {
            save()
        }
    }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        guard let quantity = DecimalTextParser.decimal(from: draft.quantityText), quantity > 0,
              let dividendPerShare = DecimalTextParser.decimal(from: draft.dividendPerShareText),
              dividendPerShare > 0 else {
            reportError("分红股数和每股分红必须大于零。")
            return
        }
        let grossAmount = quantity * dividendPerShare
        guard let withholdingTax = DecimalTextParser.optionalDecimal(from: draft.withholdingTaxText),
              let fees = DecimalTextParser.optionalDecimal(from: draft.feesText) else {
            reportError("请输入有效的预扣税和其他费用。")
            return
        }
        guard withholdingTax >= 0, fees >= 0 else {
            reportError("预扣税和其他费用不能小于零。")
            return
        }
        guard withholdingTax + fees <= grossAmount else {
            reportError("预扣税和其他费用之和不能超过税前分红。")
            return
        }

        var dividend = draft.dividend
        dividend.quantity = quantity
        dividend.dividendPerShare = dividendPerShare
        dividend.grossAmount = grossAmount
        dividend.withholdingTax = withholdingTax
        dividend.fees = fees
        store.upsertDividend(dividend, in: stock.id)
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

#endif
