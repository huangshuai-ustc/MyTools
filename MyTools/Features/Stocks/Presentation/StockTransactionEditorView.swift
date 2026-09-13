#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

private final class StockTransactionEditorDraft: ObservableObject {
    @Published var transaction: StockTransaction
    @Published var quantityText: String
    @Published var unitPriceText: String
    @Published var feesText: String
    @Published var totalAmountText: String

    init(transaction: StockTransaction) {
        self.transaction = transaction
        quantityText = transaction.quantity == 0 ? "" : Self.display(transaction.quantity)
        unitPriceText = transaction.unitPrice == 0 ? "" : Self.display(transaction.unitPrice)
        feesText = transaction.fees == 0 ? "" : Self.display(transaction.fees)
        totalAmountText = transaction.quantity == 0 || transaction.unitPrice == 0
            ? ""
            : Self.display(transaction.quantity * transaction.unitPrice + transaction.fees)
    }

    static func display(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        formatter.usesGroupingSeparator = false
        return formatter.string(from: value as NSDecimalNumber)
            ?? NSDecimalNumber(decimal: value).stringValue
    }
}

struct StockTransactionEditorView: View {
    private enum Field: Hashable {
        case quantity, price, fees, totalAmount
    }

    @EnvironmentObject private var store: StockStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: StockTransactionEditorDraft
    @FocusState private var focusedField: Field?
    @State private var errorMessage = ""
    @State private var showingError = false
    let stock: StockHolding

    init(transaction: StockTransaction, stock: StockHolding) {
        _draft = StateObject(wrappedValue: StockTransactionEditorDraft(transaction: transaction))
        self.stock = stock
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("交易") {
                    Picker("交易类型", selection: $draft.transaction.type) {
                        ForEach(StockTransactionType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    DateFieldRow(title: "交易日期：", date: $draft.transaction.tradedAt)
                    decimalField("交易股数：", placeholder: "必填", text: $draft.quantityText, field: .quantity)
                    decimalField("每股价格：", placeholder: "必填", text: $draft.unitPriceText, field: .price)
                    decimalField("交易费用：", placeholder: "可选，默认 0", text: $draft.feesText, field: .fees)
                    expressionField("交易总额：", placeholder: "含费用", text: $draft.totalAmountText, field: .totalAmount)
                }

                Section {
                    DetailValueRow(title: "当前持仓", value: "\(StockValueFormatter.quantity(stock.currentShares)) 股")
                    DetailValueRow(title: "结算币种", value: stock.market.currencyCode)
                }
            }
            .appNavigationTitle(draft.transaction.type == .buy ? "买入记录" : "卖出记录")
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
            .onChange(of: focusedField) { oldField, newField in
                guard let oldField, oldField != newField else { return }
                deriveField(editedField: oldField)
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

    private func expressionField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        NumericFieldRow(
            title: title,
            prompt: placeholder,
            text: text,
            allowsExpression: true,
            previewFormatter: { value in
                StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
            }
        )
        .focused($focusedField, equals: field)
    }

    // MARK: - Auto-derive

    // Rule: total = quantity × unitPrice + fees
    // When a field loses focus, treat it as authoritative and derive
    // the one field that was NOT just edited:
    //   edited quantity/price/fees → update total
    //   edited total              → update quantity
    private func deriveField(editedField: Field) {
        let fees = DecimalTextParser.optionalDecimal(from: draft.feesText) ?? 0
        let quantity = DecimalTextParser.decimal(from: draft.quantityText)
        let unitPrice = DecimalTextParser.decimal(from: draft.unitPriceText)
        let totalAmount = DecimalTextParser.optionalExpression(from: draft.totalAmountText)

        switch editedField {
        case .quantity, .price, .fees:
            if let q = quantity, let p = unitPrice, q > 0, p > 0 {
                draft.totalAmountText = StockTransactionEditorDraft.display(q * p + fees)
            }
        case .totalAmount:
            guard let total = totalAmount, total > 0 else { return }
            let gross = total - fees
            guard gross > 0 else { return }
            if let q = quantity, q > 0 {
                draft.quantityText = StockTransactionEditorDraft.display(gross / q)
            }
        }
    }

    // MARK: - Save

    private func requestSave() {
        commitPendingTextInput {
            if let field = focusedField {
                deriveField(editedField: field)
            }
            save()
        }
    }

    private func save() {
        guard let quantity = DecimalTextParser.decimal(from: draft.quantityText), quantity > 0,
              let unitPrice = DecimalTextParser.decimal(from: draft.unitPriceText), unitPrice > 0 else {
            reportError("交易股数和每股价格必须大于零。")
            return
        }
        guard let fees = DecimalTextParser.optionalDecimal(from: draft.feesText) else {
            reportError("请输入有效的交易费用。")
            return
        }
        guard fees >= 0 else {
            reportError("交易费用不能小于零。")
            return
        }

        var transaction = draft.transaction
        transaction.quantity = quantity
        transaction.unitPrice = unitPrice
        transaction.fees = fees
        guard store.upsertTransaction(transaction, in: stock.id) else {
            reportError("这笔卖出会使持仓股数小于零，请检查交易股数。")
            return
        }
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

#endif
