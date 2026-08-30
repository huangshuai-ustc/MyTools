#if MYTOOLS_FEATURE_FINANCE
import SwiftUI
import MapKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private enum BankNavigationApplication: String, CaseIterable, Identifiable {
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

struct AccountDetailView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var preferenceChangeBus: AppPreferenceChangeBus
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
    @AppStorage(AppStorageKey.cardSortOrder) private var cardSortOrderRawValue = CardSortOrder.nameAscending.rawValue
    @AppStorage(AppStorageKey.cardCategoryFilter) private var cardCategoryRawValue = CardCategoryFilter.all.rawValue

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
                if let account, !store.cards(for: account).isEmpty {
                    FinanceCardDisplayMenu(
                        category: $cardCategoryRawValue,
                        sort: $cardSortOrderRawValue
                    )
                }
                if account != nil {
                    AdminEditAccessButton()
                }
                if auth.isAdmin, let account {
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
            DomesticSubaccountReadOnlyView(subaccount: subaccount)
                .iOSLargeSheet()
        }
        .sheet(item: $viewingForeignSubaccount) { subaccount in
            ForeignSubaccountReadOnlyView(subaccount: subaccount)
                .iOSLargeSheet()
        }
        .sheet(item: $editingBranchLocation) { account in
            BankBranchLocationPickerView(
                branchName: account.branchName,
                location: account.branchLocation
            ) { location in
                var updated = account
                updated.branchLocation = location
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
        .onChange(of: cardSortOrderRawValue) { _, _ in
            preferenceChangeBus.notifyChanged()
        }
        .onChange(of: cardCategoryRawValue) { _, _ in
            preferenceChangeBus.notifyChanged()
        }
        .onChange(of: auth.isAdmin) { _, _ in
            sensitiveLoginInformationRevealed = false
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
                AppLabeledContentRow("银行类型") {
                    BankRegionBadge(region: account.region)
                        .copyableText(account.region.title)
                }
                DetailValueRow(title: "银行", value: account.bankName)
                if account.isOnlineBank {
                    DetailValueRow(
                        title: account.region == .domestic ? "开户网点" : "分行/网点",
                        value: "网络银行"
                    )
                } else {
                    AppLabeledContentRow(account.region == .domestic ? "开户网点" : "分行/网点") {
                        if auth.isAdmin {
                            Button {
                                editingBranchLocation = account
                            } label: {
                                branchLocationValueLabel(for: account)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Menu {
                                ForEach(BankNavigationApplication.allCases) { application in
                                    Button {
                                        openNavigation(application, for: account)
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
                }
                AppLabeledContentRow("状态") { AccountStatusText(status: account.status) }
                AppLabeledContentRow("档案统计") {
                    Text(accountSummary(account, cards: allCards))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                DetailValueRow(
                    title: "建立日期",
                    value: AppDateFormatter.string(from: account.openedAt)
                )
            }

            if account.region == .overseas {
                subaccountsSections(account)
                cardsSection(account, cards: cards, allCards: allCards)
            } else {
                cardsSection(account, cards: cards, allCards: allCards)
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

    @ViewBuilder
    private func subaccountsSections(_ account: BankAccount) -> some View {
        let allSubaccounts = account.region == .domestic
            ? account.domesticSubaccounts.map(AnySubaccount.domestic)
            : account.foreignSubaccounts.map(AnySubaccount.foreign)
        let subaccounts = allSubaccounts.filter { $0.status != .closed }
        let closedSubaccounts = allSubaccounts.filter { $0.status == .closed }
        let closedSubaccountCount = account.closedSubaccountCount

        Section("子账户（\(account.activeSubaccountCount)）") {
            if subaccounts.isEmpty {
                Text(allSubaccounts.isEmpty ? "暂无子账户" : "暂无正常子账户")
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
            if !showsClosedSubaccounts, closedSubaccountCount > 0 {
                HiddenItemsVisibilityButton(
                    itemsDescription: "\(closedSubaccountCount) 个已销户子账户",
                    isShowing: $showsClosedSubaccounts
                )
            }
        }
        if showsClosedSubaccounts, !closedSubaccounts.isEmpty {
            Section("已销户子账户（\(closedSubaccounts.count)）") {
                HiddenItemsVisibilityButton(
                    itemsDescription: "\(closedSubaccounts.count) 个已销户子账户",
                    isShowing: $showsClosedSubaccounts
                )
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
        Section("银行卡（\(activeCardCount(allCards))）") {
            if cards.isEmpty {
                Text(allCards.isEmpty ? "暂无银行卡" : "当前筛选下暂无银行卡")
                    .foregroundStyle(.secondary)
            }
            ForEach(cards) { card in
                Button { viewingCard = card } label: {
                    CardRow(card: card)
                }
                .buttonStyle(.plain)
                .appListRowStyle()
            }
            if !showsClosedCards, !closedCards.isEmpty {
                HiddenItemsVisibilityButton(
                    itemsDescription: "\(closedCards.count) 张已销户银行卡",
                    isShowing: $showsClosedCards
                )
            }
        }
        if showsClosedCards, !closedCards.isEmpty {
            Section("已销户银行卡（\(closedCards.count)）") {
                HiddenItemsVisibilityButton(
                    itemsDescription: "\(closedCards.count) 张已销户银行卡",
                    isShowing: $showsClosedCards
                )
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
        let hasSensitive = !account.loginPassword.isEmpty || additionalFields.contains { $0.isSensitive }
        if !account.boundPhoneNumber.isEmpty
            || !account.loginAccount.isEmpty
            || !account.loginPassword.isEmpty
            || !additionalFields.isEmpty {
            Section("登录信息") {
                optionalDetail("绑定手机号", account.boundPhoneNumber)
                optionalDetail("登录账号", account.loginAccount)
                if !account.loginPassword.isEmpty {
                    DetailValueRow.protected(
                        "登录密码",
                        value: account.loginPassword,
                        concealedValue: "••••••••",
                        isRevealed: auth.isAdmin || sensitiveLoginInformationRevealed
                    )
                }
                ForEach(additionalFields) { field in
                    if field.isSensitive {
                        DetailValueRow.protected(
                            field.name,
                            value: field.value,
                            concealedValue: "••••••••",
                            isRevealed: auth.isAdmin || sensitiveLoginInformationRevealed
                        )
                    } else {
                        DetailValueRow(title: field.name, value: field.value)
                    }
                }
                if !auth.isAdmin, hasSensitive {
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

    private func openNavigation(_ application: BankNavigationApplication, for account: BankAccount) {
        let location = account.branchLocation?.isValid == true
            ? account.branchLocation!
            : .defaultLocation
        let coordinate = "\(location.latitude),\(location.longitude)"
        let name = account.branchName.isEmpty ? "分行/网点" : account.branchName
        let url: URL?
        switch application {
        case .appleMaps:
            url = URL(string: "maps://?daddr=\(coordinate)&q=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)&dirflg=d")
        case .amap:
            url = URL(string: "iosamap://navi?lat=\(location.latitude)&lon=\(location.longitude)&dev=0&style=2")
        case .baiduMaps:
            url = URL(string: "baidumap://map/direction?destination=latlng:\(location.latitude),\(location.longitude)|name:\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)&mode=driving")
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

    private func displayedCards(for account: BankAccount) -> [BankCard] {
        let cards = store.cards(for: account).filter {
            $0.status != .closed
                && (CardCategoryFilter(rawValue: cardCategoryRawValue)?.includes($0) ?? true)
        }
        return (CardSortOrder(rawValue: cardSortOrderRawValue) ?? .nameAscending).sorted(cards)
    }

    private func closedCards(for account: BankAccount) -> [BankCard] {
        let cards = store.cards(for: account).filter {
            $0.status == .closed
                && (CardCategoryFilter(rawValue: cardCategoryRawValue)?.includes($0) ?? true)
        }
        return (CardSortOrder(rawValue: cardSortOrderRawValue) ?? .nameAscending).sorted(cards)
    }

    private func activeCardCount(_ cards: [BankCard]) -> Int {
        cards.filter { $0.status != .closed }.count
    }

    private func accountSummary(_ account: BankAccount, cards: [BankCard]) -> String {
        let debit = cards.filter { $0.kind == .debit && $0.status != .closed }.count
        let credit = cards.filter { $0.kind == .credit && $0.status != .closed }.count
        let subaccountCount = account.activeSubaccountCount
        return account.region == .domestic
            ? "\(debit) 张借记卡 · \(credit) 张信用卡 · \(subaccountCount) 个子账户"
            : "\(subaccountCount) 个子账户 · \(debit) 张借记卡 · \(credit) 张信用卡"
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
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: AccountEditorDraft
    @State private var editingDomesticSubaccount: DomesticSubaccount?
    @State private var editingForeignSubaccount: ForeignSubaccount?
    @State private var editingCard: BankCard?
    @State private var editingAdditionalLoginField: AdditionalLoginField?
    @State private var editingLoginTemplate: BankRegion?
    @State private var editingFixedLoginField: FixedLoginField?
    @State private var editingBranchLocation = false
    @State private var showingAuthentication = false
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注：")
                            .foregroundStyle(.secondary)
                        IMESafeMultilineTextField(prompt: "可选", text: $draft.account.note)
                    }
                }
            }
            .appNavigationTitle(navigationTitle)
            .adminModeIndicator()
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
                    .iOSAuthenticationSheet()
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
            .sheet(item: $editingFixedLoginField) { field in
                BankFixedLoginFieldEditorView(field: field, value: fixedLoginValue(field)) { value in
                    updateFixedLoginField(field, value: value)
                }
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
                    location: draft.account.branchLocation
                ) { location in
                    draft.account.branchLocation = location
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
            LabeledContent("银行名称：") {
                IMESafeTextField(prompt: "必填", text: $draft.account.bankName, alignment: .trailing)
            }
            Toggle("网络银行（无实体网点）", isOn: $draft.account.isOnlineBank)
            if !draft.account.isOnlineBank {
                LabeledContent(draft.account.region == .domestic ? "开户网点：" : "分行/网点：") {
                    IMESafeTextField(prompt: "可选", text: $draft.account.branchName, alignment: .trailing)
                }
                HStack {
                    Text("地图位置")
                    Spacer()
                    Button {
                        editingBranchLocation = true
                    } label: {
                        Label(
                            draft.account.branchLocation?.isValid == true ? "修改位置" : "设置位置",
                            systemImage: "mappin.and.ellipse"
                        )
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

    private var subaccountEditorSection: some View {
        Section("子账户") {
            let domestic = draft.account.region == .domestic
            if domestic {
                if draft.account.domesticSubaccounts.isEmpty {
                    Text("暂无子账户").foregroundStyle(.secondary)
                }
                ForEach(draft.account.domesticSubaccounts) { subaccount in
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
                ForEach(draft.account.foreignSubaccounts) { subaccount in
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
        draft.cards.sorted {
            let lhs = $0.cardType.isEmpty ? $0.kind.title : $0.cardType
            let rhs = $1.cardType.isEmpty ? $1.kind.title : $1.cardType
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private var loginEditorSection: some View {
        Section("登录信息") {
            fixedLoginFieldRow(.phone, value: draft.account.boundPhoneNumber)
            fixedLoginFieldRow(.account, value: draft.account.loginAccount)
            fixedLoginFieldRow(.password, value: draft.account.loginPassword)
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
                .appSwipeActions(edge: .leading, style: AppSwipeActions.edit) {
                    Button { editingAdditionalLoginField = field } label: {
                        Label("编辑", systemImage: "square.and.pencil")
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
            Button { editingLoginTemplate = draft.account.region } label: {
                Label("管理(draft.account.region.title)登录模板", systemImage: "rectangle.and.pencil.and.ellipsis")
            }
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

    @ViewBuilder
    private func fixedLoginFieldRow(_ field: FixedLoginField, value: String) -> some View {
        Button { editingFixedLoginField = field } label: {
            LabeledContent(field.title, value: value.isEmpty ? "未填写" : (field == .password ? "••••••••" : value))
        }
        .buttonStyle(.plain)
        .appSwipeActions(edge: .leading, style: AppSwipeActions.edit) {
            Button { editingFixedLoginField = field } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
        }
        .appDeleteSwipeAction { updateFixedLoginField(field, value: "") }
    }

    private func updateFixedLoginField(_ field: FixedLoginField, value: String) {
        switch field {
        case .phone: draft.account.boundPhoneNumber = value
        case .account: draft.account.loginAccount = value
        case .password: draft.account.loginPassword = value
        }
    }

    private func fixedLoginValue(_ field: FixedLoginField) -> String {
        switch field {
        case .phone: draft.account.boundPhoneNumber
        case .account: draft.account.loginAccount
        case .password: draft.account.loginPassword
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
            .appNavigationTitle(field.name.isEmpty ? "添加自定义字段" : "编辑自定义字段")
            .adminModeIndicator()
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

private enum FixedLoginField: String, Identifiable {
    case phone
    case account
    case password

    var id: Self { self }

    var title: String {
        switch self {
        case .phone: return "绑定手机号"
        case .account: return "登录账号"
        case .password: return "登录密码"
        }
    }
}

private struct BankFixedLoginFieldEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let field: FixedLoginField
    let onSave: (String) -> Void
    @State private var value: String

    init(field: FixedLoginField, value: String = "", onSave: @escaping (String) -> Void) {
        self.field = field
        self.onSave = onSave
        _value = State(initialValue: value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(field.title) {
                    if field == .password {
                        SecureField("可选", text: $value)
                    } else {
                        IMESafeTextField(prompt: "可选", text: $value)
                    }
                }
            }
            .appNavigationTitle("编辑(field.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            onSave(value.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        }
                    }
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
                ForEach(templates) { template in
                    Text(template.name)
                        .foregroundStyle(template.isSensitive ? .secondary : .primary)
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
            }
            .appNavigationTitle("(region.title)登录模板")
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
                LabeledContent("字段名称：") {
                    IMESafeTextField(prompt: "例如安全问题", text: $template.name, alignment: .trailing)
                }
                Toggle("作为敏感信息隐藏", isOn: $template.isSensitive)
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

private struct BankBranchLocationPickerView: View {
    let branchName: String
    let location: BankBranchLocation?
    let onSave: (BankBranchLocation) -> Void

    var body: some View {
        let initial = location?.isValid == true ? location! : BankBranchLocation.defaultLocation
        MapLocationPickerView(
            configuration: MapLocationPickerConfiguration(
                title: "分行/网点位置",
                searchPlaceholder: "搜索分行、网点或地址",
                markerTitle: branchName.isEmpty ? "分行/网点" : branchName,
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
            onSave(BankBranchLocation(
                latitude: selection.coordinate.latitude,
                longitude: selection.coordinate.longitude
            ))
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
            Divider()
            Button {
                sort = selectedSort == .nameAscending
                    ? CardSortOrder.nameDescending.rawValue
                    : CardSortOrder.nameAscending.rawValue
            } label: {
                Text("名称  \(selectedSort.direction.indicator)")
            }
        } label: {
            Image(systemName: selectedCategory == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("银行卡显示方式：名称，\(selectedSort.direction.title)")
        .help("银行卡显示方式：名称，\(selectedSort.direction.title)")
    }
}

#endif
