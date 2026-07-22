import SwiftUI

struct AdminCardsView: View {
    @EnvironmentObject private var store: CardStore
    @State private var editingAccount: BankAccount?
    @AppStorage("account-sort-order") private var sortOrderRawValue = AccountSortOrder.added.rawValue

    private var sortedAccounts: [BankAccount] {
        (AccountSortOrder(rawValue: sortOrderRawValue) ?? .added).sorted(store.accounts)
    }

    var body: some View {
        List {
            Section {
                Text("银行账户是一级档案；银行卡必须从对应账户详情中添加。删除账户会同时删除其银行卡。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(sortedAccounts) { account in
                NavigationLink {
                    AccountDetailView(account: account)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(account.bankName.isEmpty ? "未命名银行" : account.bankName)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            BankRegionBadge(region: account.region)
                        }
                        let foreignAccountCount = account.region == .overseas && !account.foreignSubaccounts.isEmpty
                            ? "\(account.foreignSubaccounts.count) 个境外账户"
                            : ""
                        let subtitle = [foreignAccountCount, account.accountType, account.branchName, account.name]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(store.cards(for: account).count) 张银行卡")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteAccounts)
        }
        .overlay {
            if store.accounts.isEmpty {
                ContentUnavailableView("暂无银行账户", systemImage: "building.columns")
            }
        }
        .navigationTitle("银行账户")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AccountSortMenu(selection: $sortOrderRawValue)
                Button { editingAccount = BankAccount() } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorView(account: account, isNew: true)
                .id(account.id)
                .iOSLargeSheet()
        }
    }

    private func deleteAccounts(at offsets: IndexSet) {
        let ids = Set(offsets.map { sortedAccounts[$0].id })
        let originalOffsets = IndexSet(store.accounts.indices.filter { ids.contains(store.accounts[$0].id) })
        store.deleteAccount(at: originalOffsets)
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
    private let accountID: UUID
    @State private var editingAccount: BankAccount?
    @State private var editingCard: BankCard?
    @State private var viewingCard: BankCard?

    init(account: BankAccount) {
        accountID = account.id
    }

    private var account: BankAccount? {
        store.accounts.first { $0.id == accountID }
    }

    var body: some View {
        Group {
            if let account {
                accountList(account)
            } else {
                ContentUnavailableView("账户已不存在", systemImage: "building.columns")
            }
        }
        .navigationTitle(account?.name.isEmpty == false ? account?.name ?? "" : "银行账户详情")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(item: $editingAccount) { account in
            AccountEditorView(account: account, isNew: false)
                .id(account.id)
                .iOSLargeSheet()
        }
        .sheet(item: $editingCard) { card in
            if let account {
                CardEditorView(card: card, account: account)
                    .id(card.id)
                    .iOSLargeSheet()
            }
        }
        .sheet(item: $viewingCard) { card in
            CardDetailView(card: card)
                .iOSLargeSheet()
        }
    }

    private func accountList(_ account: BankAccount) -> some View {
        List {
            Section("账户信息") {
                LabeledContent("银行类型") {
                    BankRegionBadge(region: account.region)
                }
                LabeledContent("银行", value: account.bankName)
                LabeledContent("支行", value: account.branchName.isEmpty ? "未填写" : account.branchName)
                if !account.name.isEmpty {
                    LabeledContent("备注名称", value: account.name)
                }
                if account.region == .domestic {
                    LabeledContent("账户类型", value: account.accountType.isEmpty ? "未填写" : account.accountType)
                    LabeledContent("币种", value: account.currency.isEmpty ? "未填写" : account.currency)
                } else {
                    LabeledContent("SWIFT", value: account.swift.isEmpty ? "未填写" : account.swift)
                    LabeledContent("IBAN", value: account.iban.isEmpty ? "未填写" : account.iban)
                }
                LabeledContent("状态", value: account.status)
                if auth.isAdmin {
                    Button("编辑银行账户") { editingAccount = account }
                }
            }

            if account.region == .overseas {
                Section("境外账户") {
                    if account.foreignSubaccounts.isEmpty {
                        Text("暂无境外账户").foregroundStyle(.secondary)
                    }
                    ForEach(account.foreignSubaccounts) { subaccount in
                        ForeignSubaccountDetailRow(subaccount: subaccount)
                    }
                }
            }

            Section("银行卡") {
                if store.cards(for: account).isEmpty {
                    Text("暂无银行卡").foregroundStyle(.secondary)
                }
                ForEach(store.cards(for: account)) { card in
                    if auth.isAdmin {
                        Button { editingCard = card } label: {
                            CardRow(card: card)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { viewingCard = card } label: {
                            CardRow(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if auth.isAdmin {
                    Button { editingCard = BankCard() } label: {
                        Label("在此账户添加银行卡", systemImage: "plus.circle")
                    }
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
    }
}

private final class AccountEditorDraft: ObservableObject {
    @Published var account: BankAccount

    init(account: BankAccount) {
        self.account = account
    }
}

struct AccountEditorView: View {
    private enum Field: Hashable {
        case bankName, branchName, name, accountType, currency, swift, iban, status, note
    }

    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: AccountEditorDraft
    @FocusState private var focusedField: Field?
    @State private var showingAuthentication = false
    @State private var editingForeignSubaccount: ForeignSubaccount?
    private let navigationTitle: String

    init(account: BankAccount, isNew: Bool) {
        _draft = StateObject(wrappedValue: AccountEditorDraft(account: account))
        navigationTitle = isNew ? "新增银行账户" : "编辑银行账户"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行类型") {
                    Picker("银行类型", selection: $draft.account.region) {
                        ForEach(BankRegion.allCases) { region in
                            Text(region.title).tag(region)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("账户信息") {
                    LabeledContent("银行名称：") {
                        TextField("未填写", text: $draft.account.bankName)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .bankName)
                            .onSubmit { focusedField = .branchName }
                    }
                    LabeledContent("支行名称：") {
                        TextField("未填写", text: $draft.account.branchName)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .branchName)
                            .onSubmit { focusedField = .name }
                    }
                    LabeledContent("备注名称：") {
                        TextField("可选", text: $draft.account.name)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .name)
                            .onSubmit {
                                focusedField = draft.account.region == .domestic ? .accountType : .swift
                            }
                    }
                    if draft.account.region == .domestic {
                        LabeledContent("账户类型：") {
                            TextField("例如私人理财", text: $draft.account.accountType)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .accountType)
                                .onSubmit { focusedField = .currency }
                        }
                        LabeledContent("币种：") {
                            TextField("未填写", text: $draft.account.currency)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .currency)
                                .onSubmit { focusedField = .status }
                        }
                    }
                }

                if draft.account.region == .overseas {
                    Section("银行识别信息") {
                        LabeledContent("SWIFT：") {
                            TextField("未填写", text: $draft.account.swift)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .swift)
                                .onSubmit { focusedField = .iban }
                        }
                        LabeledContent("IBAN：") {
                            TextField("未填写", text: $draft.account.iban)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .iban)
                                .onSubmit { focusedField = .status }
                        }
                    }

                    Section("境外账户") {
                        if draft.account.foreignSubaccounts.isEmpty {
                            Text("暂无境外账户").foregroundStyle(.secondary)
                        }
                        ForEach(draft.account.foreignSubaccounts) { subaccount in
                            Button { editingForeignSubaccount = subaccount } label: {
                                ForeignSubaccountRow(subaccount: subaccount)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteForeignSubaccounts)

                        Button { editingForeignSubaccount = ForeignSubaccount() } label: {
                            Label("添加境外账户", systemImage: "plus.circle")
                        }
                    }
                }

                Section("其他") {
                    LabeledContent("状态：") {
                        TextField("未填写", text: $draft.account.status)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .status)
                    }
                    DatePicker("开户时间：", selection: $draft.account.openedAt, displayedComponents: .date)
                    HStack(alignment: .top, spacing: 4) {
                        Text("备注：")
                            .fixedSize(horizontal: true, vertical: true)
                        TextField("未填写", text: $draft.account.note, axis: .vertical)
                            .multilineTextAlignment(.leading)
                            .focused($focusedField, equals: .note)
                            .lineLimit(3...6)
                    }
                }
            }
            .navigationTitle(navigationTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView()
                    .iOSLargeSheet()
            }
            .sheet(item: $editingForeignSubaccount) { subaccount in
                ForeignSubaccountEditorView(subaccount: subaccount, onSave: upsertForeignSubaccount)
                    .id(subaccount.id)
                    .iOSLargeSheet()
            }
        }
    }

    private func save() {
        focusedField = nil
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        var account = draft.account
        if account.region == .domestic {
            account.accountNumber = ""
            account.swift = ""
            account.iban = ""
        } else {
            account.currency = ""
            account.accountNumber = ""
        }
        store.upsertAccount(account)
        dismiss()
    }

    private func upsertForeignSubaccount(_ subaccount: ForeignSubaccount) {
        if let index = draft.account.foreignSubaccounts.firstIndex(where: { $0.id == subaccount.id }) {
            draft.account.foreignSubaccounts[index] = subaccount
        } else {
            draft.account.foreignSubaccounts.append(subaccount)
        }
    }

    private func deleteForeignSubaccounts(at offsets: IndexSet) {
        draft.account.foreignSubaccounts.remove(atOffsets: offsets)
    }
}

private struct ForeignSubaccountRow: View {
    let subaccount: ForeignSubaccount

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(subaccount.type.title).font(.headline)
                if !subaccount.name.isEmpty {
                    Text(subaccount.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(subaccount.accountNumber.isEmpty ? "未填写账户号" : subaccount.accountNumber)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(subaccount.accountNumber.isEmpty ? .secondary : .primary)
            if !subaccount.currencySummary.isEmpty {
                Text(subaccount.currencySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct ForeignSubaccountDetailRow: View {
    let subaccount: ForeignSubaccount

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !subaccount.name.isEmpty {
                Text(subaccount.name)
                    .font(.headline)
            }
            LabeledContent("账户类型", value: subaccount.type.title)
            LabeledContent("账户号", value: subaccount.accountNumber.isEmpty ? "未填写" : subaccount.accountNumber)
            LabeledContent("币种", value: subaccount.currencySummary.isEmpty ? "未选择" : subaccount.currencySummary)
        }
        .padding(.vertical, 4)
    }
}

private final class ForeignSubaccountDraft: ObservableObject {
    @Published var subaccount: ForeignSubaccount

    init(subaccount: ForeignSubaccount) {
        self.subaccount = subaccount
    }
}

private struct ForeignSubaccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: ForeignSubaccountDraft
    let onSave: (ForeignSubaccount) -> Void

    init(subaccount: ForeignSubaccount, onSave: @escaping (ForeignSubaccount) -> Void) {
        _draft = StateObject(wrappedValue: ForeignSubaccountDraft(subaccount: subaccount))
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.subaccount.accountNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.currencies.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    Picker("账户类型：", selection: $draft.subaccount.type) {
                        ForEach(ForeignAccountType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    LabeledContent("备注名称：") {
                        TextField("可选", text: $draft.subaccount.name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("账户号：") {
                        TextField("未填写", text: $draft.subaccount.accountNumber)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    CurrencySelectionRows(currencies: $draft.subaccount.currencies)
                } header: {
                    Text("币种")
                } footer: {
                    if draft.subaccount.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.subaccount.accountNumber.isEmpty ? "新增境外账户" : "编辑境外账户")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft.subaccount)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

}

private struct CurrencySelectionRows: View {
    @Binding var currencies: Set<CurrencyCode>

    var body: some View {
        ForEach(CurrencyCode.allCases) { currency in
            Toggle(currency.title, isOn: currencyBinding(currency))
        }
    }

    private func currencyBinding(_ currency: CurrencyCode) -> Binding<Bool> {
        Binding(
            get: { currencies.contains(currency) },
            set: { isSelected in
                var updatedCurrencies = currencies
                if isSelected {
                    updatedCurrencies.insert(currency)
                } else {
                    updatedCurrencies.remove(currency)
                }
                currencies = updatedCurrencies
            }
        )
    }
}

private final class CardEditorDraft: ObservableObject {
    @Published var card: BankCard

    init(card: BankCard) {
        self.card = card
    }
}

struct CardEditorView: View {
    private enum Field: Hashable {
        case cardType, holderName, cardNumber, cvv, note
    }

    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: CardEditorDraft
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
        _draft = StateObject(wrappedValue: CardEditorDraft(card: initialCard))
        self.account = account
        navigationTitle = isNewCard ? "新增银行卡" : "编辑银行卡"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行卡") {
                    LabeledContent("卡片名称：") {
                        TextField("未填写", text: $draft.card.cardType)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .cardType)
                            .onSubmit { focusedField = .holderName }
                    }
                    Picker("卡片状态：", selection: $draft.card.status) {
                        ForEach(CardStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("持卡人：") {
                        TextField(
                            account.region == .overseas ? "拼音，如 HUANG SHUAI" : "未填写",
                            text: $draft.card.holderName
                        )
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .holderName)
                            .onSubmit { focusedField = .cardNumber }
#if os(iOS)
                            .textContentType(.name)
                            .keyboardType(account.region == .overseas ? .asciiCapable : .default)
                            .textInputAutocapitalization(account.region == .overseas ? .characters : .words)
                            .autocorrectionDisabled(account.region == .overseas)
#endif
                    }
                    LabeledContent("完整卡号：") {
                        TextField("未填写", text: $draft.card.cardNumber)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .cardNumber)
                            .onSubmit { focusedField = .cvv }
                    }
                    LabeledContent("CVV：") {
                        SecureField("未填写", text: $draft.card.cvv)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .cvv)
                    }
                    Picker("有效期格式：", selection: $draft.card.expiryPrecision) {
                        ForEach(CardExpiryPrecision.allCases) { precision in
                            Text(precision.title).tag(precision)
                        }
                    }
                    .pickerStyle(.segmented)
                    if draft.card.expiryPrecision == .yearMonth {
                        YearMonthPicker(date: $draft.card.expiryDate)
                    } else {
                        DatePicker("有效期：", selection: $draft.card.expiryDate, displayedComponents: .date)
                    }
                    Toggle("Apple Pay", isOn: $draft.card.applePay)
                    Toggle("默认支付", isOn: $draft.card.defaultPayment)
                    HStack(alignment: .top, spacing: 4) {
                        Text("备注：")
                            .fixedSize(horizontal: true, vertical: true)
                        TextField("未填写", text: $draft.card.note, axis: .vertical)
                            .multilineTextAlignment(.leading)
                            .focused($focusedField, equals: .note)
                            .lineLimit(3...6)
                    }
                }

                Section {
                    CurrencySelectionRows(currencies: $draft.card.currencies)
                } header: {
                    Text("币种")
                } footer: {
                    if draft.card.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("归属账户：\(account.name.isEmpty ? "未命名账户" : account.name)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(navigationTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(draft.card.currencies.isEmpty)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView()
                    .iOSLargeSheet()
            }
        }
    }

    private func save() {
        focusedField = nil
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

    private var selectedYear: Int {
        calendar.component(.year, from: date)
    }

    private var selectedMonth: Int {
        calendar.component(.month, from: date)
    }

    private var years: ClosedRange<Int> {
        let currentYear = calendar.component(.year, from: Date())
        return min(currentYear - 10, selectedYear)...max(currentYear + 30, selectedYear)
    }

    var body: some View {
        LabeledContent("有效期：") {
            HStack(spacing: 4) {
                Picker("年份", selection: yearBinding) {
                    ForEach(Array(years), id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("年")

                Picker("月份", selection: monthBinding) {
                    ForEach(1...12, id: \.self) { month in
                        Text(String(format: "%02d", month)).tag(month)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("月")
            }
        }
    }

    private var yearBinding: Binding<Int> {
        Binding(
            get: { selectedYear },
            set: { updateDate(year: $0, month: selectedMonth) }
        )
    }

    private var monthBinding: Binding<Int> {
        Binding(
            get: { selectedMonth },
            set: { updateDate(year: selectedYear, month: $0) }
        )
    }

    private func updateDate(year: Int, month: Int) {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = 1
        if let newDate = calendar.date(from: components) {
            date = newDate
        }
    }
}
