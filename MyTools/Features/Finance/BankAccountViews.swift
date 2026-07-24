import SwiftUI

struct AdminCardsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editingAccount: BankAccount?
    @AppStorage("account-sort-order-v2") private var sortOrderRawValue = AccountSortOrder.nameAscending.rawValue

    private var sortedAccounts: [BankAccount] {
        (AccountSortOrder(rawValue: sortOrderRawValue) ?? .nameAscending).sorted(store.accounts)
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
                    AccountDetailView(account: account, backTitle: "银行账户")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(account.bankName.isEmpty ? "未命名银行" : account.bankName)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            BankRegionBadge(region: account.region)
                        }
                        let subtitle = [subaccountSummary(for: account), account.branchName, account.name]
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
        .iOSLabeledBackButton("我的")
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

    private func subaccountSummary(for account: BankAccount) -> String {
        switch account.region {
        case .domestic:
            return account.domesticSubaccounts.isEmpty ? "" : "\(account.domesticSubaccounts.count) 个境内账户"
        case .overseas:
            return account.foreignSubaccounts.isEmpty ? "" : "\(account.foreignSubaccounts.count) 个境外账户"
        }
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    private let accountID: UUID
    @State private var editingAccount: BankAccount?
    @State private var editingDomesticSubaccount: DomesticSubaccount?
    @State private var editingForeignSubaccount: ForeignSubaccount?
    @State private var editingCard: BankCard?
    @State private var viewingCard: BankCard?
    @AppStorage("card-sort-order-v1") private var cardSortOrderRawValue = CardSortOrder.nameAscending.rawValue
    @AppStorage("card-category-filter-v1") private var cardCategoryRawValue = CardCategoryFilter.all.rawValue
    private let backTitle: String

    init(account: BankAccount, backTitle: String) {
        accountID = account.id
        self.backTitle = backTitle
    }

    private var account: BankAccount? {
        store.accounts.first { $0.id == accountID }
    }

    private var selectedCardSortOrder: CardSortOrder {
        CardSortOrder(rawValue: cardSortOrderRawValue) ?? .nameAscending
    }

    private var selectedCardCategory: CardCategoryFilter {
        CardCategoryFilter(rawValue: cardCategoryRawValue) ?? .all
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
        .iOSLabeledBackButton(backTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                CardCategoryMenu(selection: $cardCategoryRawValue)
                CardSortMenu(selection: $cardSortOrderRawValue)
                AdminEditAccessButton()
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorView(account: account, isNew: false)
                .id(account.id)
                .iOSLargeSheet()
        }
        .sheet(item: $editingDomesticSubaccount) { subaccount in
            DomesticSubaccountEditorView(subaccount: subaccount, onSave: upsertDomesticSubaccount)
                .id(subaccount.id)
                .iOSLargeSheet()
        }
        .sheet(item: $editingForeignSubaccount) { subaccount in
            ForeignSubaccountEditorView(subaccount: subaccount, onSave: upsertForeignSubaccount)
                .id(subaccount.id)
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
        let allCards = store.cards(for: account)
        let displayedCards = selectedCardSortOrder.sorted(allCards.filter(selectedCardCategory.includes))

        return List {
            Section("账户信息") {
                LabeledContent("银行类型") {
                    BankRegionBadge(region: account.region)
                }
                LabeledContent("银行", value: account.bankName)
                LabeledContent("支行", value: account.branchName.isEmpty ? "未填写" : account.branchName)
                if !account.name.isEmpty {
                    LabeledContent("备注名称", value: account.name)
                }
                if account.region == .overseas {
                    LabeledContent("SWIFT", value: account.swift.isEmpty ? "未填写" : account.swift)
                    LabeledContent("IBAN", value: account.iban.isEmpty ? "未填写" : account.iban)
                }
                LabeledContent("状态", value: account.status)
                if !account.boundPhoneNumber.isEmpty {
                    LabeledContent("绑定手机号", value: account.boundPhoneNumber)
                }
                if !account.loginAccount.isEmpty {
                    LabeledContent("登录账号", value: account.loginAccount)
                }
                if !account.loginPassword.isEmpty {
                    ProtectedValueRow(title: "登录密码", value: account.loginPassword)
                }
                if auth.isAdmin {
                    Button("编辑银行账户") { editingAccount = account }
                }
            }

            if account.region == .overseas {
                if !account.correspondenceAddressChinese.isEmpty
                    || !account.correspondenceAddressEnglish.isEmpty
                    || !account.residentialAddressChinese.isEmpty
                    || !account.residentialAddressEnglish.isEmpty {
                    Section("地址信息") {
                        optionalDetail("通讯地址（中文）", account.correspondenceAddressChinese)
                        optionalDetail("通讯地址（英文）", account.correspondenceAddressEnglish)
                        optionalDetail("住宅地址（中文）", account.residentialAddressChinese)
                        optionalDetail("住宅地址（英文）", account.residentialAddressEnglish)
                    }
                }

                if !account.remittanceBankName.isEmpty
                    || !account.remittanceBankAddress.isEmpty
                    || !account.remittanceSwiftCode.isEmpty
                    || !account.remittanceInstructions.isEmpty {
                    Section("汇入汇款资料") {
                        optionalDetail("收款银行正式名称", account.remittanceBankName)
                        optionalDetail("收款银行地址", account.remittanceBankAddress)
                        optionalDetail("收款 SWIFT Code", account.remittanceSwiftCode)
                        optionalDetail("汇款说明", account.remittanceInstructions)
                    }
                }
            }

            if account.region == .domestic {
                Section("境内账户") {
                    if account.domesticSubaccounts.isEmpty {
                        Text("暂无境内账户").foregroundStyle(.secondary)
                    }
                    if auth.isAdmin {
                        ForEach(account.domesticSubaccounts) { subaccount in
                            Button { editingDomesticSubaccount = subaccount } label: {
                                DomesticSubaccountDetailRow(subaccount: subaccount)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            deleteDomesticSubaccounts(at: offsets, from: account)
                        }
                    } else {
                        ForEach(account.domesticSubaccounts) { subaccount in
                            DomesticSubaccountDetailRow(subaccount: subaccount)
                        }
                    }
                    if auth.isAdmin {
                        Button { editingDomesticSubaccount = DomesticSubaccount() } label: {
                            Label("添加境内账户", systemImage: "plus.circle")
                        }
                    }
                }
            }

            if account.region == .overseas {
                Section("境外账户") {
                    if account.foreignSubaccounts.isEmpty {
                        Text("暂无境外账户").foregroundStyle(.secondary)
                    }
                    if auth.isAdmin {
                        ForEach(account.foreignSubaccounts) { subaccount in
                            Button { editingForeignSubaccount = subaccount } label: {
                                ForeignSubaccountDetailRow(subaccount: subaccount)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            deleteForeignSubaccounts(at: offsets, from: account)
                        }
                    } else {
                        ForEach(account.foreignSubaccounts) { subaccount in
                            ForeignSubaccountDetailRow(subaccount: subaccount)
                        }
                    }
                    if auth.isAdmin {
                        Button { editingForeignSubaccount = ForeignSubaccount() } label: {
                            Label("添加境外账户", systemImage: "plus.circle")
                        }
                    }
                }
            }

            Section("银行卡") {
                if displayedCards.isEmpty {
                    Text(allCards.isEmpty ? "暂无银行卡" : "当前分类暂无银行卡")
                        .foregroundStyle(.secondary)
                }
                if auth.isAdmin {
                    ForEach(displayedCards) { card in
                        Button { editingCard = card } label: {
                            CardRow(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        deleteCards(at: offsets, from: displayedCards)
                    }
                } else {
                    ForEach(displayedCards) { card in
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

    private func upsertDomesticSubaccount(_ subaccount: DomesticSubaccount) {
        guard var updatedAccount = account else { return }
        if let index = updatedAccount.domesticSubaccounts.firstIndex(where: { $0.id == subaccount.id }) {
            updatedAccount.domesticSubaccounts[index] = subaccount
        } else {
            updatedAccount.domesticSubaccounts.append(subaccount)
        }
        store.upsertAccount(updatedAccount)
    }

    private func deleteDomesticSubaccounts(at offsets: IndexSet, from account: BankAccount) {
        guard auth.isAdmin else { return }
        var updatedAccount = account
        updatedAccount.domesticSubaccounts.remove(atOffsets: offsets)
        store.upsertAccount(updatedAccount)
    }

    @ViewBuilder
    private func optionalDetail(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(title) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private func upsertForeignSubaccount(_ subaccount: ForeignSubaccount) {
        guard var updatedAccount = account else { return }
        if let index = updatedAccount.foreignSubaccounts.firstIndex(where: { $0.id == subaccount.id }) {
            updatedAccount.foreignSubaccounts[index] = subaccount
        } else {
            updatedAccount.foreignSubaccounts.append(subaccount)
        }
        store.upsertAccount(updatedAccount)
    }

    private func deleteForeignSubaccounts(at offsets: IndexSet, from account: BankAccount) {
        guard auth.isAdmin else { return }
        var updatedAccount = account
        updatedAccount.foreignSubaccounts.remove(atOffsets: offsets)
        store.upsertAccount(updatedAccount)
    }

    private func deleteCards(at offsets: IndexSet, from displayedCards: [BankCard]) {
        guard auth.isAdmin else { return }
        for index in offsets {
            store.delete(displayedCards[index])
        }
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
        case bankName, branchName, name, swift, iban, status, note
    }

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: AccountEditorDraft
    @FocusState private var focusedField: Field?
    @State private var showingAuthentication = false
    @State private var editingDomesticSubaccount: DomesticSubaccount?
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
                        IMESafeTextField(prompt: "未填写", text: $draft.account.bankName, alignment: .trailing)
                    }
                    LabeledContent("支行名称：") {
                        IMESafeTextField(prompt: "未填写", text: $draft.account.branchName, alignment: .trailing)
                    }
                    LabeledContent("备注名称：") {
                        IMESafeTextField(prompt: "可选", text: $draft.account.name, alignment: .trailing)
                    }
                }

                Section("登录信息") {
                    LabeledContent("绑定手机号：") {
                        IMESafeTextField(prompt: "可选", text: $draft.account.boundPhoneNumber, alignment: .trailing)
                    }
                    LabeledContent("登录账号：") {
                        IMESafeTextField(prompt: "可选", text: $draft.account.loginAccount, alignment: .trailing)
                    }
                    LabeledContent("登录密码：") {
                        SecureField("可选", text: $draft.account.loginPassword)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if draft.account.region == .domestic {
                    Section("境内账户") {
                        if draft.account.domesticSubaccounts.isEmpty {
                            Text("暂无境内账户").foregroundStyle(.secondary)
                        }
                        ForEach(draft.account.domesticSubaccounts) { subaccount in
                            Button { editingDomesticSubaccount = subaccount } label: {
                                DomesticSubaccountRow(subaccount: subaccount)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteDomesticSubaccounts)

                        Button { editingDomesticSubaccount = DomesticSubaccount() } label: {
                            Label("添加境内账户", systemImage: "plus.circle")
                        }
                    }
                }

                if draft.account.region == .overseas {
                    Section("银行识别信息") {
                        LabeledContent("SWIFT：") {
                            IMESafeTextField(prompt: "未填写", text: $draft.account.swift, alignment: .trailing, mode: .asciiUppercase)
                        }
                        LabeledContent("IBAN：") {
                            IMESafeTextField(prompt: "未填写", text: $draft.account.iban, alignment: .trailing, mode: .asciiUppercase)
                        }
                    }

                    Section("地址信息") {
                        multilineField("通讯地址（中文）：", prompt: "可选", text: $draft.account.correspondenceAddressChinese)
                        multilineField("通讯地址（英文）：", prompt: "可选", text: $draft.account.correspondenceAddressEnglish)
                        multilineField("住宅地址（中文）：", prompt: "可选", text: $draft.account.residentialAddressChinese)
                        multilineField("住宅地址（英文）：", prompt: "可选", text: $draft.account.residentialAddressEnglish)
                    }

                    Section("汇入汇款资料") {
                        multilineField("收款银行正式名称：", prompt: "例如 Bank of China (Hong Kong) Limited", text: $draft.account.remittanceBankName)
                        multilineField("收款银行地址：", prompt: "例如 1 Garden Road, Central, Hong Kong", text: $draft.account.remittanceBankAddress)
                        LabeledContent("收款 SWIFT Code：") {
                            IMESafeTextField(prompt: "例如 BKCHHKHHXXX", text: $draft.account.remittanceSwiftCode, alignment: .trailing, mode: .asciiUppercase)
                        }
                        multilineField("汇款说明：", prompt: "可选", text: $draft.account.remittanceInstructions)
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
                        IMESafeTextField(prompt: "未填写", text: $draft.account.status, alignment: .trailing)
                    }
                    DatePicker("开户时间：", selection: $draft.account.openedAt, displayedComponents: .date)
                    HStack(alignment: .top, spacing: 4) {
                        Text("备注：")
                            .fixedSize(horizontal: true, vertical: true)
                        IMESafeMultilineTextField(prompt: "未填写", text: $draft.account.note)
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
                    Button("保存", action: requestSave)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSLargeSheet()
            }
            .sheet(item: $editingForeignSubaccount) { subaccount in
                ForeignSubaccountEditorView(subaccount: subaccount, onSave: upsertForeignSubaccount)
                    .id(subaccount.id)
                    .iOSLargeSheet()
            }
            .sheet(item: $editingDomesticSubaccount) { subaccount in
                DomesticSubaccountEditorView(subaccount: subaccount, onSave: upsertDomesticSubaccount)
                    .id(subaccount.id)
                    .iOSLargeSheet()
            }
        }
    }

    private func requestSave() {
        commitPendingTextInput {
            save()
        }
    }

    private func multilineField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            IMESafeMultilineTextField(prompt: prompt, text: text)
        }
    }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        var account = draft.account
        if account.region == .domestic {
            account.accountType = ""
            account.currency = ""
            account.accountNumber = ""
            account.swift = ""
            account.iban = ""
        } else {
            account.accountType = ""
            account.currency = ""
            account.accountNumber = ""
        }
        store.upsertAccount(account)
        dismiss()
    }

    private func upsertDomesticSubaccount(_ subaccount: DomesticSubaccount) {
        if let index = draft.account.domesticSubaccounts.firstIndex(where: { $0.id == subaccount.id }) {
            draft.account.domesticSubaccounts[index] = subaccount
        } else {
            draft.account.domesticSubaccounts.append(subaccount)
        }
    }

    private func deleteDomesticSubaccounts(at offsets: IndexSet) {
        draft.account.domesticSubaccounts.remove(atOffsets: offsets)
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
