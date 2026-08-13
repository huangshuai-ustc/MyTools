import SwiftUI

struct NotificationSettingsView: View {
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
    @EnvironmentObject private var currencyStore: CurrencyExchangeStore
#endif
#if MYTOOLS_FEATURE_STOCKS
    @EnvironmentObject private var stockStore: StockStore
#endif
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var notifications: AppNotificationService
    @EnvironmentObject private var moduleSettings: ToolModuleSettings
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
    @State private var editingCurrencyAlert: CurrencyRateAlert?
#endif
#if MYTOOLS_FEATURE_STOCKS
    @State private var editingStockAlert: StockPriceAlert?
#endif

#if MYTOOLS_FEATURE_STOCKS
    private var configuredStocks: [StockHolding] {
        stockStore.stocks
            .filter(\.hasConfiguredSymbol)
            .sorted { lhs, rhs in
                let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if nameComparison == .orderedSame {
                    return lhs.symbol.localizedStandardCompare(rhs.symbol) == .orderedAscending
                }
                return nameComparison == .orderedAscending
            }
    }
#endif

    var body: some View {
        List {
            Section("系统通知") {
                HStack(spacing: 10) {
                    Image(systemName: notifications.canNotify ? "bell.badge.fill" : "bell.slash")
                        .foregroundStyle(notifications.canNotify ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("通知权限")
                        Text(notifications.statusTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if notifications.authorizationStatus == .notDetermined {
                    Button("允许通知") {
                        Task { _ = await notifications.requestAuthorization() }
                    }
                } else if notifications.authorizationStatus == .denied {
                    Button("打开系统设置") {
                        notifications.openSystemSettings()
                    }
                } else {
                    Button("重新检查权限") {
                        notifications.refreshAuthorizationStatus()
                    }
                }

                Text("每条价格提醒只发送一次，成功触发后会自动关闭；重新开启后可以再次提醒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
            if moduleSettings.isVisible(.currencyExchange) {
                Section("换汇价格提醒") {
                    if currencyStore.rateAlerts.isEmpty {
                        Text("暂无换汇价格提醒")
                            .foregroundStyle(.secondary)
                    }
                    if auth.isEditSessionReady {
                        ForEach(currencyStore.rateAlerts) { alert in
                            currencyAlertRow(alert)
                        }
                        .onDelete { offsets in
                            currencyStore.deleteRateAlerts(
                                ids: Set(offsets.map { currencyStore.rateAlerts[$0].id })
                            )
                        }
                    } else {
                        ForEach(currencyStore.rateAlerts) { alert in
                            currencyAlertRow(alert)
                        }
                    }

                    if auth.isEditSessionReady {
                        Button {
                            editingCurrencyAlert = CurrencyRateAlert()
                        } label: {
                            Label("添加换汇提醒", systemImage: "plus.circle")
                        }
                    }
                }
            }
#endif

#if MYTOOLS_FEATURE_STOCKS
            if moduleSettings.isVisible(.myStocks) {
                Section("股票价格提醒") {
                    if stockStore.priceAlerts.isEmpty {
                        Text("暂无股票价格提醒")
                            .foregroundStyle(.secondary)
                    }
                    if auth.isEditSessionReady {
                        ForEach(stockStore.priceAlerts) { alert in
                            stockAlertRow(alert)
                        }
                        .onDelete { offsets in
                            stockStore.deletePriceAlerts(
                                ids: Set(offsets.map { stockStore.priceAlerts[$0].id })
                            )
                        }
                    } else {
                        ForEach(stockStore.priceAlerts) { alert in
                            stockAlertRow(alert)
                        }
                    }

                    if configuredStocks.isEmpty {
                        Text("请先添加股票后再设置价格提醒。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if auth.isEditSessionReady {
                        Button {
                            editingStockAlert = StockPriceAlert(stockID: configuredStocks.first?.id)
                        } label: {
                            Label("添加股票提醒", systemImage: "plus.circle")
                        }
                    }
                }
            }
#endif
        }
        .navigationTitle("通知与提醒")
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AdminEditAccessButton()
            }
        }
        .onAppear {
            notifications.refreshAuthorizationStatus()
        }
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        .sheet(item: $editingCurrencyAlert) { alert in
            CurrencyRateAlertEditorView(alert: alert) { updated in
                currencyStore.upsertRateAlert(updated)
                requestNotificationPermissionIfNeeded()
            }
            .iOSLargeSheet()
        }
#endif
#if MYTOOLS_FEATURE_STOCKS
        .sheet(item: $editingStockAlert) { alert in
            StockPriceAlertEditorView(alert: alert, stocks: configuredStocks) { updated in
                stockStore.upsertPriceAlert(updated)
                requestNotificationPermissionIfNeeded()
            }
            .iOSLargeSheet()
        }
#endif
    }

#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
    private func currencyAlertRow(_ alert: CurrencyRateAlert) -> some View {
        HStack(spacing: 10) {
            Button {
                guard auth.isEditSessionReady else { return }
                editingCurrencyAlert = alert
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(CurrencyExchangeValueFormatter.amount(alert.amount, currency: alert.currency)) → CNY")
                        .font(.subheadline.weight(.medium))
                    Text("\(alert.direction.title) \(CurrencyExchangeValueFormatter.amount(alert.threshold, currency: .cny))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(
                "",
                isOn: Binding(
                    get: { currencyStore.rateAlerts.first(where: { $0.id == alert.id })?.isEnabled ?? false },
                    set: { enabled in
                        var updated = alert
                        updated.isEnabled = enabled
                        currencyStore.upsertRateAlert(updated)
                    }
                )
            )
            .labelsHidden()
            .disabled(!auth.isEditSessionReady)
        }
        .appListRowStyle()
    }
#endif

#if MYTOOLS_FEATURE_STOCKS
    private func stockAlertRow(_ alert: StockPriceAlert) -> some View {
        let stock = alert.stockID.flatMap { id in configuredStocks.first { $0.id == id } }
        let currencyCode = stock?.market.currencyCode ?? ""
        return HStack(spacing: 10) {
            Button {
                guard auth.isEditSessionReady else { return }
                editingStockAlert = alert
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stock.map { "\($0.displayName)（\($0.symbol)）" } ?? "股票已不存在")
                        .font(.subheadline.weight(.medium))
                    Text("\(alert.direction.title) \(StockValueFormatter.price(alert.threshold, currencyCode: currencyCode))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(
                "",
                isOn: Binding(
                    get: { stockStore.priceAlerts.first(where: { $0.id == alert.id })?.isEnabled ?? false },
                    set: { enabled in
                        var updated = alert
                        updated.isEnabled = enabled
                        stockStore.upsertPriceAlert(updated)
                    }
                )
            )
            .labelsHidden()
            .disabled(!auth.isEditSessionReady)
        }
        .appListRowStyle()
    }
#endif

    private func requestNotificationPermissionIfNeeded() {
        guard notifications.authorizationStatus == .notDetermined else { return }
        Task { _ = await notifications.requestAuthorization() }
    }
}

#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
private struct CurrencyRateAlertEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CurrencyRateAlert
    @State private var amountText: String
    @State private var thresholdText: String
    @State private var errorMessage = ""
    @State private var showingError = false
    let onSave: (CurrencyRateAlert) -> Void

    init(alert: CurrencyRateAlert, onSave: @escaping (CurrencyRateAlert) -> Void) {
        _draft = State(initialValue: alert)
        _amountText = State(initialValue: NSDecimalNumber(decimal: alert.amount).stringValue)
        _thresholdText = State(initialValue: NSDecimalNumber(decimal: alert.threshold).stringValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("提醒条件") {
                    Picker("币种", selection: $draft.currency) {
                        ForEach(CurrencyCode.selectableCases.filter { $0 != .cny }) { currency in
                            Text(currency.title).tag(currency)
                        }
                    }
                    TextField("数量", text: $amountText)
                        .multilineTextAlignment(.trailing)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                    Picker("方向", selection: $draft.direction) {
                        ForEach(PriceAlertDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    TextField("人民币阈值", text: $thresholdText)
                        .multilineTextAlignment(.trailing)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                    Toggle("启用提醒", isOn: $draft.isEnabled)
                }

                Section {
                    Text("例如数量填写 100、方向选择“低于”、阈值填写 670，表示 100 美元折合人民币低于 670 元时提醒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("换汇价格提醒")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                }
            }
            .alert("无法保存", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func save() {
        guard let amount = DecimalTextParser.decimal(from: amountText), amount > 0 else {
            reportError("数量必须大于零。")
            return
        }
        guard let threshold = DecimalTextParser.decimal(from: thresholdText), threshold > 0 else {
            reportError("人民币阈值必须大于零。")
            return
        }
        draft.amount = amount
        draft.threshold = threshold
        onSave(draft)
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
#endif

#if MYTOOLS_FEATURE_STOCKS
private struct StockPriceAlertEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StockPriceAlert
    @State private var thresholdText: String
    @State private var errorMessage = ""
    @State private var showingError = false
    let stocks: [StockHolding]
    let onSave: (StockPriceAlert) -> Void

    init(
        alert: StockPriceAlert,
        stocks: [StockHolding],
        onSave: @escaping (StockPriceAlert) -> Void
    ) {
        _draft = State(initialValue: alert)
        _thresholdText = State(initialValue: NSDecimalNumber(decimal: alert.threshold).stringValue)
        self.stocks = stocks
        self.onSave = onSave
    }

    private var selectedStock: StockHolding? {
        guard let stockID = draft.stockID else { return nil }
        return stocks.first { $0.id == stockID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("提醒条件") {
                    Picker(
                        "股票",
                        selection: Binding(
                            get: { draft.stockID ?? stocks.first?.id ?? UUID() },
                            set: { draft.stockID = $0 }
                        )
                    ) {
                        ForEach(StockMarket.topLevelOrder) { market in
                            let marketStocks = stocks.filter { $0.market == market }
                            if !marketStocks.isEmpty {
                                Section(market.title.replacingOccurrences(of: " ", with: "")) {
                                    ForEach(marketStocks) { stock in
                                        Text("\(stock.displayName)（\(stock.symbol)）")
                                            .tag(stock.id)
                                    }
                                }
                            }
                        }
                    }
                    Picker("方向", selection: $draft.direction) {
                        ForEach(PriceAlertDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    HStack {
                        Text("价格阈值")
                        Spacer()
                        TextField("必填", text: $thresholdText)
                            .multilineTextAlignment(.trailing)
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                        if let selectedStock {
                            Text(selectedStock.market.currencyCode)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("启用提醒", isOn: $draft.isEnabled)
                }
            }
            .navigationTitle("股票价格提醒")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(stocks.isEmpty)
                }
            }
            .alert("无法保存", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func save() {
        guard draft.stockID != nil else {
            reportError("请选择股票。")
            return
        }
        guard let threshold = DecimalTextParser.decimal(from: thresholdText), threshold > 0 else {
            reportError("价格阈值必须大于零。")
            return
        }
        draft.threshold = threshold
        onSave(draft)
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
#endif
