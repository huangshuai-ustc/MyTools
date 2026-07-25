import SwiftUI

struct AdminCardsView: View {
    var body: some View { HomeView() }
}

struct AccountDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    private let accountID: UUID
    private let backTitle: String
    @State private var editingAccount: BankAccount?
    @State private var viewingCard: BankCard?
    @State private var viewingDomesticSubaccount: DomesticSubaccount?
    @State private var viewingForeignSubaccount: ForeignSubaccount?
    @State private var sensitiveLoginInformationRevealed = false
    @State private var showingSensitiveAccess = false
    @AppStorage("card-sort-order-v1") private var cardSortOrderRawValue = CardSortOrder.nameAscending.rawValue
    @AppStorage("card-category-filter-v1") private var cardCategoryRawValue = CardCategoryFilter.all.rawValue

    init(account: BankAccount, backTitle: String) {
        accountID = account.id
        self.backTitle = backTitle
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
        .navigationTitle(account?.bankName.isEmpty == false ? account?.bankName ?? "" : "银行账户详情")
        .iOSLabeledBackButton(backTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let account, !store.cards(for: account).isEmpty {
                    FinanceCardDisplayMenu(
                        category: $cardCategoryRawValue,
                        sort: $cardSortOrderRawValue
                    )
                }
                if auth.isAdmin, let account {
                    Button { editingAccount = account } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("编辑银行档案")
                    .help("编辑银行档案")
                } else {
                    AdminEditAccessButton {
                        editingAccount = account
                    }
                }
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorView(
                account: account,
                isNew: !store.accounts.contains { $0.id == account.id },
                cards: store.cards(for: account)
            )
            .id(account.id)
            .iOSLargeSheet()
        }
        .sheet(item: $viewingCard) { card in
            CardDetailView(card: card)
                .iOSLargeSheet()
        }
        .sheet(item: $viewingDomesticSubaccount) { subaccount in
            DomesticSubaccountReadOnlyView(subaccount: subaccount)
                .iOSLargeSheet()
        }
        .sheet(item: $viewingForeignSubaccount) { subaccount in
            ForeignSubaccountReadOnlyView(subaccount: subaccount)
                .iOSLargeSheet()
        }
        .sheet(isPresented: $showingSensitiveAccess) {
            SensitiveAccessView { sensitiveLoginInformationRevealed = true }
                .iOSLargeSheet()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { sensitiveLoginInformationRevealed = false }
        }
    }

    @ViewBuilder
    private func accountList(_ account: BankAccount) -> some View {
        let cards = displayedCards(for: account)
        let allCards = store.cards(for: account)

        List {
            Section("账户概览") {
                LabeledContent("银行类型") {
                    BankRegionBadge(region: account.region)
                        .copyableText(account.region.title)
                }
                CopyableValueRow(title: "银行", value: account.bankName)
                CopyableValueRow(
                    title: account.region == .domestic ? "开户网点" : "分行/网点",
                    value: account.branchName
                )
                if !account.name.isEmpty {
                    CopyableValueRow(title: "备注名称", value: account.name)
                }
                LabeledContent("状态") { AccountStatusText(status: account.status) }
                LabeledContent("档案统计") {
                    Text(accountSummary(account, cards: allCards))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                CopyableValueRow(
                    title: "建立日期",
                    value: account.openedAt.formatted(date: .numeric, time: .omitted)
                )
            }

            if account.region == .overseas {
                subaccountsSection(account)
                cardsSection(account, cards: cards, allCards: allCards)
            } else {
                cardsSection(account, cards: cards, allCards: allCards)
                subaccountsSection(account)
            }

            loginSection(account)

            if account.region == .overseas {
                addressSection(account)
                remittanceSection(account)
            }

            if !account.note.isEmpty {
                Section("其他") {
                    optionalDetail("备注", account.note)
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
    }

    private func subaccountsSection(_ account: BankAccount) -> some View {
        let subaccounts = account.region == .domestic
            ? account.domesticSubaccounts.map(AnySubaccount.domestic)
            : account.foreignSubaccounts.map(AnySubaccount.foreign)

        return Section("子账户（\(subaccounts.count)）") {
            if subaccounts.isEmpty {
                Text(account.region == .domestic ? "暂无特别账户" : "暂无子账户")
                    .foregroundStyle(.secondary)
            }
            ForEach(subaccounts) { item in
                Button {
                    switch item {
                    case .domestic(let subaccount): viewingDomesticSubaccount = subaccount
                    case .foreign(let subaccount): viewingForeignSubaccount = subaccount
                    }
                } label: {
                    item.row
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cardsSection(
        _ account: BankAccount,
        cards: [BankCard],
        allCards: [BankCard]
    ) -> some View {
        let closedCardCount = allCards.filter { $0.status == .closed }.count
        return Section("银行卡（\(activeCardCount(allCards))）") {
            if cards.isEmpty {
                Text(allCards.isEmpty ? "暂无银行卡" : "当前筛选下暂无银行卡")
                    .foregroundStyle(.secondary)
            }
            ForEach(cards) { card in
                Button { viewingCard = card } label: {
                    CardRow(card: card, region: account.region)
                }
                .buttonStyle(.plain)
            }
            if closedCardCount > 0 {
                Label("\(closedCardCount) 张已销户卡保留在档案中", systemImage: "archivebox")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func loginSection(_ account: BankAccount) -> some View {
        let additionalFields = account.additionalLoginFields.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.value.isEmpty
        }
        let hasSensitive = !account.loginPassword.isEmpty || additionalFields.contains { $0.isSensitive }
        if !account.boundPhoneNumber.isEmpty
            || !account.loginAccount.isEmpty
            || !account.loginPassword.isEmpty
            || !additionalFields.isEmpty {
            Section("登录信息") {
                optionalDetail("绑定手机号", account.boundPhoneNumber)
                optionalDetail("登录账号", account.loginAccount)
                if !account.loginPassword.isEmpty {
                    ProtectedValueRow(
                        title: "登录密码",
                        value: account.loginPassword,
                        concealedValue: "••••••••",
                        isRevealed: auth.isAdmin || sensitiveLoginInformationRevealed
                    )
                }
                ForEach(additionalFields) { field in
                    if field.isSensitive {
                        ProtectedValueRow(
                            title: field.name,
                            value: field.value,
                            concealedValue: "••••••••",
                            isRevealed: auth.isAdmin || sensitiveLoginInformationRevealed
                        )
                    } else {
                        CopyableValueRow(title: field.name, value: field.value)
                    }
                }
                if !auth.isAdmin, hasSensitive {
                    Button { showingSensitiveAccess = true } label: {
                        Label(
                            sensitiveLoginInformationRevealed ? "重新验证身份" : "验证身份后查看敏感信息",
                            systemImage: sensitiveLoginInformationRevealed ? "lock.open" : "faceid"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addressSection(_ account: BankAccount) -> some View {
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
    }

    @ViewBuilder
    private func remittanceSection(_ account: BankAccount) -> some View {
        if !account.remittanceBankName.isEmpty
            || !account.remittanceBankAddress.isEmpty
            || !account.swift.isEmpty
            || !account.iban.isEmpty
            || !account.remittanceInstructions.isEmpty {
            Section("汇入汇款资料") {
                optionalDetail("收款银行正式名称", account.remittanceBankName)
                optionalDetail("收款银行地址", account.remittanceBankAddress)
                optionalDetail("SWIFT Code", account.swift)
                optionalDetail("IBAN", account.iban)
                optionalDetail("汇款说明", account.remittanceInstructions)
            }
        }
    }

    private func displayedCards(for account: BankAccount) -> [BankCard] {
        let cards = store.cards(for: account).filter {
            CardCategoryFilter(rawValue: cardCategoryRawValue)?.includes($0) ?? true
        }
        return (CardSortOrder(rawValue: cardSortOrderRawValue) ?? .nameAscending).sorted(cards)
    }

    private func activeCardCount(_ cards: [BankCard]) -> Int {
        cards.filter { $0.status != .closed }.count
    }

    private func accountSummary(_ account: BankAccount, cards: [BankCard]) -> String {
        let debit = cards.filter { $0.kind == .debit && $0.status != .closed }.count
        let credit = cards.filter { $0.kind == .credit && $0.status != .closed }.count
        let subaccountCount = account.region == .domestic
            ? account.domesticSubaccounts.count
            : account.foreignSubaccounts.count
        return account.region == .domestic
            ? "\(debit) 张借记卡 · \(credit) 张贷记卡 · \(subaccountCount) 个特别账户"
            : "\(subaccountCount) 个子账户 · \(debit) 张扣账卡 · \(credit) 张信用卡"
    }

    @ViewBuilder
    private func optionalDetail(_ title: String, _ value: String) -> some View {
        if !value.isEmpty { CopyableValueRow(title: title, value: value) }
    }
}

private enum AnySubaccount: Identifiable {
    case domestic(DomesticSubaccount)
    case foreign(ForeignSubaccount)

    var id: UUID {
        switch self {
        case .domestic(let value): return value.id
        case .foreign(let value): return value.id
        }
    }

    @ViewBuilder
    var row: some View {
        switch self {
        case .domestic(let value): DomesticSubaccountDetailRow(subaccount: value)
        case .foreign(let value): ForeignSubaccountDetailRow(subaccount: value)
        }
    }
}

private final class AccountEditorDraft: ObservableObject {
    @Published var account: BankAccount
    @Published var cards: [BankCard]

    init(account: BankAccount, cards: [BankCard]) {
        self.account = account
        self.cards = cards
    }
}

struct AccountEditorView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: AccountEditorDraft
    @State private var editingDomesticSubaccount: DomesticSubaccount?
    @State private var editingForeignSubaccount: ForeignSubaccount?
    @State private var editingCard: BankCard?
    @State private var editingAdditionalLoginField: AdditionalLoginField?
    @State private var showingAuthentication = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var didSave = false
    private let navigationTitle: String
    private let originalAttachmentIDs: Set<UUID>

    init(account: BankAccount, isNew: Bool, cards: [BankCard] = []) {
        _draft = StateObject(wrappedValue: AccountEditorDraft(account: account, cards: cards))
        navigationTitle = isNew ? "新增银行档案" : "编辑银行档案"
        originalAttachmentIDs = Set(cards.flatMap(\.statements).compactMap { $0.attachment?.id })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行类型") {
                    Picker("银行类型：", selection: $draft.account.region) {
                        ForEach(BankRegion.allCases) { region in Text(region.title).tag(region) }
                    }
                    .pickerStyle(.segmented)
                }

                bankInformationSection

                if draft.account.region == .overseas {
                    subaccountEditorSection
                    cardsEditorSection
                } else {
                    cardsEditorSection
                    subaccountEditorSection
                }

                loginEditorSection

                if draft.account.region == .overseas {
                    overseasAddressEditorSection
                    remittanceEditorSection
                }

                Section("其他") {
                    Picker("状态：", selection: $draft.account.status) {
                        ForEach(AccountStatus.allCases) { status in Text(status.title).tag(status) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("建立日期：", selection: $draft.account.openedAt, displayedComponents: .date)
                    HStack(alignment: .top, spacing: 4) {
                        Text("备注：").fixedSize(horizontal: true, vertical: true)
                        IMESafeMultilineTextField(prompt: "可选", text: $draft.account.note)
                    }
                }
            }
            .navigationTitle(navigationTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: requestSave) }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSLargeSheet()
            }
            .sheet(item: $editingCard) { card in
                CardEditorView(card: card, account: draft.account, onSave: upsertCard)
                    .id(card.id)
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
            .sheet(item: $editingAdditionalLoginField) { field in
                AdditionalLoginFieldEditorView(field: field, onSave: upsertAdditionalLoginField)
                    .id(field.id)
                    .iOSLargeSheet()
            }
            .onDisappear(perform: cleanUpUncommittedAttachments)
            .alert("无法保存银行档案", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var bankInformationSection: some View {
        Section("银行信息") {
            LabeledContent("银行名称：") {
                IMESafeTextField(prompt: "必填", text: $draft.account.bankName, alignment: .trailing)
            }
            LabeledContent(draft.account.region == .domestic ? "开户网点：" : "分行/网点：") {
                IMESafeTextField(prompt: "可选", text: $draft.account.branchName, alignment: .trailing)
            }
            LabeledContent("备注名称：") {
                IMESafeTextField(prompt: "可选", text: $draft.account.name, alignment: .trailing)
            }
            Text(draft.account.region == .domestic
                 ? "境内银行以银行卡为主；特别账户用于个人养老金等没有独立卡片的账户。"
                 : "境外银行以子账户为主；每个账户可单独记录账户号、币种和状态。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var subaccountEditorSection: some View {
        Section("子账户") {
            let domestic = draft.account.region == .domestic
            if domestic {
                if draft.account.domesticSubaccounts.isEmpty {
                    Text("暂无特别账户").foregroundStyle(.secondary)
                }
                ForEach(draft.account.domesticSubaccounts) { subaccount in
                    Button { editingDomesticSubaccount = subaccount } label: {
                        DomesticSubaccountRow(subaccount: subaccount)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteDomesticSubaccounts)
                Button { editingDomesticSubaccount = DomesticSubaccount() } label: {
                    Label("添加特别账户", systemImage: "plus.circle")
                }
            } else {
                if draft.account.foreignSubaccounts.isEmpty {
                    Text("暂无子账户").foregroundStyle(.secondary)
                }
                ForEach(draft.account.foreignSubaccounts) { subaccount in
                    Button { editingForeignSubaccount = subaccount } label: {
                        ForeignSubaccountRow(subaccount: subaccount)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteForeignSubaccounts)
                Button { editingForeignSubaccount = ForeignSubaccount() } label: {
                    Label("添加子账户", systemImage: "plus.circle")
                }
            }
        }
    }

    private var cardsEditorSection: some View {
        Section {
            if draft.cards.isEmpty {
                Text("暂无银行卡").foregroundStyle(.secondary)
            }
            ForEach(sortedDraftCards) { card in
                Button { editingCard = card } label: {
                    CardRow(card: card, region: draft.account.region)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteCards)
            Button { editingCard = BankCard() } label: {
                Label("添加银行卡", systemImage: "plus.circle")
            }
        } header: {
            Text(draft.account.region == .domestic ? "银行卡（主要档案）" : "银行卡/扣账卡")
        } footer: {
            Text(draft.account.region == .domestic
                 ? "境内银行的卡片是主要金融载体；子账户仅用于记录特殊账户。"
                 : "境外银行的卡片作为子账户之外的支付工具单独维护。")
        }
    }

    private var sortedDraftCards: [BankCard] {
        draft.cards.sorted {
            let lhs = $0.cardType.isEmpty ? $0.kind.title : $0.cardType
            let rhs = $1.cardType.isEmpty ? $1.kind.title : $1.cardType
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private var loginEditorSection: some View {
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
            ForEach(draft.account.additionalLoginFields) { field in
                Button { editingAdditionalLoginField = field } label: {
                    HStack(spacing: 12) {
                        Text(field.name.isEmpty ? "未命名字段" : field.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(field.isSensitive ? "••••••••" : (field.value.isEmpty ? "未填写" : field.value))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteAdditionalLoginFields)
            Button { editingAdditionalLoginField = AdditionalLoginField() } label: {
                Label("添加自定义登录字段", systemImage: "plus.circle")
            }
        }
    }

    private var overseasAddressEditorSection: some View {
        Section("地址信息") {
            multilineField("通讯地址（中文）：", prompt: "可选", text: $draft.account.correspondenceAddressChinese)
            multilineField("通讯地址（英文）：", prompt: "可选", text: $draft.account.correspondenceAddressEnglish)
            multilineField("住宅地址（中文）：", prompt: "可选", text: $draft.account.residentialAddressChinese)
            multilineField("住宅地址（英文）：", prompt: "可选", text: $draft.account.residentialAddressEnglish)
        }
    }

    private var remittanceEditorSection: some View {
        Section("汇入汇款资料") {
            multilineField("收款银行正式名称：", prompt: "例如 Bank of China (Hong Kong) Limited", text: $draft.account.remittanceBankName)
            multilineField("收款银行地址：", prompt: "例如 1 Garden Road, Central, Hong Kong", text: $draft.account.remittanceBankAddress)
            LabeledContent("SWIFT Code：") {
                IMESafeTextField(prompt: "例如 BKCHHKHHXXX", text: $draft.account.swift, alignment: .trailing, mode: .asciiUppercase)
            }
            LabeledContent("IBAN：") {
                IMESafeTextField(prompt: "可选", text: $draft.account.iban, alignment: .trailing, mode: .asciiUppercase)
            }
            multilineField("汇款说明：", prompt: "可选", text: $draft.account.remittanceInstructions)
        }
    }

    private func multilineField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            IMESafeMultilineTextField(prompt: prompt, text: text)
        }
    }

    private func requestSave() {
        commitPendingTextInput { save() }
    }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        var account = draft.account
        account.bankName = account.bankName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.bankName.isEmpty else {
            errorMessage = "请填写银行名称。"
            showingError = true
            return
        }
        account.remittanceSwiftCode = ""
        account.accountType = ""
        account.currency = ""
        account.accountNumber = ""
        if account.region == .domestic {
            account.swift = ""
            account.iban = ""
        }
        didSave = true
        store.replaceAccount(account, cards: draft.cards)
        dismiss()
    }

    private func upsertDomesticSubaccount(_ value: DomesticSubaccount) {
        if let index = draft.account.domesticSubaccounts.firstIndex(where: { $0.id == value.id }) {
            draft.account.domesticSubaccounts[index] = value
        } else {
            draft.account.domesticSubaccounts.append(value)
        }
    }

    private func deleteDomesticSubaccounts(at offsets: IndexSet) {
        draft.account.domesticSubaccounts.remove(atOffsets: offsets)
    }

    private func upsertForeignSubaccount(_ value: ForeignSubaccount) {
        if let index = draft.account.foreignSubaccounts.firstIndex(where: { $0.id == value.id }) {
            draft.account.foreignSubaccounts[index] = value
        } else {
            draft.account.foreignSubaccounts.append(value)
        }
    }

    private func deleteForeignSubaccounts(at offsets: IndexSet) {
        draft.account.foreignSubaccounts.remove(atOffsets: offsets)
    }

    private func upsertCard(_ card: BankCard) {
        if let index = draft.cards.firstIndex(where: { $0.id == card.id }) {
            draft.cards[index] = card
        } else {
            draft.cards.append(card)
        }
    }

    private func deleteCards(at offsets: IndexSet) {
        let ids = Set(offsets.map { sortedDraftCards[$0].id })
        for card in draft.cards where ids.contains(card.id) {
            for attachment in card.statements.compactMap(\.attachment)
            where !originalAttachmentIDs.contains(attachment.id) {
                store.deleteUncommittedAttachment(attachment)
            }
        }
        draft.cards.removeAll { ids.contains($0.id) }
    }

    private func upsertAdditionalLoginField(_ value: AdditionalLoginField) {
        if let index = draft.account.additionalLoginFields.firstIndex(where: { $0.id == value.id }) {
            draft.account.additionalLoginFields[index] = value
        } else {
            draft.account.additionalLoginFields.append(value)
        }
    }

    private func deleteAdditionalLoginFields(at offsets: IndexSet) {
        draft.account.additionalLoginFields.remove(atOffsets: offsets)
    }

    private func cleanUpUncommittedAttachments() {
        guard !didSave else { return }
        for attachment in draft.cards.flatMap(\.statements).compactMap(\.attachment)
        where !originalAttachmentIDs.contains(attachment.id) {
            store.deleteUncommittedAttachment(attachment)
        }
    }
}

private struct AdditionalLoginFieldEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var field: AdditionalLoginField
    let onSave: (AdditionalLoginField) -> Void

    init(field: AdditionalLoginField, onSave: @escaping (AdditionalLoginField) -> Void) {
        _field = State(initialValue: field)
        self.onSave = onSave
    }

    private var canSave: Bool {
        !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !field.value.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("字段内容") {
                    LabeledContent("名称：") {
                        IMESafeTextField(prompt: "例如电话银行密码", text: $field.name, alignment: .trailing)
                    }
                    LabeledContent("内容：") {
                        if field.isSensitive {
                            SecureField("请输入内容", text: $field.value).multilineTextAlignment(.trailing)
                        } else {
                            IMESafeTextField(prompt: "请输入内容", text: $field.value, alignment: .trailing)
                        }
                    }
                }
                Section { Toggle("作为敏感信息隐藏", isOn: $field.isSensitive) }
            }
            .navigationTitle(field.name.isEmpty ? "添加自定义字段" : "编辑自定义字段")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            field.name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(field)
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

private struct FinanceCardDisplayMenu: View {
    @Binding var category: String
    @Binding var sort: String

    private var selectedCategory: CardCategoryFilter {
        CardCategoryFilter(rawValue: category) ?? .all
    }

    private var selectedSort: CardSortOrder {
        CardSortOrder(rawValue: sort) ?? .nameAscending
    }

    var body: some View {
        Menu {
            Picker("卡片分类", selection: $category) {
                ForEach(CardCategoryFilter.allCases) { value in Text(value.title).tag(value.rawValue) }
            }
            Menu("排序依据：\(selectedSort.criterion.title)") {
                Picker("排序依据", selection: criterionBinding) {
                    ForEach(CardSortCriterion.allCases) { value in Text(value.title).tag(value) }
                }
            }
            Menu("排列顺序：\(selectedSort.direction.title)") {
                Picker("排列顺序", selection: directionBinding) {
                    ForEach(SortDirection.allCases) { value in Text(value.title).tag(value) }
                }
            }
        } label: {
            Image(systemName: selectedCategory == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("银行卡显示方式")
        .help("银行卡显示方式")
    }

    private var criterionBinding: Binding<CardSortCriterion> {
        Binding(
            get: { selectedSort.criterion },
            set: { sort = CardSortOrder.value(criterion: $0, direction: selectedSort.direction).rawValue }
        )
    }

    private var directionBinding: Binding<SortDirection> {
        Binding(
            get: { selectedSort.direction },
            set: { sort = CardSortOrder.value(criterion: selectedSort.criterion, direction: $0).rawValue }
        )
    }
}
