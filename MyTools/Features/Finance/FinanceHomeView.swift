import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var editingAccount: BankAccount?
    @AppStorage("account-sort-order-v2") private var sortOrderRawValue = AccountSortOrder.nameAscending.rawValue

    private var filteredAccounts: [BankAccount] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let accounts: [BankAccount]
        if searchTerm.isEmpty {
            accounts = store.accounts
        } else {
            accounts = store.accounts.filter { account in
                accountMatches(account, searchTerm: searchTerm)
                    || store.cards(for: account).contains { cardMatches($0, searchTerm: searchTerm) }
            }
        }
        return selectedSortOrder.sorted(accounts)
    }

    private var selectedSortOrder: AccountSortOrder {
        AccountSortOrder(rawValue: sortOrderRawValue) ?? .nameAscending
    }

    var body: some View {
        List {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        financeTitle
                        Spacer(minLength: 12)
                        archiveSummary
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        financeTitle
                        archiveSummary
                    }
                }
                .padding(.vertical, 4)
            }

            Section("银行账户") {
                if filteredAccounts.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "暂无银行账户" : "没有搜索结果",
                        systemImage: query.isEmpty ? "building.columns" : "magnifyingglass",
                        description: Text(query.isEmpty ? "点右上角编辑并验证身份后添加银行账户" : "请尝试其他银行、支行、卡种或持卡人关键词")
                    )
                }
                if auth.isAdmin {
                    ForEach(filteredAccounts) { account in
                        accountLink(account)
                    }
                    .onDelete(perform: deleteAccounts)
                } else {
                    ForEach(filteredAccounts) { account in
                        accountLink(account)
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
            AccountEditorView(account: account, isNew: true)
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
                        .lineLimit(2)
                }
                Text("\(store.cards(for: account).count) 张银行卡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    private func deleteAccounts(at offsets: IndexSet) {
        let ids = Set(offsets.map { filteredAccounts[$0].id })
        let originalOffsets = IndexSet(store.accounts.indices.filter { ids.contains(store.accounts[$0].id) })
        store.deleteAccount(at: originalOffsets)
    }

    private var financeTitle: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("个人金融").font(.title2.bold())
                Text("银行账户与银行卡档案")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var archiveSummary: some View {
        HStack(spacing: 12) {
            Label("\(store.currentBankCount) 家银行", systemImage: "building.columns")
            Label("\(store.currentCardCount) 张卡", systemImage: "creditcard")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
        return [card.bankName, card.branchName, card.kind.title, card.cardType, card.status.title, card.holderName, card.cardNumber, card.currencySummary, currencyTitles]
            .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
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

struct CardRow: View {
    let card: BankCard

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
                        CardKindText(kind: card.kind)
                        CardStatusText(status: card.status)
                    }
                }
                Text("•••• " + String(card.cardNumber.suffix(4)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !card.currencySummary.isEmpty {
                    Text(card.currencySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct CardKindText: View {
    let kind: BankCardKind

    private var color: Color {
        kind == .debit ? .blue : .purple
    }

    var body: some View {
        Text(kind.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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
        case .openedNewest: return "开户时间：新到旧"
        case .openedOldest: return "开户时间：旧到新"
        case .nameAscending: return "名称：A-Z"
        case .nameDescending: return "名称：Z-A"
        case .domesticFirst: return "境内优先"
        case .overseasFirst: return "境外优先"
        }
    }

    func sorted(_ accounts: [BankAccount]) -> [BankAccount] {
        switch self {
        case .added:
            return accounts
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

struct AccountSortMenu: View {
    @Binding var selection: String

    var body: some View {
        Menu {
            Picker("排序方式", selection: $selection) {
                ForEach(AccountSortOrder.allCases) { order in
                    Text(order.title).tag(order.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("账户排序")
        .help("账户排序")
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
        case .status:
            return cards.sorted {
                let lhsRank = statusRank($0.status)
                let rhsRank = statusRank($1.status)
                return lhsRank == rhsRank ? isNameAscending($0, $1) : lhsRank < rhsRank
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

    var body: some View {
        Menu {
            Picker("排序方式", selection: $selection) {
                ForEach(CardSortOrder.allCases) { order in
                    Text(order.title).tag(order.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("银行卡排序")
        .help("银行卡排序")
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
