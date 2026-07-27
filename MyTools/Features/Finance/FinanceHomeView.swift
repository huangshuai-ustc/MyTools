import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var regionFilter: BankRegionFilter = .all
    @State private var editingAccount: BankAccount?
    @AppStorage("account-sort-order-v2") private var sortOrderRawValue = AccountSortOrder.nameAscending.rawValue
    @State private var showsInactiveBanks = false

    private var selectedSortOrder: AccountSortOrder {
        AccountSortOrder(rawValue: sortOrderRawValue) ?? .nameAscending
    }

    var body: some View {
        let snapshot = financeSnapshot
        List {
            Section {
                Picker("银行地区", selection: $regionFilter) {
                    ForEach(BankRegionFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { financeMetrics(snapshot) }
                    VStack(alignment: .leading, spacing: 10) { financeMetrics(snapshot) }
                }
                .appListRowStyle()
            }

            Section("银行账户") {
                if snapshot.activeAccounts.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "暂无正常银行账户" : "没有搜索结果",
                        systemImage: query.isEmpty ? "building.columns" : "magnifyingglass",
                        description: Text(query.isEmpty ? "点右上角编辑并验证身份后添加银行账户" : "请尝试其他银行、支行、卡种或持卡人关键词")
                    )
                }
                if auth.isAdmin {
                    ForEach(snapshot.activeAccounts) { account in
                        accountLink(account, cards: snapshot.cards(for: account))
                    }
                    .onDelete { deleteAccounts(at: $0, from: snapshot.activeAccounts) }
                } else {
                    ForEach(snapshot.activeAccounts) { account in
                        accountLink(account, cards: snapshot.cards(for: account))
                    }
                }
                if !showsInactiveBanks, !snapshot.inactiveAccounts.isEmpty {
                    HiddenItemsVisibilityButton(
                        itemsDescription: "\(snapshot.inactiveAccounts.count) 家停用银行",
                        isShowing: $showsInactiveBanks
                    )
                }
            }
            if showsInactiveBanks, !snapshot.inactiveAccounts.isEmpty {
                Section("停用银行（\(snapshot.inactiveAccounts.count)）") {
                    if auth.isAdmin {
                        ForEach(snapshot.inactiveAccounts) { account in
                            accountLink(account, cards: snapshot.cards(for: account))
                        }
                        .onDelete { deleteAccounts(at: $0, from: snapshot.inactiveAccounts) }
                    } else {
                        ForEach(snapshot.inactiveAccounts) { account in
                            accountLink(account, cards: snapshot.cards(for: account))
                        }
                    }
                    HiddenItemsVisibilityButton(
                        itemsDescription: "\(snapshot.inactiveAccounts.count) 家停用银行",
                        isShowing: $showsInactiveBanks
                    )
                }
            }
        }
        .navigationTitle(ToolModule.personalFinance.title)
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
        .onDisappear {
            showsInactiveBanks = false
        }
    }

    private func accountLink(_ account: BankAccount, cards: [BankCard]) -> some View {
        NavigationLink {
            AccountDetailView(account: account, backTitle: ToolModule.personalFinance.title)
        } label: {
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
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
                Text(financeRowSummary(account, cards: cards))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .appListRowStyle()
    }

    private func deleteAccounts(at offsets: IndexSet, from source: [BankAccount]) {
        guard auth.isAdmin else { return }
        let ids = Set(offsets.map { source[$0].id })
        let originalOffsets = IndexSet(store.accounts.indices.filter { ids.contains(store.accounts[$0].id) })
        store.deleteAccount(at: originalOffsets)
    }

    @ViewBuilder
    private func financeMetrics(_ snapshot: FinanceViewSnapshot) -> some View {
        financeMetric("银行", value: snapshot.visibleAccountCount, systemImage: "building.columns")
        financeMetric("子账户", value: snapshot.visibleSubaccountCount, systemImage: "list.bullet.rectangle")
        financeMetric("借记卡", value: snapshot.visibleDebitCount, systemImage: "creditcard")
        financeMetric("信用卡", value: snapshot.visibleCreditCount, systemImage: "creditcard.fill")
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

    private var financeSnapshot: FinanceViewSnapshot {
        var cardsByAccountID: [UUID: [BankCard]] = [:]
        for card in store.cards {
            guard let accountID = card.accountID else { continue }
            cardsByAccountID[accountID, default: []].append(card)
        }

        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredAccounts = selectedSortOrder.sorted(
            store.accounts
                .filter(regionFilter.includes)
                .filter { account in
                    searchTerm.isEmpty
                        || accountMatches(account, searchTerm: searchTerm)
                        || cardsByAccountID[account.id, default: []].contains {
                            cardMatches($0, searchTerm: searchTerm)
                        }
                }
        )
        let activeAccounts = filteredAccounts.filter {
            !isInactive($0, cards: cardsByAccountID[$0.id, default: []])
        }
        let inactiveAccounts = filteredAccounts.filter {
            isInactive($0, cards: cardsByAccountID[$0.id, default: []])
        }
        let visibleAccounts = store.accounts.filter(regionFilter.includes).filter { account in
            showsInactiveBanks
                || !isInactive(account, cards: cardsByAccountID[account.id, default: []])
        }

        var subaccountCount = 0
        var debitCount = 0
        var creditCount = 0
        for account in visibleAccounts {
            subaccountCount += account.activeSubaccountCount
            for card in cardsByAccountID[account.id, default: []] where card.status != .closed {
                if card.kind == .debit { debitCount += 1 } else { creditCount += 1 }
            }
        }

        return FinanceViewSnapshot(
            activeAccounts: activeAccounts,
            inactiveAccounts: inactiveAccounts,
            cardsByAccountID: cardsByAccountID,
            visibleAccountCount: visibleAccounts.count,
            visibleSubaccountCount: subaccountCount,
            visibleDebitCount: debitCount,
            visibleCreditCount: creditCount
        )
    }

    private func accountMatches(_ account: BankAccount, searchTerm: String) -> Bool {
        let bankMatches = [account.region.title, account.bankName, account.branchName, account.name, account.swift, account.iban]
            .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
        let subaccountMatches = account.foreignSubaccounts.contains { subaccount in
            [subaccount.typeTitle, subaccount.name, subaccount.accountNumber, subaccount.currencySummary]
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
        return [card.kind.title, card.cardType, card.status.title, card.holderName, card.cardNumber, card.currencySummary, currencyTitles, networks]
            .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
    }

    private func financeRowSummary(_ account: BankAccount, cards: [BankCard]) -> String {
        let debit = cards.filter { $0.kind == .debit && $0.status != .closed }.count
        let credit = cards.filter { $0.kind == .credit && $0.status != .closed }.count
        let subs = account.activeSubaccountCount
        switch account.region {
        case .domestic:
            return "\(debit) 张借记卡 · \(credit) 张信用卡 · \(subs) 个子账户"
        case .overseas:
            return "\(subs) 个子账户 · \(debit) 张借记卡 · \(credit) 张信用卡"
        }
    }

    private func isInactive(_ account: BankAccount, cards: [BankCard]) -> Bool {
        account.isInactiveFinanceArchive(cards: cards)
    }
}

private struct FinanceViewSnapshot {
    let activeAccounts: [BankAccount]
    let inactiveAccounts: [BankAccount]
    let cardsByAccountID: [UUID: [BankCard]]
    let visibleAccountCount: Int
    let visibleSubaccountCount: Int
    let visibleDebitCount: Int
    let visibleCreditCount: Int

    func cards(for account: BankAccount) -> [BankCard] {
        cardsByAccountID[account.id, default: []]
    }
}

struct CardRow: View {
    let card: BankCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "creditcard.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.cardType.isEmpty ? "未命名卡片" : card.cardType)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        CardKindText(kind: card.kind)
                        CardStatusText(status: card.status)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(card.cardNumber.isEmpty ? "未填写卡号" : "•••• " + String(card.cardNumber.suffix(4)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(card.cardNumber.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !card.networks.isEmpty {
                        CardNetworkTags(networks: card.networks)
                    }
                }
            }
        }
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
        return kind.title
    }
}

struct BankRegionBadge: View {
    let region: BankRegion

    private var color: Color {
        region == .domestic ? .cyan : .mint
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

enum AccountSortOrder: String {
    case nameAscending
    case nameDescending

    var direction: SortDirection {
        switch self {
        case .nameAscending: return .ascending
        case .nameDescending: return .descending
        }
    }

    func sorted(_ accounts: [BankAccount]) -> [BankAccount] {
        switch self {
        case .nameAscending:
            return accounts.sorted(by: isNameAscending)
        case .nameDescending:
            return accounts.sorted {
                let comparison = displayName($0).localizedStandardCompare(displayName($1))
                return comparison == .orderedSame
                    ? $0.id.uuidString > $1.id.uuidString
                    : comparison == .orderedDescending
            }
        }
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

enum SortDirection {
    case ascending
    case descending

    var title: String {
        switch self {
        case .ascending: return "升序"
        case .descending: return "降序"
        }
    }

    var indicator: String {
        switch self {
        case .ascending: return "↑"
        case .descending: return "↓"
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
            Button {
                selection = selectedOrder == .nameAscending
                    ? AccountSortOrder.nameDescending.rawValue
                    : AccountSortOrder.nameAscending.rawValue
            } label: {
                Text("名称  \(selectedOrder.direction.indicator)")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("账户排序：名称，\(selectedOrder.direction.title)")
        .help("账户排序：名称，\(selectedOrder.direction.title)")
    }

}

enum CardSortOrder: String {
    case nameAscending
    case nameDescending

    var direction: SortDirection {
        switch self {
        case .nameAscending: return .ascending
        case .nameDescending: return .descending
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
                    ? tieBreak($1, $0)
                    : comparison == .orderedDescending
            }
        }
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
        case .credit: return "信用卡"
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
