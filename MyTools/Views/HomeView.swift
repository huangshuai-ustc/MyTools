import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: CardStore
    @State private var query = ""
    @AppStorage("account-sort-order") private var sortOrderRawValue = AccountSortOrder.added.rawValue

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
        AccountSortOrder(rawValue: sortOrderRawValue) ?? .added
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
                        description: Text(query.isEmpty ? "请在“我的”中进入管理员模式后添加银行账户" : "请尝试其他银行、支行、卡种或持卡人关键词")
                    )
                }
                ForEach(filteredAccounts) { account in
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
                            let subtitle = [foreignAccountCount, account.accountType, account.branchName, account.name, account.currency]
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
            }
        }
        .navigationTitle("个人金融")
        .searchable(text: $query, prompt: "搜索银行、支行、卡种或持卡人")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AccountSortMenu(selection: $sortOrderRawValue)
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
#endif
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
            Label("\(store.accounts.count) 家银行", systemImage: "building.columns")
            Label("\(store.cards.count) 张卡", systemImage: "creditcard")
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
        return bankMatches || subaccountMatches
    }

    private func cardMatches(_ card: BankCard, searchTerm: String) -> Bool {
        let currencyTitles = card.currencies.map(\.title).joined(separator: " ")
        return [card.bankName, card.branchName, card.cardType, card.status.title, card.holderName, card.cardNumber, card.currencySummary, currencyTitles]
            .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
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
                    Text(card.bankName.isEmpty ? "未命名银行" : card.bankName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        Text(card.cardType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
