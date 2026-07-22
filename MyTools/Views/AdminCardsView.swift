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
                        let subtitle = [account.foreignAccountTypeSummary, account.branchName, account.name]
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
                LabeledContent("币种", value: account.currency.isEmpty ? "未填写" : account.currency)
                if account.region == .overseas {
                    LabeledContent("账户类型", value: account.foreignAccountTypeSummary.isEmpty ? "未添加" : account.foreignAccountTypeSummary)
                    LabeledContent("账号", value: account.accountNumber.isEmpty ? "未填写" : account.accountNumber)
                    LabeledContent("SWIFT", value: account.swift.isEmpty ? "未填写" : account.swift)
                    LabeledContent("IBAN", value: account.iban.isEmpty ? "未填写" : account.iban)
                }
                LabeledContent("状态", value: account.status)
                if auth.isAdmin {
                    Button("编辑银行账户") { editingAccount = account }
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
        case bankName, branchName, name, currency, accountNumber, swift, iban, status, note
    }

    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: AccountEditorDraft
    @FocusState private var focusedField: Field?
    @State private var showingAuthentication = false
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
                    TextField("银行名称", text: $draft.account.bankName)
                        .focused($focusedField, equals: .bankName)
                        .onSubmit { focusedField = .branchName }
                    TextField("支行名称", text: $draft.account.branchName)
                        .focused($focusedField, equals: .branchName)
                        .onSubmit { focusedField = .name }
                    TextField("账户名称", text: $draft.account.name)
                        .focused($focusedField, equals: .name)
                        .onSubmit { focusedField = .currency }
                    TextField("币种", text: $draft.account.currency)
                        .focused($focusedField, equals: .currency)
                        .onSubmit {
                            focusedField = draft.account.region == .overseas ? .accountNumber : .status
                        }
                }

                if draft.account.region == .overseas {
                    Section("境外账户类型") {
                        ForEach(ForeignAccountType.allCases) { type in
                            Toggle(type.title, isOn: foreignAccountTypeBinding(type))
                        }
                    }

                    Section("境外账户信息") {
                        TextField("账号", text: $draft.account.accountNumber)
                            .focused($focusedField, equals: .accountNumber)
                            .onSubmit { focusedField = .swift }
                        TextField("SWIFT", text: $draft.account.swift)
                            .focused($focusedField, equals: .swift)
                            .onSubmit { focusedField = .iban }
                        TextField("IBAN", text: $draft.account.iban)
                            .focused($focusedField, equals: .iban)
                            .onSubmit { focusedField = .status }
                    }
                }

                Section("其他") {
                    TextField("状态", text: $draft.account.status)
                        .focused($focusedField, equals: .status)
                    DatePicker("开户时间", selection: $draft.account.openedAt, displayedComponents: .date)
                    TextField("备注", text: $draft.account.note, axis: .vertical)
                        .focused($focusedField, equals: .note)
                        .lineLimit(3...6)
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
            account.foreignAccountTypes = []
            account.accountNumber = ""
            account.swift = ""
            account.iban = ""
        }
        store.upsertAccount(account)
        dismiss()
    }

    private func foreignAccountTypeBinding(_ type: ForeignAccountType) -> Binding<Bool> {
        Binding(
            get: { draft.account.foreignAccountTypes.contains(type) },
            set: { isSelected in
                if isSelected {
                    draft.account.foreignAccountTypes.insert(type)
                } else {
                    draft.account.foreignAccountTypes.remove(type)
                }
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
        _draft = StateObject(wrappedValue: CardEditorDraft(card: card))
        self.account = account
        navigationTitle = card.cardNumber.isEmpty ? "新增银行卡" : "编辑银行卡"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行卡") {
                    TextField("卡片名称", text: $draft.card.cardType)
                        .focused($focusedField, equals: .cardType)
                        .onSubmit { focusedField = .holderName }
                    Picker("卡片状态", selection: $draft.card.status) {
                        ForEach(CardStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("持卡人", text: $draft.card.holderName)
                        .focused($focusedField, equals: .holderName)
                        .onSubmit { focusedField = .cardNumber }
                    TextField("完整卡号", text: $draft.card.cardNumber)
                        .focused($focusedField, equals: .cardNumber)
                        .onSubmit { focusedField = .cvv }
                    SecureField("CVV", text: $draft.card.cvv)
                        .focused($focusedField, equals: .cvv)
                    Picker("有效期格式", selection: $draft.card.expiryPrecision) {
                        ForEach(CardExpiryPrecision.allCases) { precision in
                            Text(precision.title).tag(precision)
                        }
                    }
                    .pickerStyle(.segmented)
                    if draft.card.expiryPrecision == .yearMonth {
                        YearMonthPicker(date: $draft.card.expiryDate)
                    } else {
                        DatePicker("有效期", selection: $draft.card.expiryDate, displayedComponents: .date)
                    }
                    Toggle("Apple Pay", isOn: $draft.card.applePay)
                    Toggle("默认支付", isOn: $draft.card.defaultPayment)
                    TextField("备注", text: $draft.card.note, axis: .vertical)
                        .focused($focusedField, equals: .note)
                        .lineLimit(3...6)
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
        LabeledContent("有效期") {
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
