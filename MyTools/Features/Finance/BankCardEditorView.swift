import SwiftUI

private final class BankCardEditorDraft: ObservableObject {
    @Published var card: BankCard
    init(card: BankCard) { self.card = card }
}

struct CardEditorView: View {
    private enum Field: Hashable { case cvv }

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: BankCardEditorDraft
    @FocusState private var focusedField: Field?
    @State private var showingAuthentication = false
    let account: BankAccount
    private let navigationTitle: String

    init(card: BankCard, account: BankAccount) {
        var initialCard = card
        let isNewCard = card.accountID == nil
        if isNewCard, account.region == .domestic, initialCard.currencies.isEmpty {
            initialCard.currencies = [.cny]
        }
        _draft = StateObject(wrappedValue: BankCardEditorDraft(card: initialCard))
        self.account = account
        navigationTitle = isNewCard ? "新增银行卡" : "编辑银行卡"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行卡") {
                    Picker("卡片类型：", selection: $draft.card.kind) {
                        ForEach(BankCardKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("卡片名称：") {
                        IMESafeTextField(prompt: "可选，如 Visa 白金卡", text: $draft.card.cardType, alignment: .trailing)
                    }
                    Picker("卡片状态：", selection: $draft.card.status) {
                        ForEach(CardStatus.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("持卡人：") {
                        IMESafeTextField(
                            prompt: account.region == .overseas ? "拼音，如 HUANG SHUAI" : "未填写",
                            text: $draft.card.holderName,
                            alignment: .trailing,
                            mode: account.region == .overseas ? .asciiUppercase : .text
                        )
                    }
                    LabeledContent("完整卡号：") {
                        IMESafeTextField(prompt: "未填写", text: $draft.card.cardNumber, alignment: .trailing)
                    }
                    LabeledContent("CVV：") {
                        SecureField("未填写", text: $draft.card.cvv)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .cvv)
                    }
                    Picker("有效期格式：", selection: $draft.card.expiryPrecision) {
                        ForEach(CardExpiryPrecision.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if draft.card.expiryPrecision == .yearMonth {
                        YearMonthPicker(date: $draft.card.expiryDate)
                    } else {
                        DatePicker("有效期：", selection: $draft.card.expiryDate, displayedComponents: .date)
                    }
                    DatePicker("开户时间：", selection: $draft.card.openedAt, displayedComponents: .date)
                    Toggle("Apple Pay", isOn: $draft.card.applePay)
                    Toggle("默认支付", isOn: $draft.card.defaultPayment)
                    HStack(alignment: .top, spacing: 4) {
                        Text("备注：").fixedSize(horizontal: true, vertical: true)
                        IMESafeMultilineTextField(prompt: "未填写", text: $draft.card.note)
                    }
                }
                Section {
                    CurrencySelectionRows(currencies: $draft.card.currencies)
                } header: {
                    Text("币种")
                } footer: {
                    if draft.card.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存").foregroundStyle(.red)
                    }
                }
                Section {
                    Text("归属账户：\(account.name.isEmpty ? "未命名账户" : account.name)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(navigationTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave).disabled(draft.card.currencies.isEmpty)
                }
            }
            .sheet(isPresented: $showingAuthentication) { AuthenticationView().iOSLargeSheet() }
        }
    }

    private func requestSave() { commitPendingTextInput { save() } }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        store.upsertCard(draft.card, in: account)
        dismiss()
    }
}

private struct YearMonthPicker: View {
    @Binding var date: Date
    private let calendar = Calendar.autoupdatingCurrent

    private var selectedYear: Int { calendar.component(.year, from: date) }
    private var selectedMonth: Int { calendar.component(.month, from: date) }
    private var years: ClosedRange<Int> {
        let currentYear = calendar.component(.year, from: Date())
        return min(currentYear - 10, selectedYear)...max(currentYear + 30, selectedYear)
    }

    var body: some View {
        LabeledContent("有效期：") {
            HStack(spacing: 4) {
                Picker("年份", selection: yearBinding) {
                    ForEach(Array(years), id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Text("年")
                Picker("月份", selection: monthBinding) {
                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Text("月")
            }
        }
    }

    private var yearBinding: Binding<Int> {
        Binding(get: { selectedYear }, set: { updateDate(year: $0, month: selectedMonth) })
    }
    private var monthBinding: Binding<Int> {
        Binding(get: { selectedMonth }, set: { updateDate(year: selectedYear, month: $0) })
    }
    private func updateDate(year: Int, month: Int) {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = 1
        if let newDate = calendar.date(from: components) { date = newDate }
    }
}
