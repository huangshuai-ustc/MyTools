#if MYTOOLS_FEATURE_FINANCE
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.appFontScale) private var fontScale
    @State private var query = ""
    @State private var regionFilter: BankRegionFilter = .all
    @State private var editingAccount: BankAccount?
    @State private var showsInactiveBanks = false

    private var availableRegionFilters: [BankRegionFilter] {
        let regions = Set(store.accounts.map(\.region))
        return BankRegionFilter.allCases.filter { filter in
            filter == .all || filter.region.map(regions.contains) ?? false
        }
    }

    var body: some View {
        let snapshot = financeSnapshot
        List {
            Section {
                Picker("银行地区", selection: $regionFilter) {
                    ForEach(availableRegionFilters) { filter in
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

            Section("银行") {
                if snapshot.activeAccounts.isEmpty, snapshot.inactiveAccounts.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "暂无银行" : "没有搜索结果",
                        systemImage: query.isEmpty ? "building.columns" : "magnifyingglass",
                        description: Text(query.isEmpty ? "点右上角编辑并验证身份后添加银行账户" : "请尝试其他银行、支行、卡种或持卡人关键词")
                    )
#if os(macOS)
                    .frame(maxWidth: .infinity, minHeight: 300)
#endif
                }
                ForEach(snapshot.activeAccounts) { account in
                    accountLink(account, cards: snapshot.cards(for: account))
                }
                if !snapshot.inactiveAccounts.isEmpty {
                    HiddenItemsVisibilityButton(
                        itemsDescription: "\(snapshot.inactiveAccounts.count) 家停用银行",
                        isShowing: $showsInactiveBanks
                    )
                }
                if showsInactiveBanks {
                    ForEach(snapshot.inactiveAccounts) { account in
                        accountLink(account, cards: snapshot.cards(for: account))
                    }
                }
            }
        }
        .appNavigationTitle(ToolModule.personalFinance.title)
        .iOSLabeledBackButton("工具")
        .searchable(text: $query, prompt: "搜索银行、支行、卡种或持卡人")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    var account = BankAccount()
                    account.additionalLoginFields = store.makeLoginFields(for: .domestic)
                    editingAccount = account
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加银行账户")
            }
        }
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
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
        .onChange(of: availableRegionFilters) { _, filters in
            if !filters.contains(regionFilter) {
                regionFilter = .all
            }
        }
    }

    private func accountLink(_ account: BankAccount, cards: [BankCard]) -> some View {
        NavigationLink {
            AccountDetailView(account: account, backTitle: ToolModule.personalFinance.title)
        } label: {
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BankRegionBadge(region: account.region)
                    Text(account.bankName.isEmpty ? "未命名银行" : account.bankName)
                        .appFont(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if account.status != .normal {
                        AccountStatusText(status: account.status)
                    }
                }
                Text(financeRowSummary(account, cards: cards))
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .appListRowStyle()
        .appDeleteSwipeAction(isEnabled: true) {
            store.deleteAccount(id: account.id)
        }
    }

    private func deleteAccount(id: UUID) {
        store.deleteAccount(id: id)
    }

    @ViewBuilder
    private func financeMetrics(_ snapshot: FinanceViewSnapshot) -> some View {
        financeMetric("银行", value: snapshot.visibleAccountCount, systemImage: "building.columns")
        financeMetric("借记卡", value: snapshot.visibleDebitCount, systemImage: "creditcard")
        financeMetric("信用卡", value: snapshot.visibleCreditCount, systemImage: "creditcard.fill")
        financeMetric("子账户", value: snapshot.visibleSubaccountCount, systemImage: "list.bullet.rectangle")
    }

    private func financeMetric(_ title: String, value: Int, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").appFont(.headline.monospacedDigit())
                Text(title).appFont(.caption).foregroundStyle(.secondary)
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
        let filteredAccounts = store.accounts
                .filter(regionFilter.includes)
                .filter { account in
                    searchTerm.isEmpty
                        || accountMatches(account, searchTerm: searchTerm)
                        || cardsByAccountID[account.id, default: []].contains {
                            cardMatches($0, searchTerm: searchTerm)
                        }
                }
                .sorted { lhs, rhs in
                    AppAlphabeticalSort.isOrderedBefore(
                        accountDisplayName(lhs),
                        accountDisplayName(rhs),
                        lhsTieBreaker: lhs.id.uuidString,
                        rhsTieBreaker: rhs.id.uuidString
                    )
                }
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
        let bankMatches = [account.region.title, account.bankName, account.branchName, account.swift, account.iban]
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
        let additionalCredentials = card.additionalCredentials.flatMap {
            let credentialNetworks = $0.networks.map(\.title).joined(separator: " ")
            let credentialCurrencies = $0.currencies.map(\.title).joined(separator: " ")
            return [$0.name, $0.cardNumber, credentialNetworks, credentialCurrencies, $0.holderName, $0.status.title]
        }.joined(separator: " ")
        return [card.kind.title, card.cardType, card.branchName ?? "", card.status.title, card.holderName, card.cardNumber, card.currencySummary, currencyTitles, networks, additionalCredentials]
            .contains { $0.localizedCaseInsensitiveContains(searchTerm) }
    }

    private func financeRowSummary(_ account: BankAccount, cards: [BankCard]) -> String {
        let debit = cards.filter { $0.kind == .debit && $0.status != .closed }.count
        let credit = cards.filter { $0.kind == .credit && $0.status != .closed }.count
        let subs = account.activeSubaccountCount
        return "\(debit) 张借记卡 · \(credit) 张信用卡 · \(subs) 个子账户"
    }

    private func isInactive(_ account: BankAccount, cards: [BankCard]) -> Bool {
        account.isInactiveFinanceArchive(cards: cards)
    }

    private func accountDisplayName(_ account: BankAccount) -> String {
        account.bankName.isEmpty ? "未命名银行" : account.bankName
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
    @Environment(\.appFontScale) private var fontScale
    let card: BankCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "creditcard.fill")
                .appFont(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.cardType.isEmpty ? "未命名卡片" : card.cardType)
                        .appFont(.headline)
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
                        .appFont(.subheadline.monospacedDigit())
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

    var region: BankRegion? {
        switch self {
        case .all: return nil
        case .domestic: return .domestic
        case .overseas: return .overseas
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
                .appFont(.caption2.weight(.semibold))
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
            .appFont(.caption.weight(.semibold))
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
            .appFont(.caption2.weight(.semibold))
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
            .appFont(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

#endif
