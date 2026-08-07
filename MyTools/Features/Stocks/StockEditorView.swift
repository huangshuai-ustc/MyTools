import SwiftUI

private final class StockEditorDraft: ObservableObject {
    @Published var stock: StockHolding
    @Published var symbolText: String
    @Published var nameText: String
    @Published var initialTradedAt = Date()
    @Published var includesInitialPurchase = true
    @Published var quantityText = ""
    @Published var unitPriceText = ""
    @Published var feesText = ""

    init(stock: StockHolding) {
        self.stock = stock
        symbolText = stock.symbol
        nameText = stock.name
    }
}

struct StockEditorView: View {
    private enum Field: Hashable {
        case symbol, name, quantity, price, fees
    }

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: StockEditorDraft
    @FocusState private var focusedField: Field?
    @State private var errorMessage = ""
    @State private var showingError = false
    @State private var showingAuthentication = false
    let isNew: Bool
    private let originalSymbol: String

    init(stock: StockHolding, isNew: Bool) {
        _draft = StateObject(wrappedValue: StockEditorDraft(stock: stock))
        self.isNew = isNew
        originalSymbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("股票信息") {
                    Picker("股票市场", selection: $draft.stock.market) {
                        ForEach(StockMarket.allCases) { market in
                            Text(market.title).tag(market)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!isNew)
                    LabeledContent("股票代码：") {
                        IMESafeTextField(
                            prompt: symbolPrompt,
                            text: $draft.symbolText,
                            alignment: .trailing,
                            mode: .asciiUppercase
                        )
                    }
                    LabeledContent("股票名称：") {
                        IMESafeTextField(prompt: "可选", text: $draft.nameText, alignment: .trailing)
                    }
                }

                if isNew {
                    Section("新增方式") {
                        Toggle("记录首次买入", isOn: $draft.includesInitialPurchase)
                        if !draft.includesInitialPurchase {
                            Text("仅保存股票代码和行情信息，不计入持仓。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isNew, draft.includesInitialPurchase {
                    Section("首次买入") {
                        DatePicker(
                            "购买日期：",
                            selection: $draft.initialTradedAt,
                            displayedComponents: .date
                        )
                        decimalField("购买股数：", placeholder: "必填", text: $draft.quantityText, field: .quantity)
                        decimalField("每股价格：", placeholder: "必填", text: $draft.unitPriceText, field: .price)
                        decimalField("交易费用：", placeholder: "可选", text: $draft.feesText, field: .fees)
                    }
                }
            }
            .navigationTitle(isNew ? "添加股票" : "编辑股票")
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
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
        }
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

        var stock = draft.stock
        stock.symbol = StockHolding.normalizedSymbol(draft.symbolText, market: stock.market)
        stock.name = draft.nameText
        guard validSymbol(stock.symbol, market: stock.market) else {
            reportError(invalidSymbolMessage)
            return
        }
        guard !store.stockExists(market: stock.market, symbol: stock.symbol, excluding: stock.id) else {
            reportError("该市场中已经添加了这只股票。")
            return
        }

        if isNew, draft.includesInitialPurchase {
            guard let quantity = DecimalTextParser.decimal(from: draft.quantityText), quantity > 0,
                  let unitPrice = DecimalTextParser.decimal(from: draft.unitPriceText), unitPrice > 0 else {
                reportError("购买股数和每股价格必须大于零。")
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
            stock.transactions = [StockTransaction(
                type: .buy,
                tradedAt: StockTransaction.normalizedDate(draft.initialTradedAt),
                dayOrder: 0,
                quantity: quantity,
                unitPrice: unitPrice,
                fees: fees
            )]
        } else if stock.symbol != originalSymbol {
            stock.latestPrice = nil
            stock.previousClose = nil
            stock.changePercent = nil
            stock.quoteName = ""
            stock.lastQuoteAt = nil
        }

        store.upsertStock(stock)
        dismiss()
    }

    private func validSymbol(_ symbol: String, market: StockMarket) -> Bool {
        guard !symbol.isEmpty else { return false }
        switch market {
        case .aShare:
            return symbol.count == 6 && symbol.allSatisfy(\.isNumber)
        case .hongKong:
            return symbol.count == 5 && symbol.allSatisfy(\.isNumber)
        case .unitedStates:
            return symbol.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        }
    }

    private var symbolPrompt: String {
        switch draft.stock.market {
        case .aShare: return "例如 600519"
        case .hongKong: return "例如 00700"
        case .unitedStates: return "例如 AAPL"
        }
    }

    private var invalidSymbolMessage: String {
        switch draft.stock.market {
        case .aShare: return "A 股代码需要填写 6 位数字。"
        case .hongKong: return "港股代码需要填写 5 位数字，例如 00700。"
        case .unitedStates: return "请填写有效的美股代码。"
        }
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
