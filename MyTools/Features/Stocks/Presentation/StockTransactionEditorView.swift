#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

private final class StockTransactionEditorDraft: ObservableObject {
    @Published var transaction: StockTransaction
    @Published var quantityText: String
    @Published var unitPriceText: String
    @Published var feesText: String
    @Published var totalAmountText: String
    @Published var recordsExecutionTime: Bool
    @Published var executionTime: Date

    init(transaction: StockTransaction, market: StockMarket) {
        self.transaction = transaction
        recordsExecutionTime = transaction.executedAt != nil
        // 时间选择器固定按北京时间显示，所以直接承载绝对时刻即可。
        executionTime = transaction.executedAt ?? Date()
        quantityText = transaction.quantity == 0 ? "" : Self.display(transaction.quantity)
        unitPriceText = transaction.unitPrice == 0 ? "" : Self.display(transaction.unitPrice)
        feesText = transaction.fees == 0 ? "" : Self.display(transaction.fees)
        totalAmountText = transaction.quantity == 0 || transaction.unitPrice == 0
            ? ""
            : Self.display(
                transaction.type == .buy
                    ? transaction.buyTotalCost
                    : transaction.sellNetProceeds
            )
    }

    /// 由总额反推的单价或股数用更多小数，保存后与用户输入的总额一致（AUDIT-094）。
    static func display(_ value: Decimal, maximumFractionDigits: Int = 4) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
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
        _draft = StateObject(wrappedValue: StockTransactionEditorDraft(
            transaction: transaction,
            market: stock.market
        ))
        self.stock = stock
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("交易信息") {
                    Picker("交易类型", selection: $draft.transaction.type) {
                        ForEach(StockTransactionType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    DateFieldRow(title: "交易日期：", date: $draft.transaction.tradedAt, upperBound: Date())
                    .environment(\.timeZone, StockMarketClock.beijingTimeZone)
                    ToggleFieldRow(title: "记录成交时间", isOn: $draft.recordsExecutionTime)
                    if draft.recordsExecutionTime {
                        DateFieldRow(
                            title: "成交时间：",
                            date: $draft.executionTime,
                            displayedComponents: .hourAndMinute
                        )
                        .environment(\.timeZone, StockMarketClock.beijingTimeZone)
                        Text("日期和时间均按北京时间填写，保存后按股票市场自动换算。美股夜间成交请填写成交时间，否则按北京日期对应的美股交易日处理；不填写时按价格和同日顺序推定。")
                            .appFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    decimalField("交易股数：", placeholder: "必填", text: $draft.quantityText, field: .quantity)
                    decimalField(
                        "每股价格：",
                        placeholder: "必填",
                        text: $draft.unitPriceText,
                        field: .price,
                        showsCurrencySymbol: true
                    )
                }

                Section(draft.transaction.type == .buy ? "买入成本" : "卖出结算") {
                    DetailValueRow(title: "成交金额", value: grossAmountText)
                    decimalField(
                        draft.transaction.type == .buy ? "买入费用：" : "卖出费用：",
                        placeholder: "可选，默认 0",
                        text: $draft.feesText,
                        field: .fees,
                        showsCurrencySymbol: true
                    )
                    expressionField(
                        draft.transaction.type == .buy ? "买入总成本：" : "卖出净回款：",
                        placeholder: draft.transaction.type == .buy ? "成交金额 + 费用" : "成交金额 - 费用",
                        text: $draft.totalAmountText,
                        field: .totalAmount,
                        showsCurrencySymbol: true
                    )
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
            .onChange(of: draft.transaction.type) { _, _ in
                deriveField(editedField: .fees)
            }
        }
    }

    private func decimalField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        showsCurrencySymbol: Bool = false
    ) -> some View {
        NumericFieldRow(
            title: title,
            prompt: placeholder,
            text: text,
            prefix: showsCurrencySymbol ? currencySymbol : nil
        )
            .focused($focusedField, equals: field)
    }

    private func expressionField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        showsCurrencySymbol: Bool = false
    ) -> some View {
        NumericFieldRow(
            title: title,
            prompt: placeholder,
            text: text,
            prefix: showsCurrencySymbol ? currencySymbol : nil,
            allowsExpression: true,
            previewFormatter: { value in
                StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
            }
        )
        .focused($focusedField, equals: field)
    }

    // MARK: - Auto-derive

    // Buy: total cost = quantity × unitPrice + fees.
    // Sell: net proceeds = quantity × unitPrice - fees.
    // When a field loses focus, treat it as authoritative and derive
    // the one field that was NOT just edited:
    //   edited quantity/price/fees → update total
    //   edited total              → update unit price
    private func deriveField(editedField: Field) {
        let fees = DecimalTextParser.optionalDecimal(from: draft.feesText) ?? 0
        let quantity = DecimalTextParser.decimal(from: draft.quantityText)
        let unitPrice = DecimalTextParser.decimal(from: draft.unitPriceText)
        let totalAmount = DecimalTextParser.optionalExpression(from: draft.totalAmountText)

        switch editedField {
        case .quantity, .price, .fees:
            if let q = quantity, let p = unitPrice, q > 0, p > 0 {
                let gross = q * p
                let settlement = draft.transaction.type == .buy
                    ? gross + fees
                    : gross - fees
                draft.totalAmountText = StockTransactionEditorDraft.display(settlement)
            }
        case .totalAmount:
            guard let total = totalAmount, total > 0 else { return }
            let gross = draft.transaction.type == .buy
                ? total - fees
                : total + fees
            guard gross > 0 else { return }
            if let q = quantity, q > 0 {
                draft.unitPriceText = StockTransactionEditorDraft.display(gross / q, maximumFractionDigits: 10)
            }
        }
    }

    private var parsedTransaction: StockTransaction? {
        guard let quantity = DecimalTextParser.decimal(from: draft.quantityText), quantity > 0,
              let unitPrice = DecimalTextParser.decimal(from: draft.unitPriceText), unitPrice > 0,
              let fees = DecimalTextParser.optionalDecimal(from: draft.feesText), fees >= 0 else {
            return nil
        }
        var transaction = draft.transaction
        transaction.executedAt = draft.recordsExecutionTime
            ? StockTransaction.executionInstant(
                tradingDate: transaction.tradedAt,
                beijingTime: draft.executionTime
            )
            : nil
        transaction.quantity = quantity
        transaction.unitPrice = unitPrice
        transaction.fees = fees
        return transaction
    }

    private var grossAmountText: String {
        guard let transaction = parsedTransaction else { return "待填写" }
        return money(transaction.grossAmount)
    }

    private func money(_ value: Decimal) -> String {
        StockValueFormatter.money(value, currencyCode: stock.market.currencyCode)
    }

    private var currencySymbol: String {
        let currency = CurrencyCode(rawValue: stock.market.currencyCode) ?? .cny
        return AppCurrencyFormatter.currencySymbol(for: currency)
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
        transaction.executedAt = draft.recordsExecutionTime
            ? StockTransaction.executionInstant(
                tradingDate: transaction.tradedAt,
                beijingTime: draft.executionTime
            )
            : nil
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
