#if MYTOOLS_FEATURE_FINANCE
import SwiftUI
import MapKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum BankNavigationApplication: String, CaseIterable, Identifiable {
    case appleMaps
    case amap
    case baiduMaps
    case googleMaps

    var id: Self { self }

    var title: String {
        switch self {
        case .appleMaps: return "Apple 地图"
        case .amap: return "高德地图"
        case .baiduMaps: return "百度地图"
        case .googleMaps: return "Google Maps"
        }
    }

    var systemImage: String {
        switch self {
        case .appleMaps: return "map"
        case .amap: return "location.north.line"
        case .baiduMaps: return "map.fill"
        case .googleMaps: return "globe"
        }
    }
}

enum BankBranchNavigationService {
    @MainActor
    static func open(
        _ application: BankNavigationApplication,
        branchName: String,
        location: BankBranchLocation?
    ) {
        let resolvedLocation = location?.isValid == true
            ? location!
            : .defaultLocation
        let coordinate = "\(resolvedLocation.latitude),\(resolvedLocation.longitude)"
        let name = branchName.isEmpty ? "分行/网点" : branchName
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let url: URL?
        switch application {
        case .appleMaps:
            url = URL(string: "maps://?daddr=\(coordinate)&q=\(encodedName)&dirflg=d")
        case .amap:
            url = URL(string: "iosamap://navi?lat=\(resolvedLocation.latitude)&lon=\(resolvedLocation.longitude)&dev=0&style=2")
        case .baiduMaps:
            url = URL(string: "baidumap://map/direction?destination=latlng:\(resolvedLocation.latitude),\(resolvedLocation.longitude)|name:\(encodedName)&mode=driving")
        case .googleMaps:
            url = URL(string: "comgooglemaps://?daddr=\(coordinate)&directionsmode=driving")
        }
        guard let url else { return }
#if os(iOS)
        UIApplication.shared.open(url)
#elseif os(macOS)
        NSWorkspace.shared.open(url)
#endif
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.scenePhase) private var scenePhase
    private let accountID: UUID
    private let backTitle: String
    @State private var editingAccount: BankAccount?
    @State private var viewingCard: BankCard?
    @State private var viewingDomesticSubaccount: DomesticSubaccount?
    @State private var viewingForeignSubaccount: ForeignSubaccount?
    @State private var editingBranchLocation: BankAccount?
    @State private var sensitiveLoginInformationRevealed = false
    @State private var showingSensitiveAccess = false
    @State private var showsClosedCards = false
    @State private var showsClosedSubaccounts = false

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
        .appNavigationTitle(account?.bankName.isEmpty == false ? account?.bankName ?? "" : "银行账户详情")
        .iOSLabeledBackButton(backTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let account {
                    Button { editingAccount = account } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("编辑银行档案")
                    .help("编辑银行档案")
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
            DomesticSubaccountReadOnlyView(subaccount: subaccount, accountID: accountID)
                .iOSLargeSheet()
        }
        .sheet(item: $viewingForeignSubaccount) { subaccount in
            ForeignSubaccountReadOnlyView(subaccount: subaccount, accountID: accountID)
                .iOSLargeSheet()
        }
        .sheet(item: $editingBranchLocation) { account in
            BankBranchLocationPickerView(
                branchName: account.branchName,
                location: account.branchLocation
            ) { branch in
                var updated = account
                updated.branchLocation = branch.location
                if !branch.name.isEmpty {
                    updated.branchName = branch.name
                }
                store.replaceAccount(updated, cards: store.cards(for: account))
            }
            .iOSLargeSheet()
        }
        .sheet(isPresented: $showingSensitiveAccess) {
            SensitiveAccessView { sensitiveLoginInformationRevealed = true }
                .iOSAuthenticationSheet()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { sensitiveLoginInformationRevealed = false }
        }
        .onDisappear {
            showsClosedCards = false
            showsClosedSubaccounts = false
            sensitiveLoginInformationRevealed = false
        }
    }

    @ViewBuilder
    private func accountList(_ account: BankAccount) -> some View {
        let cards = displayedCards(for: account)
        let allCards = store.cards(for: account)

        List {
            Section("账户概览") {
                accountOverviewCard(account, cards: allCards)
            }

            if !allCards.isEmpty {
                cardsSection(account, cards: cards, allCards: allCards)
            }
            if hasSubaccounts(account) {
                subaccountsSections(account)
            }

            loginSection(account)

            if account.region == .overseas {
                addressSection(account)
                remittanceSection(account)
            }

            if !account.note.isEmpty {
                Section("其他") {
                    optionalDetail("备注", account.note, alignment: .leading)
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
    }

    private func accountOverviewCard(_ account: BankAccount, cards: [BankCard]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.bankName.isEmpty ? "未命名银行" : account.bankName)
                    .appFont(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                BankRegionBadge(region: account.region)
                AccountStatusText(status: account.status)
            }

            accountBranchFact(account)

            overviewFact(
                title: "档案统计",
                value: accountSummary(account, cards: cards)
            )
            overviewFact(
                title: "建立日期",
                value: AppDateFormatter.string(from: account.openedAt)
            )
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func accountBranchFact(_ account: BankAccount) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(account.region == .domestic ? "开户网点" : "分行/网点")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            if account.isOnlineBank {
                Text("网络银行")
            } else {
                Menu {
                    ForEach(BankNavigationApplication.allCases) { application in
                        Button {
                            BankBranchNavigationService.open(
                                application,
                                branchName: account.branchName,
                                location: account.branchLocation
                            )
                        } label: {
                            Label(application.title, systemImage: application.systemImage)
                        }
                    }
                } label: {
                    branchLocationValueLabel(for: account)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overviewFact(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appFont(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .copyableText(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func subaccountsSections(_ account: BankAccount) -> some View {
        let allSubaccounts = account.region == .domestic
            ? account.domesticSubaccounts.map(AnySubaccount.domestic)
            : account.foreignSubaccounts.map(AnySubaccount.foreign)
        let subaccounts = sortedSubaccounts(allSubaccounts.filter { $0.status != .closed })
        let closedSubaccounts = sortedSubaccounts(allSubaccounts.filter { $0.status == .closed })
        let closedSubaccountCount = account.closedSubaccountCount

        Section(subaccounts.isEmpty ? "子账户归档" : "子账户（\(account.activeSubaccountCount)）") {
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
            if closedSubaccountCount > 0 {
                HiddenItemsVisibilityButton(
                    itemsDescription: "\(closedSubaccountCount) 个已销户子账户",
                    isShowing: $showsClosedSubaccounts
                )
            }
            if showsClosedSubaccounts {
                ForEach(closedSubaccounts) { item in
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
    }

    @ViewBuilder
    private func cardsSection(
        _ account: BankAccount,
        cards: [BankCard],
        allCards: [BankCard]
    ) -> some View {
        let closedCards = closedCards(for: account)
        Section(cards.isEmpty ? "银行卡归档" : "银行卡（\(activeCardCount(allCards))）") {
            ForEach(cards) { card in
                Button { viewingCard = card } label: {
                    CardRow(card: card)
                }
                .buttonStyle(.plain)
                .appListRowStyle()
            }
            if !closedCards.isEmpty {
                HiddenItemsVisibilityButton(
                    itemsDescription: "\(closedCards.count) 张已销户银行卡",
                    isShowing: $showsClosedCards
                )
            }
            if showsClosedCards {
                ForEach(closedCards) { card in
                    Button { viewingCard = card } label: {
                        CardRow(card: card)
                    }
                    .buttonStyle(.plain)
                    .appListRowStyle()
                }
            }
        }
    }

    @ViewBuilder
    private func loginSection(_ account: BankAccount) -> some View {
        let additionalFields = account.additionalLoginFields.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.value.isEmpty
        }
        let hasSensitive = additionalFields.contains { $0.isSensitive }
        if !additionalFields.isEmpty {
            Section("登录信息") {
                ForEach(additionalFields) { field in
                    if field.isSensitive {
                        DetailValueRow.protected(
                            field.name,
                            value: field.value,
                            concealedValue: "••••••••",
                            isRevealed: sensitiveLoginInformationRevealed
                        )
                    } else {
                        DetailValueRow(title: field.name, value: field.value)
                    }
                }
                if hasSensitive {
                    Button {
                        if sensitiveLoginInformationRevealed {
                            sensitiveLoginInformationRevealed = false
                        } else {
                            showingSensitiveAccess = true
                        }
                    } label: {
                        Label(
                            sensitiveLoginInformationRevealed ? "隐藏敏感信息" : "验证身份后查看敏感信息",
                            systemImage: sensitiveLoginInformationRevealed ? "lock" : "faceid"
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
                optionalDetail("通讯地址（中文）", account.correspondenceAddressChinese, alignment: .leading)
                optionalDetail("通讯地址（英文）", account.correspondenceAddressEnglish, alignment: .leading)
                optionalDetail("住宅地址（中文）", account.residentialAddressChinese, alignment: .leading)
                optionalDetail("住宅地址（英文）", account.residentialAddressEnglish, alignment: .leading)
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
                optionalDetail("收款银行正式名称", account.remittanceBankName, alignment: .leading)
                optionalDetail("收款银行地址", account.remittanceBankAddress, alignment: .leading)
                optionalDetail("SWIFT Code", account.swift)
                optionalDetail("IBAN", account.iban)
                optionalDetail("汇款说明", account.remittanceInstructions, alignment: .leading)
            }
        }
    }

    private func branchLocationValueLabel(for account: BankAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.branchLocation?.isValid == true
                  ? "mappin.and.ellipse"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(account.branchLocation?.isValid == true ? .blue : .yellow)
            Text(account.branchName.isEmpty ? "未填写" : account.branchName)
                .foregroundStyle(.blue)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .copyableText(account.branchName)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }

    private func displayedCards(for account: BankAccount) -> [BankCard] {
        sortedCards(store.cards(for: account).filter { $0.status != .closed })
    }

    private func closedCards(for account: BankAccount) -> [BankCard] {
        sortedCards(store.cards(for: account).filter { $0.status == .closed })
    }

    private func sortedCards(_ cards: [BankCard]) -> [BankCard] {
        cards.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .debit
            }
            return AppAlphabeticalSort.isOrderedBefore(
                cardDisplayName(lhs),
                cardDisplayName(rhs),
                lhsTieBreaker: "\(lhs.cardNumber)|\(lhs.id.uuidString)",
                rhsTieBreaker: "\(rhs.cardNumber)|\(rhs.id.uuidString)"
            )
        }
    }

    private func sortedSubaccounts(_ subaccounts: [AnySubaccount]) -> [AnySubaccount] {
        subaccounts.sorted { lhs, rhs in
            AppAlphabeticalSort.isOrderedBefore(
                lhs.displayName,
                rhs.displayName,
                lhsTieBreaker: lhs.id.uuidString,
                rhsTieBreaker: rhs.id.uuidString
            )
        }
    }

    private func cardDisplayName(_ card: BankCard) -> String {
        let name = card.cardType.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? card.kind.title : name
    }

    private func activeCardCount(_ cards: [BankCard]) -> Int {
        cards.filter { $0.status != .closed }.count
    }

    private func accountSummary(_ account: BankAccount, cards: [BankCard]) -> String {
        let debit = cards.filter { $0.kind == .debit && $0.status != .closed }.count
        let credit = cards.filter { $0.kind == .credit && $0.status != .closed }.count
        let subaccountCount = account.activeSubaccountCount
        return "\(debit) 张借记卡 · \(credit) 张信用卡 · \(subaccountCount) 个子账户"
    }

    private func hasSubaccounts(_ account: BankAccount) -> Bool {
        account.region == .domestic
            ? !account.domesticSubaccounts.isEmpty
            : !account.foreignSubaccounts.isEmpty
    }

    @ViewBuilder
    private func optionalDetail(
        _ title: String,
        _ value: String,
        alignment: TextAlignment = .trailing
    ) -> some View {
        if !value.isEmpty {
            DetailValueRow(title: title, value: value, alignment: alignment)
        }
    }
}

private struct AccountStatusDisclosurePicker: View {
    @Binding var status: AccountStatus

    var body: some View {
        AppLabeledContentRow("状态") {
            Menu {
                ForEach(AccountStatus.allCases) { option in
                    Button { status = option } label: {
                        Text("\(statusDot(for: option)) \(option.title)\(option == status ? "  ✓" : "")")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .appFont(.caption2)
                        .foregroundStyle(statusColor)
                    Text(status.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var statusColor: Color {
        switch status {
        case .normal: .green
        case .abnormal: .orange
        case .closed: .red
        }
    }

    private func statusDot(for option: AccountStatus) -> String {
        switch option {
        case .normal: "🟢"
        case .abnormal: "🟠"
        case .closed: "🔴"
        }
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

    var status: AccountStatus {
        switch self {
        case .domestic(let value): value.status
        case .foreign(let value): value.status
        }
    }

    var displayName: String {
        switch self {
        case .domestic(let value):
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? value.type : name
        case .foreign(let value):
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? value.typeTitle : name
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
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: AccountEditorDraft
    @State private var editingDomesticSubaccount: DomesticSubaccount?
    @State private var editingForeignSubaccount: ForeignSubaccount?
    @State private var editingCard: BankCard?
    @State private var editingAdditionalLoginField: AdditionalLoginField?
    @State private var editingLoginTemplate: BankRegion?
    @State private var editingBranchLocation = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var didSave = false
    private let navigationTitle: String
    private let isNew: Bool
    private let originalAttachmentIDs: Set<UUID>

    init(account: BankAccount, isNew: Bool, cards: [BankCard] = []) {
        _draft = StateObject(wrappedValue: AccountEditorDraft(account: account, cards: cards))
        self.isNew = isNew
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

                cardsEditorSection
                subaccountEditorSection

                loginEditorSection

                if draft.account.region == .overseas {
                    overseasAddressEditorSection
                    remittanceEditorSection
                }

                Section("其他") {
                    AccountStatusDisclosurePicker(status: $draft.account.status)
                    DateFieldRow(title: "建立日期：", date: $draft.account.openedAt)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注：")
                            .foregroundStyle(.secondary)
                        IMESafeMultilineTextField(prompt: "可选", text: $draft.account.note)
                    }
                }
            }
            .appNavigationTitle(navigationTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: requestSave) }
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
                AdditionalLoginFieldEditorView(
                    field: field,
                    isNew: !draft.account.additionalLoginFields.contains { $0.id == field.id },
                    onSave: upsertAdditionalLoginField
                )
                .id(field.id)
                .iOSLargeSheet()
            }
            .sheet(item: $editingLoginTemplate) { region in
                BankLoginTemplateEditorView(
                    region: region,
                    templates: store.loginFieldTemplates(for: region)
                )
                    .id(region)
                    .iOSLargeSheet()
            }
            .sheet(isPresented: $editingBranchLocation) {
                BankBranchLocationPickerView(
                    branchName: draft.account.branchName,
                    location: draft.account.branchLocation,
                    title: draft.account.region == .domestic ? "开户网点" : "分行/网点",
                    markerFallback: draft.account.region == .domestic ? "开户网点" : "分行/网点"
                ) { branch in
                    draft.account.branchLocation = branch.location
                    if !branch.name.isEmpty {
                        draft.account.branchName = branch.name
                    }
                }
                .iOSLargeSheet()
            }
            .onChange(of: draft.account.region) { oldRegion, newRegion in
                guard isNew, oldRegion != newRegion else { return }
                let oldTemplateNames = Set(store.loginFieldTemplates(for: oldRegion).map(\.name))
                let currentNames = Set(draft.account.additionalLoginFields.map(\.name))
                guard currentNames.isSubset(of: oldTemplateNames) else { return }
                draft.account.additionalLoginFields = store.makeLoginFields(for: newRegion)
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
            FieldEditorRow(title: "银行名称：", prompt: "必填", text: $draft.account.bankName)
            ToggleFieldRow(title: "网络银行（无实体网点）", isOn: $draft.account.isOnlineBank)
            AppLabeledContentRow(draft.account.region == .domestic ? "开户网点" : "分行/网点") {
                if draft.account.isOnlineBank {
                    Text("网络银行")
                } else {
                    Button {
                        editingBranchLocation = true
                    } label: {
                        Label(
                            branchLocationDisplayText,
                            systemImage: "mappin.and.ellipse"
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    }
                }
            }
            if !draft.account.isOnlineBank {
                Text(draft.account.region == .domestic
                     ? "境内银行以银行卡为主；子账户用于个人养老金等没有独立卡片的账户。"
                     : "境外银行以子账户为主；每个账户可单独记录账户号、币种和状态。")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var branchLocationDisplayText: String {
        guard let location = draft.account.branchLocation, location.isValid else {
            return "设置位置"
        }
        let name = draft.account.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(format: "%.5f, %.5f", location.latitude, location.longitude)
            : name
    }

    private var subaccountEditorSection: some View {
        Section("子账户") {
            let domestic = draft.account.region == .domestic
            if domestic {
                if draft.account.domesticSubaccounts.isEmpty {
                    Text("暂无子账户").foregroundStyle(.secondary)
                }
                ForEach(sortedDomesticDraftSubaccounts) { subaccount in
                    Button { editingDomesticSubaccount = subaccount } label: {
                        DomesticSubaccountRow(subaccount: subaccount)
                    }
                    .buttonStyle(.plain)
                    .appDeleteSwipeAction {
                        draft.account.domesticSubaccounts.removeAll { $0.id == subaccount.id }
                    }
                }
                Button { editingDomesticSubaccount = DomesticSubaccount() } label: {
                    Label("添加子账户", systemImage: "plus.circle")
                }
            } else {
                if draft.account.foreignSubaccounts.isEmpty {
                    Text("暂无子账户").foregroundStyle(.secondary)
                }
                ForEach(sortedForeignDraftSubaccounts) { subaccount in
                    Button { editingForeignSubaccount = subaccount } label: {
                        ForeignSubaccountRow(subaccount: subaccount)
                    }
                    .buttonStyle(.plain)
                    .appDeleteSwipeAction {
                        draft.account.foreignSubaccounts.removeAll { $0.id == subaccount.id }
                    }
                }
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
                    CardRow(card: card)
                }
                .buttonStyle(.plain)
                .appListRowStyle()
                .appDeleteSwipeAction {
                    deleteCards(ids: [card.id])
                }
            }
            Button { editingCard = BankCard() } label: {
                Label("添加银行卡", systemImage: "plus.circle")
            }
        } header: {
            Text(draft.account.region == .domestic ? "银行卡（主要档案）" : "银行卡")
        } footer: {
            Text(draft.account.region == .domestic
                 ? "境内银行的卡片是主要金融载体；子账户仅用于记录特殊账户。"
                 : "境外银行的卡片作为子账户之外的支付工具单独维护。")
        }
    }

    private var sortedDraftCards: [BankCard] {
        draft.cards.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .debit
            }
            let lhsName = lhs.cardType.isEmpty ? lhs.kind.title : lhs.cardType
            let rhsName = rhs.cardType.isEmpty ? rhs.kind.title : rhs.cardType
            return AppAlphabeticalSort.isOrderedBefore(
                lhsName,
                rhsName,
                lhsTieBreaker: "\(lhs.cardNumber)|\(lhs.id.uuidString)",
                rhsTieBreaker: "\(rhs.cardNumber)|\(rhs.id.uuidString)"
            )
        }
    }

    private var sortedDomesticDraftSubaccounts: [DomesticSubaccount] {
        draft.account.domesticSubaccounts.sorted { lhs, rhs in
            let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return AppAlphabeticalSort.isOrderedBefore(
                lhsName.isEmpty ? lhs.type : lhsName,
                rhsName.isEmpty ? rhs.type : rhsName,
                lhsTieBreaker: lhs.id.uuidString,
                rhsTieBreaker: rhs.id.uuidString
            )
        }
    }

    private var sortedForeignDraftSubaccounts: [ForeignSubaccount] {
        draft.account.foreignSubaccounts.sorted { lhs, rhs in
            let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return AppAlphabeticalSort.isOrderedBefore(
                lhsName.isEmpty ? lhs.typeTitle : lhsName,
                rhsName.isEmpty ? rhs.typeTitle : rhsName,
                lhsTieBreaker: lhs.id.uuidString,
                rhsTieBreaker: rhs.id.uuidString
            )
        }
    }

    private var loginEditorSection: some View {
        Section {
            ForEach($draft.account.additionalLoginFields) { $field in
                AppLabeledContentRow(field.name.isEmpty ? "未命名字段" : field.name) {
                    IMESafeTextField(prompt: "请输入内容", text: $field.value, alignment: .trailing)
                }
                .appSwipeActions(edge: .leading, style: AppSwipeActions.edit) {
                    Button { editingAdditionalLoginField = field } label: {
                        Label("编辑名称", systemImage: "square.and.pencil")
                    }
                    Button {
                        var updated = field
                        updated.isSensitive.toggle()
                        upsertAdditionalLoginField(updated)
                    } label: {
                        Label(field.isSensitive ? "显示" : "隐藏", systemImage: field.isSensitive ? "eye" : "eye.slash")
                    }
                }
                .appDeleteSwipeAction {
                    draft.account.additionalLoginFields.removeAll { $0.id == field.id }
                }
            }
            Button { editingAdditionalLoginField = AdditionalLoginField() } label: {
                Label("添加自定义登录字段", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text("登录信息")
                Spacer()
                Button("登录模板") {
                    editingLoginTemplate = draft.account.region
                }
                .appFont(.subheadline)
                .foregroundStyle(.blue)
                .underline()
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
            FieldEditorRow(title: "SWIFT Code：", prompt: "例如 BKCHHKHHXXX", text: $draft.account.swift, mode: .asciiUppercase)
            FieldEditorRow(title: "IBAN：", prompt: "可选", text: $draft.account.iban, mode: .asciiUppercase)
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
        var account = draft.account
        account.bankName = account.bankName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.bankName.isEmpty else {
            errorMessage = "请填写银行名称。"
            showingError = true
            return
        }
        if account.region == .domestic {
            account.swift = ""
            account.iban = ""
        }
        var cards = draft.cards
        if account.isOnlineBank {
            account.branchName = ""
            account.branchLocation = nil
        }
        if account.isOnlineBank || account.region == .overseas {
            for index in cards.indices {
                cards[index].branchName = nil
                cards[index].branchLocation = nil
            }
        }
        didSave = true
        store.replaceAccount(account, cards: cards)
        dismiss()
    }

    private func upsertDomesticSubaccount(_ value: DomesticSubaccount) {
        if let index = draft.account.domesticSubaccounts.firstIndex(where: { $0.id == value.id }) {
            draft.account.domesticSubaccounts[index] = value
        } else {
            draft.account.domesticSubaccounts.append(value)
        }
    }

    private func upsertForeignSubaccount(_ value: ForeignSubaccount) {
        if let index = draft.account.foreignSubaccounts.firstIndex(where: { $0.id == value.id }) {
            draft.account.foreignSubaccounts[index] = value
        } else {
            draft.account.foreignSubaccounts.append(value)
        }
    }

    private func upsertCard(_ card: BankCard) {
        if let index = draft.cards.firstIndex(where: { $0.id == card.id }) {
            draft.cards[index] = card
        } else {
            draft.cards.append(card)
        }
    }

    private func deleteCards(ids: Set<UUID>) {
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
    let isNew: Bool
    let onSave: (AdditionalLoginField) -> Void

    init(field: AdditionalLoginField, isNew: Bool, onSave: @escaping (AdditionalLoginField) -> Void) {
        _field = State(initialValue: field)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var canSave: Bool {
        !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isNew ? !field.value.isEmpty : true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("字段内容") {
                    FieldEditorRow(title: "名称：", prompt: "例如电话银行密码", text: $field.name)
                    if isNew {
                        AppLabeledContentRow("内容：") {
                            if field.isSensitive {
                                SecureField("请输入内容", text: $field.value).multilineTextAlignment(.trailing)
                            } else {
                                IMESafeTextField(prompt: "请输入内容", text: $field.value, alignment: .trailing)
                            }
                        }
                    }
                }
                Section { ToggleFieldRow(title: "作为敏感信息隐藏", isOn: $field.isSensitive) }
            }
            .appNavigationTitle(isNew ? "添加自定义字段" : "编辑字段名称")
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

private struct BankLoginTemplateEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let region: BankRegion
    @State private var templates: [BankLoginFieldTemplate]
    @State private var editingTemplate: BankLoginFieldTemplate?

    init(region: BankRegion, templates: [BankLoginFieldTemplate]) {
        self.region = region
        _templates = State(initialValue: templates)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(templates) { template in
                        Text(template.name)
                            .foregroundStyle(.primary)
                            .appSwipeActions(edge: .leading, style: AppSwipeActions.edit) {
                                Button { editingTemplate = template } label: {
                                    Label("编辑", systemImage: "square.and.pencil")
                                }
                                Button {
                                    var updated = template
                                    updated.isSensitive.toggle()
                                    save(updated)
                                } label: {
                                    Label(template.isSensitive ? "显示" : "隐藏", systemImage: template.isSensitive ? "eye" : "eye.slash")
                                }
                            }
                            .appDeleteSwipeAction {
                                templates.removeAll { $0.id == template.id }
                                store.deleteLoginFieldTemplate(template, for: region)
                            }
                    }
                    Button { editingTemplate = BankLoginFieldTemplate() } label: {
                        Label("添加模板字段", systemImage: "plus.circle")
                    }
                } header: {
                    Text("自定义字段 · \(region.title)")
                }
            }
            .appNavigationTitle("登录模板")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(item: $editingTemplate) { template in
                BankLoginTemplateFieldEditorView(template: template) { save($0) }
                    .id(template.id)
                    .iOSLargeSheet()
            }
        }
    }

    private func save(_ template: BankLoginFieldTemplate) {
        store.upsertLoginFieldTemplate(template, for: region)
        templates = store.loginFieldTemplates(for: region)
        editingTemplate = nil
    }

}

private struct BankLoginTemplateFieldEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var template: BankLoginFieldTemplate
    let onSave: (BankLoginFieldTemplate) -> Void

    init(template: BankLoginFieldTemplate, onSave: @escaping (BankLoginFieldTemplate) -> Void) {
        _template = State(initialValue: template)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                FieldEditorRow(title: "字段名称：", prompt: "例如安全问题", text: $template.name)
                ToggleFieldRow(title: "作为敏感信息隐藏", isOn: $template.isSensitive)
            }
            .appNavigationTitle(template.name.isEmpty ? "添加模板字段" : "编辑模板字段")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            var value = template
                            value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.name.isEmpty else { return }
                            onSave(value)
                            dismiss()
                        }
                    }
                    .disabled(template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct BankBranchSelection: Equatable {
    var name: String
    var location: BankBranchLocation

    init(mapSelection: MapLocationSelection, markerFallback: String) {
        let selectedName = mapSelection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = selectedName == markerFallback ? "" : selectedName
        location = BankBranchLocation(
            latitude: mapSelection.coordinate.latitude,
            longitude: mapSelection.coordinate.longitude
        )
    }
}

struct BankBranchLocationPickerView: View {
    let branchName: String
    let location: BankBranchLocation?
    var title = "分行/网点位置"
    var markerFallback = "分行/网点"
    let onSave: (BankBranchSelection) -> Void

    var body: some View {
        let initial = location?.isValid == true ? location! : BankBranchLocation.defaultLocation
        MapLocationPickerView(
            configuration: MapLocationPickerConfiguration(
                title: title,
                searchPlaceholder: "搜索分行、网点或地址",
                markerTitle: branchName.isEmpty ? markerFallback : branchName,
                initialSearchText: branchName,
                initialSelection: MapLocationSelection(
                    name: branchName,
                    address: "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: initial.latitude,
                        longitude: initial.longitude
                    ),
                    administrativeContext: ""
                ),
                defaultCoordinate: CLLocationCoordinate2D(
                    latitude: BankBranchLocation.defaultLocation.latitude,
                    longitude: BankBranchLocation.defaultLocation.longitude
                )
            )
        ) { selection in
            onSave(BankBranchSelection(
                mapSelection: selection,
                markerFallback: markerFallback
            ))
        }
    }

}

#endif
