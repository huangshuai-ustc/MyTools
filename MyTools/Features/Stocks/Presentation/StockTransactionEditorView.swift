#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

private final class StockTransactionEditorDraft: ObservableObject {
    @Published var transaction: StockTransaction
    @Published var quantityText: String
    @Published var unitPriceText: String
    @Published var feesText: String

    init(transaction: StockTransaction) {
        self.transaction = transaction
        quantityText = transaction.quantity == 0 ? "" : NSDecimalNumber(decimal: transaction.quantity).stringValue
        unitPriceText = transaction.unitPrice == 0 ? "" : NSDecimalNumber(decimal: transaction.unitPrice).stringValue
        feesText = transaction.fees == 0 ? "" : NSDecimalNumber(decimal: transaction.fees).stringValue
    }
}

struct StockTransactionEditorView: View {
    private enum Field: Hashable {
        case quantity, price, fees
    }

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: StockTransactionEditorDraft
    @FocusState private var focusedField: Field?
    @State private var errorMessage = ""
    @State private var showingError = false
    @State private var showingAuthentication = false
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
                    decimalField("交易费用：", placeholder: "可选", text: $draft.feesText, field: .fees)
                }

                Section {
                    DetailValueRow(title: "当前持仓", value: "\(StockValueFormatter.quantity(stock.currentShares)) 股")
                    DetailValueRow(title: "结算币种", value: stock.market.currencyCode)
                }
            }
            .appNavigationTitle(draft.transaction.type == .buy ? "买入记录" : "卖出记录")
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
