import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var regionFilter: BankRegionFilter = .all
    @State private var editingAccount: BankAccount?
    @AppStorage("account-sort-order-v2") private var sortOrderRawValue = AccountSortOrder.nameAscending.rawValue
    @AppStorage("finance-hide-inactive-banks-v1") private var hidesInactiveBanks = true

    private var filteredAccounts: [BankAccount] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedSortOrder.sorted(
            store.accounts
                .filter(regionFilter.includes)
                .filter { account in
                    (searchTerm.isEmpty
                     || accountMatches(account, searchTerm: searchTerm)
                     || store.cards(for: account).contains { cardMatches($0, searchTerm: searchTerm) })
                }
        )
    }

    private var activeAccounts: [BankAccount] {
        filteredAccounts.filter { !isInactive($0) }
    }

    private var inactiveAccounts: [BankAccount] {
        filteredAccounts.filter(isInactive)
    }

    private var selectedSortOrder: AccountSortOrder {
        AccountSortOrder(rawValue: sortOrderRawValue) ?? .nameAscending
    }

    var body: some View {
        List {
            Section {
                Picker("银行地区", selection: $regionFilter) {
                    ForEach(BankRegionFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("银行账户总览 · \(regionFilter.title)") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { financeMetrics }
                    VStack(alignment: .leading, spacing: 10) { financeMetrics }
                }
                .padding(.vertical, 3)
            }

            Section("银行账户") {
                if activeAccounts.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "暂无正常银行账户" : "没有搜索结果",
                        systemImage: query.isEmpty ? "building.columns" : "magnifyingglass",
                        description: Text(query.isEmpty ? "点右上角编辑并验证身份后添加银行账户" : "请尝试其他银行、支行、卡种或持卡人关键词")
                    )
                }
                if auth.isAdmin {
                    ForEach(activeAccounts) { account in
                        accountLink(account)
                    }
                    .onDelete { deleteAccounts(at: $0, from: activeAccounts) }
                } else {
                    ForEach(activeAccounts) { account in
                        accountLink(account)
                    }
                }
                if hidesInactiveBanks, hiddenInactiveCount > 0 {
                    Button {
                        hidesInactiveBanks = false
                    } label: {
                        Label("显示 \(hiddenInactiveCount) 家停用银行", systemImage: "eye")
                    }
                }
            }
            if !hidesInactiveBanks, !inactiveAccounts.isEmpty {
                Section("停用银行（\(inactiveAccounts.count)）") {
                    if auth.isAdmin {
                        ForEach(inactiveAccounts) { account in
                            accountLink(account)
                        }
                        .onDelete { deleteAccounts(at: $0, from: inactiveAccounts) }
                    } else {
                        ForEach(inactiveAccounts) { account in
                            accountLink(account)
                        }
                    }
                    Button {
                        hidesInactiveBanks = true
                    } label: {
                        Label("隐藏停用银行", systemImage: "eye.slash")
                    }
                }
            }
        }
        .navigationTitle("个人金融")
        .iOSLabeledBackButton("工具箱")
        .searchable(text: $query, prompt: "搜索银行、支行、卡种或持卡人")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AccountSortMenu(selection: $sortOrderRawValue)
                AdminEditAccessButton {
                    editingAccount = BankAccount()
                }
                if auth.isAdmin {
                    Button { editingAccount = BankAccount() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加银行账户")
                }
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
#endif
        .sheet(item: $editingAccount) { account in
            AccountEditorView(account: account, isNew: true, cards: [])
                .id(account.id)
                .iOSLargeSheet()
        }
    }

    private func accountLink(_ account: BankAccount) -> some View {
        NavigationLink {
            AccountDetailView(account: account, backTitle: "个人金融")
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BankRegionBadge(region: account.region)
                    Text(account.bankName.isEmpty ? "未命名银行" : account.bankName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if account.status != .normal {
                        AccountStatusText(status: account.status)
                    }
                }
                let cards = store.cards(for: account)
                let subtitle = [account.branchName, account.name]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(financeRowSummary(account, cards: cards))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                let currencies = financeCurrencies(account, cards: cards)
                if !currencies.isEmpty {
                    Text("币种：\(currencies)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func deleteAccounts(at offsets: IndexSet, from source: [BankAccount]) {
        guard auth.isAdmin else { return }
        let ids = Set(offsets.map { source[$0].id })
        let originalOffsets = IndexSet(store.accounts.indices.filter { ids.contains(store.accounts[$0].id) })
        store.deleteAccount(at: originalOffsets)
    }

    @ViewBuilder
    private var financeMetrics: some View {
        financeMetric("银行", value: visibleAccounts.count, systemImage: "building.columns")
        financeMetric("子账户", value: visibleSubaccountCount, systemImage: "list.bullet.rectangle")
        financeMetric("借记/扣账卡", value: visibleDebitCount, systemImage: "creditcard")
        financeMetric("贷记/信用卡", value: visibleCreditCount, systemImage: "creditcard.fill")
    }

    private func financeMetric(_ title: String, value: Int, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.headline.monospacedDigit())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleAccounts: [BankAccount] {
        store.accounts.filter(regionFilter.includes).filter { !hidesInactiveBanks || !isInactive($0) }
    }

    private var visibleSubaccountCount: Int {
        visibleAccounts.reduce(0) { total, account in
            total + (account.region == .domestic ? account.domesticSubaccounts.count : account.foreignSubaccounts.count)
        }
    }

    private var visibleDebitCount: Int {
        visibleAccounts.flatMap(store.cards(for:)).filter { $0.kind == .debit && $0.status != .closed }.count
    }

    private var visibleCreditCount: Int {
        visibleAccounts.flatMap(store.cards(for:)).filter { $0.kind == .credit && $0.status != .closed }.count
    }

    private var hiddenInactiveCount: Int {
        inactiveAccounts.count
    }

    private func accountMatches(_ account: BankAccount, searchTerm: String) -> Bool {
        let bankMatches = [account.region.title, account.bankName, account.branchName, account.name, account.accountType, account.currency, account.accountNumber, account.swift, account.iban]
            .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
        let subaccountMatches = account.foreignSubaccounts.contains { subaccount in
            [subaccount.type.title, subaccount.name, subaccount.accountNumber, subaccount.currencySummary]
                .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
        }
        let domesticSubaccountMatches = account.domesticSubaccounts.contains { subaccount in
            [subaccount.type, subaccount.name, subaccount.accountNumber, subaccount.currencySummary]
                .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
        }
        return bankMatches || subaccountMatches || domesticSubaccountMatches
    }

    private func cardMatches(_ card: BankCard, searchTerm: String) -> Bool {
        let currencyTitles = card.currencies.map(\.title).joined(separator: " ")
        let networks = card.networks.map(\.title).joined(separator: " " )
        return [card.bankName, card.branchName, card.kind.title, card.cardType, card.status.title, card.holderName, card.cardNumber, card.currencySummary, currencyTitles, networks]
            .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
    }

    private func financeRowSummary(_ account: BankAccount, cards: [BankCard]) -> String {
        let debit = cards.filter { $0.kind == .debit && $0.status != .closed }.count
        let credit = cards.filter { $0.kind == .credit && $0.status != .closed }.count
        let subs = account.region == .domestic ? account.domesticSubaccounts.count : account.foreignSubaccounts.count
        switch account.region {
        case .domestic:
            return "\(debit) 张借记卡 · \(credit) 张贷记卡 · \(subs) 个特别账户"
        case .overseas:
            return "\(subs) 个子账户 · \(debit) 张扣账卡 · \(credit) 张信用卡"
        }
    }

    private func financeCurrencies(_ account: BankAccount, cards: [BankCard]) -> String {
        let subaccountCurrencies = account.region == .domestic
            ? account.domesticSubaccounts.flatMap(\.currencies)
            : account.foreignSubaccounts.flatMap(\.currencies)
        return CurrencyCode.displayOrdered(Set(cards.flatMap(\.currencies) + subaccountCurrencies))
            .map(\.rawValue)
            .joined(separator: " · ")
    }

    private func isInactive(_ account: BankAccount) -> Bool {
        account.isInactiveFinanceArchive(cards: store.cards(for: account))
    }
}

struct CardRow: View {
    let card: BankCard
    var region: BankRegion? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "creditcard.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.cardType.isEmpty ? "未命名卡片" : card.cardType)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        CardKindText(kind: card.kind, region: region)
                        CardStatusText(status: card.status)
                    }
                }
                Text(card.cardNumber.isEmpty ? "未填写卡号" : "•••• " + String(card.cardNumber.suffix(4)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(card.cardNumber.isEmpty ? .tertiary : .secondary)
                if !card.currencySummary.isEmpty {
                    Text(card.currencySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !card.networks.isEmpty {
                    CardNetworkTags(networks: card.networks)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

enum BankRegionFilter: String, CaseIterable, Identifiable {
    case all
    case domestic
    case overseas

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .domestic: return "境内"
        case .overseas: return "境外"
        }
    }

    func includes(_ account: BankAccount) -> Bool {
        switch self {
        case .all: return true
        case .domestic: return account.region == .domestic
        case .overseas: return account.region == .overseas
        }
    }
}

struct CardNetworkTags: View {
    let networks: Set<CardNetwork>

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { tags }
            VStack(alignment: .leading, spacing: 4) { tags }
        }
    }

    @ViewBuilder
    private var tags: some View {
        ForEach(CardNetwork.allCases.filter(networks.contains)) { network in
            Text(network.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.indigo)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .copyableText(network.title)
        }
    }
}

struct CardKindText: View {
    let kind: BankCardKind
    var region: BankRegion? = nil

    private var color: Color {
        kind == .debit ? .blue : .purple
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var title: String {
        if region == .overseas, kind == .debit { return "扣账卡" }
        return kind.title
    }
}

struct BankRegionBadge: View {
    let region: BankRegion

    private var color: Color {
        region == .domestic ? .green : .orange
    }

    private var title: String {
        region == .domestic ? "境内" : "境外"
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(region.title)
    }
}

struct CardStatusText: View {
    let status: CardStatus

    private var color: Color {
        switch status {
        case .normal: return .green
        case .abnormal: return .orange
        case .closed: return .red
        }
    }

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

enum AccountSortOrder: String, CaseIterable, Identifiable {
    case added
    case addedReversed
    case openedNewest
    case openedOldest
    case nameAscending
    case nameDescending
    case domesticFirst
    case overseasFirst

    var id: Self { self }

    var title: String {
        switch self {
        case .added: return "添加顺序"
        case .addedReversed: return "添加顺序：新到旧"
        case .openedNewest: return "开户时间：新到旧"
        case .openedOldest: return "开户时间：旧到新"
        case .nameAscending: return "名称：A-Z"
        case .nameDescending: return "名称：Z-A"
        case .domesticFirst: return "境内优先"
        case .overseasFirst: return "境外优先"
        }
    }

    var criterion: AccountSortCriterion {
        switch self {
        case .added, .addedReversed: return .added
        case .openedNewest, .openedOldest: return .openedAt
        case .nameAscending, .nameDescending: return .name
        case .domesticFirst, .overseasFirst: return .region
        }
    }

    var direction: SortDirection {
        switch self {
        case .added, .openedOldest, .nameAscending, .domesticFirst: return .ascending
        case .addedReversed, .openedNewest, .nameDescending, .overseasFirst: return .descending
        }
    }

    static func value(criterion: AccountSortCriterion, direction: SortDirection) -> Self {
        switch (criterion, direction) {
        case (.added, .ascending): return .added
        case (.added, .descending): return .addedReversed
        case (.openedAt, .ascending): return .openedOldest
        case (.openedAt, .descending): return .openedNewest
        case (.name, .ascending): return .nameAscending
        case (.name, .descending): return .nameDescending
        case (.region, .ascending): return .domesticFirst
        case (.region, .descending): return .overseasFirst
        }
    }

    func sorted(_ accounts: [BankAccount]) -> [BankAccount] {
        switch self {
        case .added:
            return accounts
        case .addedReversed:
            return Array(accounts.reversed())
        case .openedNewest:
            return accounts.sorted {
                $0.openedAt == $1.openedAt ? isNameAscending($0, $1) : $0.openedAt > $1.openedAt
            }
        case .openedOldest:
            return accounts.sorted {
                $0.openedAt == $1.openedAt ? isNameAscending($0, $1) : $0.openedAt < $1.openedAt
            }
        case .nameAscending:
            return accounts.sorted(by: isNameAscending)
        case .nameDescending:
            return accounts.sorted {
                let comparison = displayName($0).localizedStandardCompare(displayName($1))
                return comparison == .orderedSame
                    ? $0.id.uuidString > $1.id.uuidString
                    : comparison == .orderedDescending
            }
        case .domesticFirst:
            return accounts.sorted { groupedBefore($0, $1, firstRegion: .domestic) }
        case .overseasFirst:
            return accounts.sorted { groupedBefore($0, $1, firstRegion: .overseas) }
        }
    }

    private func groupedBefore(_ lhs: BankAccount, _ rhs: BankAccount, firstRegion: BankRegion) -> Bool {
        guard lhs.region != rhs.region else { return isNameAscending(lhs, rhs) }
        return lhs.region == firstRegion
    }

    private func isNameAscending(_ lhs: BankAccount, _ rhs: BankAccount) -> Bool {
        let comparison = displayName(lhs).localizedStandardCompare(displayName(rhs))
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }

    private func displayName(_ account: BankAccount) -> String {
        account.bankName.isEmpty ? account.name : account.bankName
    }
}

enum AccountSortCriterion: String, CaseIterable, Identifiable {
    case added
    case openedAt
    case name
    case region

    var id: Self { self }

    var title: String {
        switch self {
        case .added: return "添加时间"
        case .openedAt: return "开户时间"
        case .name: return "名称"
        case .region: return "境内/境外"
        }
    }
}

enum SortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: Self { self }

    var title: String {
        switch self {
        case .ascending: return "升序"
        case .descending: return "降序"
        }
    }
}

struct AccountSortMenu: View {
    @Binding var selection: String

    private var selectedOrder: AccountSortOrder {
        AccountSortOrder(rawValue: selection) ?? .nameAscending
    }

    var body: some View {
        Menu {
            Menu("排序依据：\(selectedOrder.criterion.title)") {
                Picker("排序依据", selection: criterionBinding) {
                    ForEach(AccountSortCriterion.allCases) { criterion in
                        Text(criterion.title).tag(criterion)
                    }
                }
            }
            Menu("排列顺序：\(selectedOrder.direction.title)") {
                Picker("排列顺序", selection: directionBinding) {
                    ForEach(SortDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("账户排序")
        .help("账户排序")
    }

    private var criterionBinding: Binding<AccountSortCriterion> {
        Binding(
            get: { selectedOrder.criterion },
            set: { selection = AccountSortOrder.value(criterion: $0, direction: selectedOrder.direction).rawValue }
        )
    }

    private var directionBinding: Binding<SortDirection> {
        Binding(
            get: { selectedOrder.direction },
            set: { selection = AccountSortOrder.value(criterion: selectedOrder.criterion, direction: $0).rawValue }
        )
    }
}

enum CardSortOrder: String, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case openedNewest
    case openedOldest
    case debitFirst
    case creditFirst
    case status
    case statusReversed

    var id: Self { self }

    var title: String {
        switch self {
        case .nameAscending: return "名称：A-Z"
        case .nameDescending: return "名称：Z-A"
        case .openedNewest: return "开户时间：新到旧"
        case .openedOldest: return "开户时间：旧到新"
        case .debitFirst: return "借记卡优先"
        case .creditFirst: return "贷记卡优先"
        case .status: return "按状态"
        case .statusReversed: return "按状态：倒序"
        }
    }

    var criterion: CardSortCriterion {
        switch self {
        case .nameAscending, .nameDescending: return .name
        case .openedNewest, .openedOldest: return .openedAt
        case .debitFirst, .creditFirst: return .kind
        case .status, .statusReversed: return .status
        }
    }

    var direction: SortDirection {
        switch self {
        case .nameAscending, .openedOldest, .debitFirst, .status: return .ascending
        case .nameDescending, .openedNewest, .creditFirst, .statusReversed: return .descending
        }
    }

    static func value(criterion: CardSortCriterion, direction: SortDirection) -> Self {
        switch (criterion, direction) {
        case (.name, .ascending): return .nameAscending
        case (.name, .descending): return .nameDescending
        case (.openedAt, .ascending): return .openedOldest
        case (.openedAt, .descending): return .openedNewest
        case (.kind, .ascending): return .debitFirst
        case (.kind, .descending): return .creditFirst
        case (.status, .ascending): return .status
        case (.status, .descending): return .statusReversed
        }
    }

    func sorted(_ cards: [BankCard]) -> [BankCard] {
        switch self {
        case .nameAscending:
            return cards.sorted(by: isNameAscending)
        case .nameDescending:
            return cards.sorted {
                let comparison = displayName($0).localizedStandardCompare(displayName($1))
                return comparison == .orderedSame
                    ? tieBreak($0, $1)
                    : comparison == .orderedDescending
            }
        case .openedNewest:
            return cards.sorted {
                $0.openedAt == $1.openedAt ? isNameAscending($0, $1) : $0.openedAt > $1.openedAt
            }
        case .openedOldest:
            return cards.sorted {
                $0.openedAt == $1.openedAt ? isNameAscending($0, $1) : $0.openedAt < $1.openedAt
            }
        case .debitFirst:
            return cards.sorted { groupedBefore($0, $1, firstKind: .debit) }
        case .creditFirst:
            return cards.sorted { groupedBefore($0, $1, firstKind: .credit) }
        case .status, .statusReversed:
            return cards.sorted {
                let lhsRank = statusRank($0.status)
                let rhsRank = statusRank($1.status)
                if lhsRank == rhsRank { return isNameAscending($0, $1) }
                return self == .status ? lhsRank < rhsRank : lhsRank > rhsRank
            }
        }
    }

    private func groupedBefore(_ lhs: BankCard, _ rhs: BankCard, firstKind: BankCardKind) -> Bool {
        guard lhs.kind != rhs.kind else { return isNameAscending(lhs, rhs) }
        return lhs.kind == firstKind
    }

    private func isNameAscending(_ lhs: BankCard, _ rhs: BankCard) -> Bool {
        let comparison = displayName(lhs).localizedStandardCompare(displayName(rhs))
        return comparison == .orderedSame
            ? tieBreak(lhs, rhs)
            : comparison == .orderedAscending
    }

    private func tieBreak(_ lhs: BankCard, _ rhs: BankCard) -> Bool {
        let numberComparison = lhs.cardNumber.localizedStandardCompare(rhs.cardNumber)
        return numberComparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : numberComparison == .orderedAscending
    }

    private func displayName(_ card: BankCard) -> String {
        let name = card.cardType.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? card.kind.title : name
    }

    private func statusRank(_ status: CardStatus) -> Int {
        switch status {
        case .normal: return 0
        case .abnormal: return 1
        case .closed: return 2
        }
    }
}

enum CardSortCriterion: String, CaseIterable, Identifiable {
    case name
    case openedAt
    case kind
    case status

    var id: Self { self }

    var title: String {
        switch self {
        case .name: return "名称"
        case .openedAt: return "开户时间"
        case .kind: return "借记卡/贷记卡"
        case .status: return "状态"
        }
    }
}

enum CardCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case debit
    case credit

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部卡片"
        case .debit: return "借记卡"
        case .credit: return "贷记卡"
        }
    }

    func includes(_ card: BankCard) -> Bool {
        switch self {
        case .all: return true
        case .debit: return card.kind == .debit
        case .credit: return card.kind == .credit
        }
    }
}

struct CardSortMenu: View {
    @Binding var selection: String

    private var selectedOrder: CardSortOrder {
        CardSortOrder(rawValue: selection) ?? .nameAscending
    }

    var body: some View {
        Menu {
            Menu("排序依据：\(selectedOrder.criterion.title)") {
                Picker("排序依据", selection: criterionBinding) {
                    ForEach(CardSortCriterion.allCases) { criterion in
                        Text(criterion.title).tag(criterion)
                    }
                }
            }
            Menu("排列顺序：\(selectedOrder.direction.title)") {
                Picker("排列顺序", selection: directionBinding) {
                    ForEach(SortDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("银行卡排序")
        .help("银行卡排序")
    }

    private var criterionBinding: Binding<CardSortCriterion> {
        Binding(
            get: { selectedOrder.criterion },
            set: { selection = CardSortOrder.value(criterion: $0, direction: selectedOrder.direction).rawValue }
        )
    }

    private var directionBinding: Binding<SortDirection> {
        Binding(
            get: { selectedOrder.direction },
            set: { selection = CardSortOrder.value(criterion: selectedOrder.criterion, direction: $0).rawValue }
        )
    }
}

struct CardCategoryMenu: View {
    @Binding var selection: String

    private var isFiltering: Bool {
        selection != CardCategoryFilter.all.rawValue
    }

    var body: some View {
        Menu {
            Picker("卡片分类", selection: $selection) {
                ForEach(CardCategoryFilter.allCases) { category in
                    Text(category.title).tag(category.rawValue)
                }
            }
        } label: {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("银行卡分类")
        .help("银行卡分类")
    }
}
