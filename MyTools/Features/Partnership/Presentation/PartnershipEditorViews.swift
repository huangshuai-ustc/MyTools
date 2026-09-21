#if MYTOOLS_FEATURE_PARTNERSHIP
import SwiftUI

enum PartnershipAction: String, CaseIterable, Identifiable {
    case buy, sell, dividend, importStocks, contribution, withdrawal, settle, member, rename
    var id: Self { self }
    var title: String {
        switch self {
        case .buy: "记录买入"
        case .sell: "记录卖出"
        case .dividend: "记录股息"
        case .importStocks: "从股票投资导入"
        case .contribution: "单人注资"
        case .withdrawal: "取出可用现金"
        case .settle: "清账收益池"
        case .member: "新成员加入"
        case .rename: "修改账本名称"
        }
    }
}

struct PartnershipCreateView: View {
    @EnvironmentObject private var store: PartnershipStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: PartnershipBookType = .stockInvestment
    @State private var currency: CurrencyCode = .usd
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账本") {
                    FieldEditorRow(title: "名称", prompt: "账本名称", text: $name)
                    PickerFieldRow(title: "账本类型", selection: $type) {
                        ForEach(PartnershipBookType.allCases) { Text($0.title).tag($0) }
                    }
                    PickerFieldRow(title: "账本币种", selection: $currency) {
                        Text(CurrencyCode.usd.title).tag(CurrencyCode.usd)
                    }
                }
                Section("规则") {
                    Text("创建后可随时新增成员和注资；分成比例在每笔卖出时确认，默认带入 5%。").foregroundStyle(.secondary)
                }
            }
            .appNavigationTitle("新建合伙账本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commitPendingTextInput { save() } }
                }
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("确定", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
    private func save() {
        do {
            try store.create(name: name, type: type, currency: currency)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
struct PartnershipActionView: View {
    @EnvironmentObject private var store: PartnershipStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    let bookID: UUID
    let action: PartnershipAction
    private let locksPurchase: Bool
    private let showsCancel: Bool
    private let importKind: PartnershipStockImportRecord.Kind?
    private let finish: () -> Void
    @State private var amount = ""
    @State private var name = ""
    @State private var note = ""
    @State private var memberID: UUID?
    @State private var tradeDate = Date()
    @State private var symbol = ""
    @State private var stockName = ""
    @State private var shares = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var holdingSymbol: String?
    @State private var purchaseID: UUID?
    @State private var adjustmentRate = "5"
    @State private var withholdingTax = ""
    @State private var selectedImportIDs: Set<UUID> = []
    @State private var reinvestChoices: [UUID: Bool] = [:]
    @State private var addingMember = false
    @State private var usesCustomRate = false
    @State private var settlementRate = ""
    @State private var error: String?

    // The book is USD-only for now; every trade is a US-market record.
    private let tradeMarket: PartnershipStockMarket = .unitedStates

    private var book: PartnershipBook? { store.books.first { $0.id == bookID } }
    /// Only US-market transactions can enter a USD book.
    private var importCandidates: [PartnershipStockImportRecord] {
        store.importCandidates(bookID: bookID).filter {
            $0.market == .unitedStates && (importKind == nil || $0.kind == importKind)
        }
    }
    private var availablePurchases: [PartnershipRecord] {
        guard let book else { return [] }
        return book.records.filter { purchase in
            guard purchase.isPurchase else { return false }
            let sold = book.records.lazy
                .filter(\.isSale)
                .flatMap(\.saleMatches)
                .filter { $0.purchaseID == purchase.id }
                .reduce(Decimal.zero) { $0 + $1.shares }
            return sold < purchase.shares
        }
    }
    private var availableHoldings: [PartnershipHoldingChoice] {
        guard let book else { return [] }
        return PartnershipCalculator.stockSummary(book).positions.map { position in
            PartnershipHoldingChoice(symbol: position.symbol, name: position.name, shares: position.shares)
        }.sorted {
            AppAlphabeticalSort.isOrderedBefore($0.name, $1.name, lhsTieBreaker: $0.symbol, rhsTieBreaker: $1.symbol)
        }
    }
    private var purchasesForSelectedHolding: [PartnershipRecord] {
        availablePurchases.filter { $0.symbol == holdingSymbol }
    }
    private var profitPool: [PartnershipAllocation] {
        guard let book else { return [] }
        return PartnershipCalculator.memberProfitPool(book).filter { $0.actual != 0 }
    }

    init(bookID: UUID, action: PartnershipAction, purchaseID: UUID? = nil,
         importKind: PartnershipStockImportRecord.Kind? = nil,
         showsCancel: Bool = true, finish: @escaping () -> Void) {
        self.bookID = bookID
        self.action = action
        locksPurchase = purchaseID != nil
        self.importKind = importKind
        self.showsCancel = showsCancel
        self.finish = finish
        _purchaseID = State(initialValue: purchaseID)
    }
    var body: some View {
        Form {
            if let book {
                switch action {
                case .importStocks: importForm
                case .buy, .sell, .dividend: tradeForm(book)
                case .settle: settleForm(book)
                case .member, .rename: nameForm
                case .contribution, .withdrawal: memberAmountForm(book)
                }
            }
        }
        .appNavigationTitle(action.title)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { finish() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { commitPendingTextInput { save() } }
                    .disabled(saveDisabled)
            }
        }
        .onAppear { configureInitialState() }
        .onChange(of: holdingSymbol) { oldValue, newValue in
            guard action == .sell || action == .dividend, !locksPurchase, oldValue != newValue else { return }
            purchaseID = nil
            if let holding = availableHoldings.first(where: { $0.symbol == newValue }) {
                symbol = holding.symbol
                stockName = holding.name
            } else {
                symbol = ""
                stockName = ""
            }
        }
        .onChange(of: purchaseID) { _, newValue in
            guard action == .sell, let newValue,
                  let purchase = book?.records.first(where: { $0.id == newValue }) else { return }
            symbol = purchase.symbol
            stockName = purchase.name
        }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("确定", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var saveDisabled: Bool {
        book == nil
            || ((action == .sell || action == .dividend) && holdingSymbol == nil)
            || (action == .importStocks && selectedImportIDs.isEmpty)
            || (action == .settle && profitPool.isEmpty)
    }

    private func configureInitialState() {
        memberID = book?.members.first?.id
        if action == .rename { name = book?.name ?? "" }
        if action == .contribution, book?.members.isEmpty == true { addingMember = true }
        if action == .settle {
            reinvestChoices = Dictionary(uniqueKeysWithValues: profitPool.map { ($0.memberID, true) })
            if let rate = book.flatMap({ exchangeRateStore.renminbiBuyingRates[$0.currency] }) {
                settlementRate = NSDecimalNumber(decimal: rate).stringValue
            }
        }
        if action == .sell, let purchaseID,
           let purchase = book?.records.first(where: { $0.id == purchaseID }) {
            holdingSymbol = purchase.symbol
            symbol = purchase.symbol
            stockName = purchase.name
        }
    }
    @ViewBuilder private var importForm: some View {
        Section {
            Text("导入后会复制为本账本的独立记录；后续修改或删除原股票投资记录不会影响这里。仅支持美股交易。")
                .appFont(.footnote).foregroundStyle(.secondary)
        }
        if importCandidates.isEmpty {
            Section { ContentUnavailableView("没有可导入交易", systemImage: "tray") }
        } else {
            Section("已选交易（\(selectedImportIDs.count)）") {
                if selectedImportIDs.isEmpty {
                    Text("尚未选择，进入下方市场逐笔勾选。").appFont(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(importCandidates.filter { selectedImportIDs.contains($0.id) }.sorted { $0.date > $1.date }) { record in
                        Button(role: .destructive) { selectedImportIDs.remove(record.id) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                Text("\(record.title) · \(record.name) \(record.symbol)")
                                    Text(record.kind == .dividend
                                         ? "\(record.date.formatted(date: .numeric, time: .shortened)) · \(PartnershipFormat.money(record.grossAmount))"
                                         : "\(record.date.formatted(date: .numeric, time: .shortened)) · \(PartnershipFormat.shares(record.shares)) 股")
                                        .appFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("按市场浏览") {
                PartnershipImportMarketList(records: importCandidates, selected: $selectedImportIDs)
            }
        }
    }
    @ViewBuilder private func tradeForm(_ book: PartnershipBook) -> some View {
        Section {
            ReadOnlyFieldRow(title: "市场", value: tradeMarket.title)
            if action == .sell && !locksPurchase {
                PickerFieldRow(title: "持仓股票", selection: $holdingSymbol) {
                    Text("请选择").tag(Optional<String>.none)
                    ForEach(availableHoldings) { holding in
                        Text("\(holding.name) · \(PartnershipFormat.shares(holding.shares)) 股").tag(Optional(holding.symbol))
                    }
                }
                if holdingSymbol != nil {
                    PickerFieldRow(title: "买入记录", selection: $purchaseID) {
                        Text("自动（先进先出）").tag(Optional<UUID>.none)
                        ForEach(purchasesForSelectedHolding) { purchase in
                            Text("\(purchase.date.formatted(date: .numeric, time: .omitted)) · 剩余 \(PartnershipFormat.shares(remainingShares(of: purchase, in: book))) 股")
                                .tag(Optional(purchase.id))
                        }
                    }
                }
            }
            if action == .dividend {
                PickerFieldRow(title: "持仓股票", selection: $holdingSymbol) {
                    Text("请选择").tag(Optional<String>.none)
                    ForEach(availableHoldings) { holding in
                        Text("\(holding.name) · \(PartnershipFormat.shares(holding.shares)) 股").tag(Optional(holding.symbol))
                    }
                }
            }
            if action == .buy || holdingSymbol != nil {
                DatePicker("交易时间", selection: $tradeDate, displayedComponents: [.date, .hourAndMinute])
                ReadOnlyFieldRow(title: "交易币种", value: book.currency.title)
                if action == .buy {
                    FieldEditorRow(title: "股票代码", prompt: "例如 AAPL", text: $symbol)
                    FieldEditorRow(title: "股票名称", prompt: "例如 苹果", text: $stockName)
                } else {
                    ReadOnlyFieldRow(title: "股票", value: "\(stockName) · \(symbol)")
                }
                if action == .dividend {
                    NumericFieldRow(title: "税前股息", prompt: "0.00", text: $amount)
                    NumericFieldRow(title: "预扣税", prompt: "0.00", text: $withholdingTax)
                    NumericFieldRow(title: "其他费用", prompt: "0.00", text: $fee)
                } else {
                    NumericFieldRow(title: "股数", prompt: "0", text: $shares)
                    NumericFieldRow(title: "股价", prompt: "0.00", text: $price)
                    NumericFieldRow(title: "手续费", prompt: "0.00", text: $fee)
                }
                if action == .sell {
                    NumericFieldRow(title: "盈利抽成 / 亏损补偿（%）", prompt: "5", text: $adjustmentRate)
                    if locksPurchase, let purchase = book.records.first(where: { $0.id == purchaseID }) {
                        ReadOnlyFieldRow(title: "关联买入", value: "\(purchase.symbol) · \(purchase.date.formatted(date: .numeric, time: .omitted))")
                    }
                }
                FieldEditorRow(title: "备注", prompt: "选填", text: $note)
            }
        } footer: {
            Text("买入会冻结当时的可用资金比例；卖出只把本金返还可用资金，盈利按冻结比例计入收益池，待清账再分配。")
        }
        if let kind = importKind(for: action) {
            Section {
                NavigationLink("从股票投资导入\(kind.title)记录") {
                    PartnershipActionView(bookID: bookID, action: .importStocks,
                                          importKind: kind, showsCancel: false, finish: finish)
                }
            } header: {
                Text("股票投资")
            } footer: {
                Text("这里只显示尚未导入的\(kind.title)记录。")
            }
        }
    }
    @ViewBuilder private func settleForm(_ book: PartnershipBook) -> some View {
        if profitPool.isEmpty {
            Section { ContentUnavailableView("暂无可清账收益", systemImage: "tray") }
        } else {
            Section("清账设置") {
                DatePicker("清账时间", selection: $tradeDate, displayedComponents: [.date, .hourAndMinute])
                Toggle("自定义人民币汇率", isOn: $usesCustomRate)
                NumericFieldRow(title: usesCustomRate ? "自定义汇率" : "中国银行结汇汇率",
                                prompt: "人民币 / 1 \(book.currency.rawValue)", text: $settlementRate)
                    .disabled(!usesCustomRate)
                Text("清账生成后汇率会固定，不再随市场汇率变化。")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(profitPool, id: \.memberID) { allocation in
                    let name = book.members.first { $0.id == allocation.memberID }?.name ?? "成员"
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(name)
                            Spacer()
                            Text(PartnershipFormat.money(allocation.actual))
                                .monospacedDigit()
                                .foregroundStyle(allocation.actual >= 0 ? Color.red : Color.green)
                        }
                        Picker("处理方式", selection: Binding(
                            get: { reinvestChoices[allocation.memberID] ?? true },
                            set: { reinvestChoices[allocation.memberID] = $0 }
                        )) {
                            Text("重投可用资金").tag(true)
                            Text("取回").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            } footer: {
                Text("重投把收益转入可用资金，抬高其后续买入比例，不影响历史交易；取回将收益移出账户。亏损按重投语义抵减可用资金。")
            }
        }
    }

    @ViewBuilder private var nameForm: some View {
        Section {
            FieldEditorRow(title: action == .member ? "姓名" : "名称", prompt: "必填", text: $name)
            if action == .member {
                NumericFieldRow(title: "注资金额", prompt: "0.00", text: $amount)
                DatePicker("发生时间", selection: $tradeDate, displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    @ViewBuilder private func memberAmountForm(_ book: PartnershipBook) -> some View {
        Section {
            if action == .contribution {
                PickerFieldRow(title: "注资对象", selection: $addingMember) {
                    if !book.members.isEmpty { Text("现有成员").tag(false) }
                    Text("新增成员").tag(true)
                }
                if addingMember {
                    FieldEditorRow(title: "成员姓名", prompt: "必填", text: $name)
                } else {
                    PickerFieldRow(title: "成员", selection: $memberID) {
                        ForEach(book.members) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            } else {
                PickerFieldRow(title: "成员", selection: $memberID) {
                    ForEach(book.members) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            ReadOnlyFieldRow(title: "币种", value: book.currency.title)
            NumericFieldRow(title: "金额", prompt: "0.00", text: $amount)
            DatePicker("发生时间", selection: $tradeDate, displayedComponents: [.date, .hourAndMinute])
            FieldEditorRow(title: "备注", prompt: "选填", text: $note)
        } footer: {
            if action == .withdrawal {
                Text("取出金额不能超过该成员当前可用现金；收益需先清账才能取出。")
            }
        }
    }
    private func importKind(for action: PartnershipAction) -> PartnershipStockImportRecord.Kind? {
        switch action {
        case .buy: .buy
        case .sell: .sell
        case .dividend: .dividend
        default: nil
        }
    }
    private func remainingShares(of purchase: PartnershipRecord, in book: PartnershipBook) -> Decimal {
        let sold = book.records.lazy
            .filter(\.isSale)
            .flatMap(\.saleMatches)
            .filter { $0.purchaseID == purchase.id }
            .reduce(Decimal.zero) { $0 + $1.shares }
        return purchase.shares - sold
    }

    private func save() {
        do {
            switch action {
            case .rename:
                try store.rename(id: bookID, name: name)
            case .importStocks:
                try store.importStockRecords(bookID: bookID, ids: selectedImportIDs)
            case .settle:
                guard let rate = DecimalTextParser.decimal(from: settlementRate) else {
                    throw PartnershipError.invalid("请输入有效的人民币汇率。")
                }
                try store.settle(bookID: bookID, reinvest: reinvestChoices, date: tradeDate,
                                 renminbiRate: rate, rateSource: usesCustomRate ? .custom : .bankOfChina)
            case .dividend:
                guard let gross = DecimalTextParser.decimal(from: amount),
                      let tax = optionalAmount(withholdingTax),
                      let feeValue = optionalAmount(fee) else {
                    throw PartnershipError.invalid("请输入有效的股息、预扣税和费用。")
                }
                try store.recordDividend(bookID: bookID, date: tradeDate, market: tradeMarket, symbol: symbol,
                                         name: stockName, grossAmount: gross, withholdingTax: tax, fee: feeValue, note: note)
            case .buy, .sell:
                guard let shareValue = DecimalTextParser.decimal(from: shares),
                      let priceValue = DecimalTextParser.decimal(from: price),
                      let feeValue = optionalAmount(fee) else {
                    throw PartnershipError.invalid("请输入有效的股数、股价和手续费。")
                }
                if action == .buy {
                    try store.recordStockPurchase(bookID: bookID, date: tradeDate, market: tradeMarket, symbol: symbol,
                                                  name: stockName, shares: shareValue, price: priceValue, fee: feeValue, note: note)
                } else {
                    guard let rate = DecimalTextParser.decimal(from: adjustmentRate) else {
                        throw PartnershipError.invalid("请输入有效的分成比例。")
                    }
                    try store.recordStockSale(bookID: bookID, date: tradeDate, market: tradeMarket, symbol: symbol,
                                              name: stockName, shares: shareValue, price: priceValue, fee: feeValue,
                                              adjustmentRate: rate / 100, purchaseID: purchaseID, note: note)
                }
            case .member:
                guard let value = DecimalTextParser.decimal(from: amount) else { throw PartnershipError.invalid("请输入有效金额。") }
                try store.addMember(bookID: bookID, name: name, amount: value, date: tradeDate)
            case .contribution:
                guard let value = DecimalTextParser.decimal(from: amount) else { throw PartnershipError.invalid("请输入有效金额。") }
                if addingMember {
                    try store.addMember(bookID: bookID, name: name, amount: value, date: tradeDate)
                } else {
                    try store.contribute(bookID: bookID, amount: value, memberID: memberID, note: note, date: tradeDate)
                }
            case .withdrawal:
                guard let value = DecimalTextParser.decimal(from: amount) else { throw PartnershipError.invalid("请输入有效金额。") }
                try store.withdraw(bookID: bookID, amount: value, memberID: memberID, note: note, date: tradeDate)
            }
            finish()
        } catch { self.error = error.localizedDescription }
    }

    /// Optional money fields (fee / withholding tax) default to 0 when left blank,
    /// so the form does not need to pre-fill "0" and force the user to clear it.
    private func optionalAmount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? 0 : DecimalTextParser.decimal(from: trimmed)
    }

}

struct PartnershipAddRecordView: View {
    let bookID: UUID
    let finish: () -> Void
    @State private var selectedAction: PartnershipAction = .buy

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("记录类型").foregroundStyle(.secondary)
                    Spacer()
                    Picker("记录类型", selection: $selectedAction) {
                        Text("买入").tag(PartnershipAction.buy)
                        Text("卖出").tag(PartnershipAction.sell)
                        Text("股息（分红）").tag(PartnershipAction.dividend)
                        Text("注资").tag(PartnershipAction.contribution)
                        Text("取现").tag(PartnershipAction.withdrawal)
                    }
                    .labelsHidden()
                    .tint(.blue)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.background)

                Divider()
                form(selectedAction)
                    .id(selectedAction)
            }
            .appNavigationTitle("新增记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { finish() } }
            }
        }
    }

    private func form(_ action: PartnershipAction) -> some View {
        PartnershipActionView(bookID: bookID, action: action, showsCancel: false, finish: finish)
    }
}

private struct PartnershipHoldingChoice: Identifiable {
    var id: String { symbol }
    var symbol: String
    var name: String
    var shares: Decimal
}
private struct PartnershipImportMarketList: View {
    let records: [PartnershipStockImportRecord]
    @Binding var selected: Set<UUID>

    private var markets: [PartnershipStockMarket] {
        Array(Set(records.map(\.market))).sorted { $0.title < $1.title }
    }
    var body: some View {
        ForEach(markets) { market in
            let marketRecords = records.filter { $0.market == market }
            let selectedCount = marketRecords.filter { selected.contains($0.id) }.count
            NavigationLink {
                PartnershipImportSymbolList(market: market, records: marketRecords, selected: $selected)
            } label: {
                HStack {
                    Text(market.title)
                    Spacer()
                    Text(selectedCount > 0 ? "已选 \(selectedCount)/\(marketRecords.count)" : "\(marketRecords.count) 笔")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PartnershipImportSymbolList: View {
    let market: PartnershipStockMarket
    let records: [PartnershipStockImportRecord]
    @Binding var selected: Set<UUID>

    private var symbols: [String] {
        let latestBySymbol = Dictionary(grouping: records, by: \.symbol).compactMapValues { $0.map(\.date).max() }
        return Array(latestBySymbol.keys).sorted { (latestBySymbol[$0] ?? .distantPast) > (latestBySymbol[$1] ?? .distantPast) }
    }
    var body: some View {
        List {
            ForEach(symbols, id: \.self) { symbol in
                let symbolRecords = records.filter { $0.symbol == symbol }.sorted { $0.date > $1.date }
                let name = symbolRecords.first?.name ?? symbol
                let selectedCount = symbolRecords.filter { selected.contains($0.id) }.count
                NavigationLink {
                    PartnershipImportRecordList(title: "\(name) · \(symbol)", records: symbolRecords, selected: $selected)
                } label: {
                    HStack {
                        Text("\(name) · \(symbol)")
                        Spacer()
                        Text(selectedCount > 0 ? "已选 \(selectedCount)/\(symbolRecords.count)" : "\(symbolRecords.count) 笔")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .appNavigationTitle(market.title)
    }
}

private struct PartnershipImportRecordList: View {
    let title: String
    let records: [PartnershipStockImportRecord]
    @Binding var selected: Set<UUID>

    var body: some View {
        List {
            ForEach(records) { record in
                Toggle(isOn: Binding(
                    get: { selected.contains(record.id) },
                    set: { isOn in if isOn { selected.insert(record.id) } else { selected.remove(record.id) } }
                )) {
                    VStack(alignment: .leading) {
                        Text(record.kind == .dividend
                             ? "股息（分红） · \(PartnershipFormat.money(record.grossAmount))"
                             : "\(record.title) · \(PartnershipFormat.shares(record.shares)) 股 @ \(PartnershipFormat.money(record.price))")
                        Text(record.date.formatted(date: .numeric, time: .shortened))
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .appNavigationTitle(title)
    }
}
#endif
