#if MYTOOLS_FEATURE_FINANCE
  import SwiftUI
  #if os(macOS)
    import AppKit
  #endif

  struct FinanceInstitutionsView: View {
    @EnvironmentObject private var store: FinanceStore
    @State private var query = ""
    @State private var service: FinanceService?
    @State private var showArchived = false
    @State private var editing: FinancialInstitution?
    @State private var deleting: FinancialInstitution?

    private var matchingInstitutions: [FinancialInstitution] {
      store.financialInstitutions.filter { account in
        let profile = account
        let cardMatches = store.cards(for: account).contains {
          [$0.cardType, $0.holderName, String($0.cardNumber.suffix(4))].contains {
            $0.localizedCaseInsensitiveContains(query)
          }
        }
        return (service.map(profile.services.contains) ?? true)
          && (profile.matches(query.trimmingCharacters(in: .whitespacesAndNewlines)) || cardMatches)
      }.sorted {
        AppAlphabeticalSort.isOrderedBefore(
          $0.name, $1.name, lhsTieBreaker: $0.id.uuidString,
          rhsTieBreaker: $1.id.uuidString)
      }
    }
    private var activeInstitutions: [FinancialInstitution] {
      matchingInstitutions.filter { !$0.isInactiveFinanceArchive(cards: store.cards(for: $0)) }
    }
    private var archivedInstitutions: [FinancialInstitution] {
      matchingInstitutions.filter { $0.isInactiveFinanceArchive(cards: store.cards(for: $0)) }
    }
    private var archivedCount: Int {
      archivedInstitutions.count
    }
    private var overviewInstitutions: [FinancialInstitution] {
      showArchived ? matchingInstitutions : activeInstitutions
    }
    private var overviewCards: [BankCard] {
      overviewInstitutions.flatMap { store.cards(for: $0) }.filter {
        showArchived || $0.status != .closed
      }
    }
    private var overviewAccountCount: Int {
      overviewInstitutions.reduce(0) {
        $0 + $1.accountCount(includeClosed: showArchived)
      }
    }

    var body: some View {
      List {
        Section {
          HStack(spacing: 12) {
            metric("机构", value: overviewInstitutions.count, symbol: "building.2")
            metric("账户", value: overviewAccountCount, symbol: "wallet.bifold")
            metric(
              "借记卡", value: overviewCards.filter { $0.kind == .debit }.count, symbol: "creditcard")
            metric(
              "信用卡", value: overviewCards.filter { $0.kind == .credit }.count,
              symbol: "creditcard.fill")
          }
        }
        if !activeInstitutions.isEmpty || !showArchived || archivedInstitutions.isEmpty {
          Section {
            if activeInstitutions.isEmpty {
              ContentUnavailableView(
                "暂无符合条件的金融档案", systemImage: "wallet.bifold",
                description: Text("添加银行、券商或支付平台，也可以调整筛选条件。"))
            }
            ForEach(activeInstitutions) { institution in
              NavigationLink {
                institutionDetailDestination(institution)
              } label: {
                institutionRow(institution)
              }
              .appListRowStyle()
              .appDeleteSwipeAction { deleting = institution }
            }
          } header: {
            Text(service?.title ?? "在用金融机构")
          } footer: {
            Text("同一机构可管理多种账户、卡片和收款方式。")
          }
        }
        if !archivedInstitutions.isEmpty {
          Section("已归档机构") {
            Button(showArchived ? "隐藏已归档机构（\(archivedCount)）" : "显示已归档机构（\(archivedCount)）") {
              showArchived.toggle()
            }
            if showArchived {
              ForEach(archivedInstitutions) { institution in
                NavigationLink {
                  institutionDetailDestination(institution)
                } label: {
                  institutionRow(institution)
                }
                .appListRowStyle()
                .appDeleteSwipeAction { deleting = institution }
              }
            }
          }
        }
      }
      .appNavigationTitle(ToolModule.personalFinance.title)
      .diagnosticScreen("金融档案首页")
      .iOSLabeledBackButton("工具")
      .searchable(text: $query, prompt: "机构、账户、币种或卡号尾号")
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Menu {
            Picker("机构类型", selection: $service) {
              Text("全部类型").tag(nil as FinanceService?)
              ForEach(FinanceService.allCases) { Text($0.title).tag(Optional($0)) }
            }
          } label: {
            Image(
              systemName: service == nil
                ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
          }
          .accessibilityLabel("筛选金融档案")
          Menu {
            ForEach(FinancialInstitutionKind.allCases) { kind in
              Button("添加" + kind.title) { editing = FinancialInstitution(kind: kind) }
            }
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("添加金融机构")
        }
      }
      .sheet(item: $editing) {
        FinanceInstitutionEditorView(institution: $0, isNew: true).iOSLargeSheet()
      }
      .alert(
        "删除整个金融档案？",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("取消", role: .cancel) { deleting = nil }
        Button("删除", role: .destructive) {
          if let deleting { store.deleteAccount(id: deleting.id) }
          deleting = nil
        }
      } message: {
        Text("将删除该机构的账户、卡片、登录资料、收款方式和文件。账户与卡片全部销户后，档案会自动归档。")
      }
      #if os(iOS)
        .listStyle(.insetGrouped)
        .appAdaptiveLargeNavigationTitle()
      #endif
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        Label(title, systemImage: symbol).appFont(.caption2).foregroundStyle(.secondary).lineLimit(
          1)
        Text("\(value)").appFont(.title3.weight(.semibold).monospacedDigit())
      }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func institutionDetailDestination(_ institution: FinancialInstitution) -> some View {
      switch institution.kind {
      case .bank: FinanceInstitutionDetailView(institutionID: institution.id)
      case .brokerage: BrokerageInstitutionDetailView(institutionID: institution.id)
      case .payment: PaymentInstitutionDetailView(institutionID: institution.id)
      case .other: FinanceInstitutionDetailView(institutionID: institution.id)
      }
    }

    private func institutionRow(_ institution: FinancialInstitution) -> some View {
      let profile = institution
      let cards = store.cards(for: institution)
      let includeClosed = showArchived
      return VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          ForEach(FinanceService.allCases.filter { profile.services.contains($0) }) { service in
            Text(service.title)
              .appFont(.caption.weight(.medium))
              .padding(.horizontal, 6).padding(.vertical, 3)
              .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
              .foregroundStyle(.blue)
          }
          Text(profile.name.isEmpty ? "未命名机构" : profile.name)
            .appFont(.headline).lineLimit(1)
          Spacer(minLength: 0)
        }
        if profile.services.contains(.banking) {
          let countedCards = cards.filter { includeClosed || $0.status != .closed }
          let accountCount = profile.accounts.filter { includeClosed || $0.status != .closed }.count
          Text(
            "借记卡 \(countedCards.filter { $0.kind == .debit }.count) · 信用卡 \(countedCards.filter { $0.kind == .credit }.count) · 账户 \(accountCount)"
          )
          .appFont(.caption).foregroundStyle(.secondary)
        } else if profile.services.contains(.payments) {
          Text("账户 \(profile.paymentAccounts.filter { includeClosed || $0.status != .closed }.count)")
            .appFont(.caption).foregroundStyle(.secondary)
        }
      }.padding(.vertical, 3)
    }
  }

  private extension FinancialInstitution {
    func accountCount(includeClosed: Bool) -> Int {
      switch kind {
      case .bank: bankAccounts.filter { includeClosed || $0.status != .closed }.count
      case .brokerage: brokerageAccounts.filter { includeClosed || $0.status != .closed }.count
      case .payment: paymentAccounts.filter { includeClosed || $0.status != .closed }.count
      case .other: 0
      }
    }
  }

  struct FinanceInstitutionDetailView: View {
    let institutionID: UUID
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing: FinancialInstitution?
    @State private var viewingCard: BankCard?
    @State private var viewingMethod: FinanceReceivingMethod?
    @State private var preview: FileAttachment?
    @State private var showClosedAccounts = false
    @State private var showClosedCards = false
    @State private var revealedLoginIDs: Set<UUID> = []
    @State private var attachmentError = false
    private var institution: FinancialInstitution? { store.financialInstitutions.first { $0.id == institutionID } }

    var body: some View {
      Group {
        if let institution {
          content(institution)
        } else {
          ContentUnavailableView("金融档案已不存在", systemImage: "folder")
        }
      }
      .appNavigationTitle(institution?.name ?? "金融档案")
      .diagnosticScreen("金融机构详情")
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            editing = institution
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .accessibilityLabel("编辑金融档案")
        }
      }
      .sheet(item: $editing) { value in
        switch value.kind {
        case .bank: FinanceInstitutionEditorView(institution: value, isNew: false, cards: store.cards(for: value)).iOSLargeSheet()
        case .brokerage: BrokerageInstitutionEditorView(institution: value, isNew: false).iOSLargeSheet()
        case .payment: PaymentInstitutionEditorView(institution: value, isNew: false).iOSLargeSheet()
        case .other: FinanceInstitutionEditorView(institution: value, isNew: false, cards: []).iOSLargeSheet()
        }
      }
      .sheet(item: $viewingCard) { CardDetailView(card: $0).iOSLargeSheet() }
      .sheet(item: $viewingMethod) { method in
        FinanceReceivingInfoView(institutionID: institutionID, methodID: method.id).iOSLargeSheet()
      }
      #if os(iOS)
        .sheet(item: $preview) { attachment in
          AttachmentPreviewSheet(
            attachment: attachment, url: store.attachmentURL(for: attachment),
            onDismiss: { preview = nil })
        }
      #endif
      .alert("文件暂不可用", isPresented: $attachmentError) { Button("确定", role: .cancel) {} }
      .onChange(of: scenePhase) { _, phase in if phase != .active { revealedLoginIDs.removeAll() } }
      .onDisappear { revealedLoginIDs.removeAll() }
    }

    private func content(_ institution: FinancialInstitution) -> some View {
      let profile = institution
      let cards = store.cards(for: institution)
      return List {
        Section {
          Label(profile.serviceSummary, systemImage: "building.2").appFont(.headline)
          FinanceInfoRow(title: "国家／地区", value: profile.country)
          FinanceInfoRow(title: "官网", value: profile.website)
          FinanceInfoRow(title: "联系电话", value: profile.phone)
          if institution.isInactiveFinanceArchive(cards: cards) {
            Label("已归档", systemImage: "archivebox").foregroundStyle(.secondary)
          }
          if !profile.note.isEmpty { Text(profile.note).copyableText(profile.note) }
        }
        if !profile.accounts.isEmpty {
          Section("账户") {
            ForEach(profile.accounts.filter { $0.status != .closed }) { account in
              NavigationLink {
                FinanceAccountInfoView(institutionID: institutionID, accountID: account.id)
              } label: {
                FinanceAccountRow(account: account, bankStyle: profile.services.contains(.banking))
              }
            }
            if profile.accounts.contains(where: { $0.status == .closed }) {
              Button(showClosedAccounts ? "隐藏已销户账户" : "显示已销户账户") { showClosedAccounts.toggle() }
              if showClosedAccounts {
                ForEach(profile.accounts.filter { $0.status == .closed }) { account in
                  NavigationLink {
                    FinanceAccountInfoView(institutionID: institutionID, accountID: account.id)
                  } label: {
                    FinanceAccountRow(
                      account: account, bankStyle: profile.services.contains(.banking))
                  }
                }
              }
            }
          }
        }
        if !cards.isEmpty {
          Section("卡片") {
            ForEach(cards.filter { $0.status != .closed }) { card in
              Button {
                viewingCard = card
              } label: {
                CardRow(card: card)
              }.buttonStyle(.plain)
            }
            if cards.contains(where: { $0.status == .closed }) {
              Button(showClosedCards ? "隐藏已销户卡片" : "显示已销户卡片") { showClosedCards.toggle() }
              if showClosedCards {
                ForEach(cards.filter { $0.status == .closed }) { card in
                  Button {
                    viewingCard = card
                  } label: {
                    CardRow(card: card)
                  }.buttonStyle(.plain)
                }
              }
            }
          }
        }
        if profile.kind != .payment && !profile.receivingMethods.isEmpty {
          Section("收款／入金资料") {
            ForEach(profile.receivingMethods) { method in
              Button {
                viewingMethod = method
              } label: {
                FinanceReceivingRow(method: method, accounts: profile.accounts)
              }.buttonStyle(.plain)
            }
          }
        }
        if !profile.logins.isEmpty {
          Section("登录信息") {
            ForEach(profile.logins) { login in
              loginCard(login, accounts: profile.accounts)
            }
          }
        }
        if !profile.documents.isEmpty {
          Section("文件") {
            ForEach(profile.documents) { document in
              Button {
                Task {
                  guard await auth.verifyWithBiometrics() else { return }
                  let url = store.attachmentURL(for: document.attachment)
                  guard FileManager.default.fileExists(atPath: url.path) else {
                    attachmentError = true
                    return
                  }
                  #if os(macOS)
                    NSWorkspace.shared.open(url)
                  #else
                    preview = document.attachment
                  #endif
                }
              } label: {
                Label(
                  document.title.isEmpty ? document.attachment.fileName : document.title,
                  systemImage: "doc")
              }
            }
          }
        }
        if institution.kind == .bank { FinanceInstitutionDetailsSection(institution: institution) }
        if profile.accounts.isEmpty && cards.isEmpty && profile.receivingMethods.isEmpty {
          Section {
            Text("点击右上角编辑，按需添加账户、卡片或收款资料。").foregroundStyle(.secondary)
          }
        }
      }
    }

    private func loginCard(_ login: FinanceLogin, accounts: [FinancialAccount]) -> some View {
      let revealed = revealedLoginIDs.contains(login.id)
      return VStack(alignment: .leading, spacing: 0) {
        if (institution?.logins.count ?? 0) > 1 || login.name != "登录信息" {
          Text(login.name).appFont(.headline).padding(.bottom, 10)
        }
        if !login.accountIDs.isEmpty {
          Text(
            accounts.filter { login.accountIDs.contains($0.id) }.map(\.displayName).joined(
              separator: "、")
          )
          .appFont(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
        ForEach(login.fields.filter { !$0.value.isEmpty }) { field in
          FinanceLoginFieldRow(field: field, revealed: revealed) {
            if revealed {
              revealedLoginIDs.remove(login.id)
            } else {
              Task { if await auth.verifyWithBiometrics() { revealedLoginIDs.insert(login.id) } }
            }
          }
          .padding(12)
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }

  }

  struct BrokerageInstitutionDetailView: View {
    let institutionID: UUID
    @EnvironmentObject private var store: FinanceStore
    @State private var editing: FinancialInstitution?
    @State private var confirmsDeletion = false
    @Environment(\.dismiss) private var dismiss
    private var institution: FinancialInstitution? { store.financialInstitutions.first { $0.id == institutionID } }
    var body: some View {
      Group {
        if let institution {
          List {
            Section("券商资料") {
              FinanceInfoRow(title: "机构", value: institution.name)
              FinanceInfoRow(title: "平台", value: institution.brokerage?.platform ?? "IBKR")
              FinanceInfoRow(title: "国家／地区", value: institution.country)
              if !institution.note.isEmpty { Text(institution.note).copyableText(institution.note) }
            }
            Section("券商账户") {
              ForEach(institution.brokerageAccounts.sorted { AppAlphabeticalSort.isOrderedBefore($1.displayName, $0.displayName, lhsTieBreaker: $1.id.uuidString, rhsTieBreaker: $0.id.uuidString) }) { account in
                NavigationLink { BrokerageAccountDetailView(institutionID: institutionID, accountID: account.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(account.name.isEmpty ? "未命名账户" : account.name).appFont(.headline)
                  Text(account.accountNumber.isEmpty ? "未填写账户号" : account.maskedAccountNumber).foregroundStyle(.secondary)
                  Text("\(account.accountType.title) · \(account.baseCurrency.rawValue) · \(account.ownership)").appFont(.caption).foregroundStyle(.secondary)
                }
                }
              }
            }
            if !institution.receivingMethods.isEmpty {
              Section("入金资料") {
                ForEach(institution.receivingMethods) { method in
                  NavigationLink { FinanceReceivingInfoView(institutionID: institutionID, methodID: method.id) } label: {
                    FinanceReceivingRow(method: method, accounts: [], linkedAccountName: institution.brokerageAccounts.first { $0.id == method.accountID }?.displayName)
                      .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                  }
                }
              }
            }
          }
          .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { editing = institution } label: { Image(systemName: "square.and.pencil") } }
            ToolbarItem(placement: .secondaryAction) { Button("删除券商档案", role: .destructive) { confirmsDeletion = true } }
          }
        } else { ContentUnavailableView("券商档案已不存在", systemImage: "chart.line.uptrend.xyaxis") }
      }
      .appNavigationTitle(institution?.name ?? "券商详情")
      .diagnosticScreen("券商机构详情")
      .alert("删除券商档案？", isPresented: $confirmsDeletion) {
        Button("删除", role: .destructive) { store.deleteAccount(id: institutionID); dismiss() }
        Button("取消", role: .cancel) {}
      } message: { Text("将删除此券商及其账户、入金资料和附件。此操作无法撤回。") }
      .sheet(item: $editing) { BrokerageInstitutionEditorView(institution: $0, isNew: false).iOSLargeSheet() }
    }
  }

  struct BrokerageAccountDetailView: View {
    let institutionID: UUID
    let accountID: UUID
    @EnvironmentObject private var store: FinanceStore
    @State private var editingInstitution: FinancialInstitution?
    private var account: BrokerageAccount? { store.financialInstitutions.first { $0.id == institutionID }?.brokerageAccounts.first { $0.id == accountID } }
    var body: some View {
      List {
        if let account {
          Section("账户资料") {
            AppAdaptiveRecordRow(title: "名称", value: account.displayName)
            if !account.accountNumber.isEmpty { AppAdaptiveRecordRow(title: "账户号", value: account.accountNumber) }
            if !account.holderName.isEmpty { AppAdaptiveRecordRow(title: "持有人", value: account.holderName) }
            if let date = account.openedAt { AppAdaptiveRecordRow(title: "开户日期", value: AppDateFormatter.string(from: date)) }
            AppAdaptiveRecordRow(title: "账户类型", value: account.accountType.title)
            AppAdaptiveRecordRow(title: "基准币种", value: account.baseCurrency.title)
            if !account.legalEntity.isEmpty { AppAdaptiveRecordRow(title: "开户实体", value: account.legalEntity) }
            if !account.ownership.isEmpty { AppAdaptiveRecordRow(title: "持有形式", value: account.ownership) }
            AppLabeledContentRow("状态") { AccountStatusText(status: account.status) }
            if !account.note.isEmpty { AppAdaptiveRecordRow(title: "备注", value: account.note) }
          }
        } else { ContentUnavailableView("券商账户已不存在", systemImage: "chart.line.uptrend.xyaxis") }
      }
      .appNavigationTitle(account?.displayName ?? "券商账户")
      .diagnosticScreen("券商账户详情")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            editingInstitution = store.financialInstitutions.first { $0.id == institutionID }
          } label: { Image(systemName: "square.and.pencil") }
          .disabled(account == nil)
        }
      }
      .sheet(item: $editingInstitution) { original in
        BrokerageAccountSaveView(original: original, accountID: accountID).iOSLargeSheet()
      }
    }
  }

  struct PaymentInstitutionDetailView: View {
    let institutionID: UUID
    @EnvironmentObject private var store: FinanceStore
    @State private var editing: FinancialInstitution?
    @State private var selectedAccountID: UUID?
    private var institution: FinancialInstitution? { store.financialInstitutions.first { $0.id == institutionID } }
    var body: some View {
      Group {
        if let institution {
          List {
            let platform = institution.payment?.platform.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Section("支付机构资料") {
              AppAdaptiveRecordRow(title: "机构", value: institution.name)
              if !platform.isEmpty { AppAdaptiveRecordRow(title: "平台", value: platform) }
              if let profileType = institution.payment?.profileType,
                 !profileType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppAdaptiveRecordRow(title: "资料类型", value: profileType)
              }
              if !institution.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppAdaptiveRecordRow(title: "国家／地区", value: institution.country)
              }
            }
            Section("多币种账户") {
              ForEach(institution.paymentAccounts.sorted { lhs, rhs in
                let left = CurrencyCode.financialOrdered(lhs.currencies).first.map { CurrencyCode.financialPriority.firstIndex(of: $0) ?? Int.max } ?? Int.max
                let right = CurrencyCode.financialOrdered(rhs.currencies).first.map { CurrencyCode.financialPriority.firstIndex(of: $0) ?? Int.max } ?? Int.max
                return left == right ? AppAlphabeticalSort.isOrderedBefore(rhs.displayName, lhs.displayName, lhsTieBreaker: rhs.id.uuidString, rhsTieBreaker: lhs.id.uuidString) : left < right
              }) { account in
                Button {
                  selectedAccountID = account.id
                } label: {
                  AppAdaptiveRecordRow(
                    title: account.name.isEmpty ? "未命名币种账户" : account.name,
                    value: [account.currencySummary.isEmpty ? "未设置币种" : account.currencySummary,
                            account.accountNumber.isEmpty ? "" : account.maskedAccountNumber]
                      .filter { !$0.isEmpty }.joined(separator: " · "),
                    titleFont: .headline,
                    valueFont: .caption,
                    verticalPadding: 0
                  )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
              }
            }
          }
          .toolbar { ToolbarItem(placement: .primaryAction) { Button { editing = institution } label: { Image(systemName: "square.and.pencil") } } }
        } else { ContentUnavailableView("支付机构档案已不存在", systemImage: "wallet.bifold") }
      }
      .appNavigationTitle(institution?.name ?? "支付机构详情")
      .diagnosticScreen("支付机构详情")
      .navigationDestination(item: $selectedAccountID) { accountID in
        PaymentAccountDetailView(institutionID: institutionID, accountID: accountID)
      }
      .sheet(item: $editing) { PaymentInstitutionEditorView(institution: $0, isNew: false).iOSLargeSheet() }
    }
  }

  struct PaymentAccountDetailView: View {
    let institutionID: UUID
    let accountID: UUID
    @EnvironmentObject private var store: FinanceStore
    @State private var editing: PaymentAccount?
    private var account: PaymentAccount? { store.financialInstitutions.first { $0.id == institutionID }?.paymentAccounts.first { $0.id == accountID } }
    var body: some View {
      List {
        if let account {
          Section("账户资料") {
            AppAdaptiveRecordRow(title: "名称", value: account.displayName)
            if !account.accountNumber.isEmpty { AppAdaptiveRecordRow(title: "账户号", value: account.accountNumber) }
            if !account.currencySummary.isEmpty { AppAdaptiveRecordRow(title: "币种", value: account.currencySummary) }
            HStack {
              Text("状态").foregroundStyle(.secondary)
              Spacer(minLength: 8)
              AccountStatusText(status: account.status)
            }
            .appListRowStyle()
          }
          if let receiving = account.receivingProfile {
            Section("收款信息") {
              if !receiving.details.name.isEmpty { AppAdaptiveRecordRow(title: "资料名称", value: receiving.details.name) }
              ForEach(receiving.details.fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { field in
                AppAdaptiveRecordRow(title: field.title, value: field.value)
              }
            }
          }
        } else { ContentUnavailableView("支付账户已不存在", systemImage: "wallet.bifold") }
      }
      .appNavigationTitle(account?.displayName ?? "支付账户")
      .diagnosticScreen("支付账户详情")
      .toolbar { ToolbarItem(placement: .primaryAction) { Button { editing = account } label: { Image(systemName: "square.and.pencil") } } }
      .sheet(item: $editing) { value in
        PaymentAccountEditorView(account: value, onSave: { updated in
          guard let original = store.financialInstitutions.first(where: { $0.id == institutionID }),
                var institution = store.financialInstitutions.first(where: { $0.id == institutionID }),
                let index = institution.paymentAccounts.firstIndex(where: { $0.id == updated.id }) else { return false }
          institution.paymentAccounts[index] = updated
          do { return try store.saveInstitution(institution, cards: [], expected: original, expectedCards: []) }
          catch { return false }
        }, isWise: {
          let platform = store.financialInstitutions.first { $0.id == institutionID }?.payment?.platform ?? ""
          return platform.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Wise") == .orderedSame
        }()).iOSLargeSheet()
      }
    }
  }

  private struct FinanceLoginFieldRow: View {
    let field: AdditionalLoginField
    let revealed: Bool
    let toggleReveal: () -> Void
    private var value: String { field.isSensitive && !revealed ? "••••••" : field.value }
    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(field.name).appFont(.caption).foregroundStyle(.secondary)
          Spacer()
          if field.isSensitive {
            Button(action: toggleReveal) { Image(systemName: revealed ? "eye.slash" : "eye") }
              .buttonStyle(.borderless)
              .accessibilityLabel(revealed ? "隐藏敏感信息" : "验证身份后显示敏感信息")
          }
        }
        Text(value).appFont(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .copyableText(field.isSensitive && !revealed ? nil : field.value)
      }

    }
  }

  struct FinanceAccountRow: View {
    let account: FinancialAccount
    var bankStyle = false
    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(bankStyle ? account.typeTitle : account.displayName).appFont(.headline).lineLimit(1)
          Spacer()
          AccountStatusText(status: account.status)
        }
        Text(account.maskedAccountNumber).appFont(.subheadline.monospacedDigit()).foregroundStyle(
          .secondary)
      }.padding(.vertical, 3).contentShape(Rectangle())
    }
  }

  struct FinanceReceivingRow: View {
    let method: FinanceReceivingMethod
    let accounts: [FinancialAccount]
    var linkedAccountName: String?
    var body: some View {
      AppAdaptiveRecordRow(
        title: method.details.displayName,
        value: [
          linkedAccountName ?? accounts.first { $0.id == method.accountID }?.displayName ?? "未关联账户",
          method.details.currencySummary
        ].filter { !$0.isEmpty }.joined(separator: " · "),
        titleFont: .headline,
        valueFont: .caption,
        verticalPadding: 0
      ).contentShape(Rectangle())
    }
  }

  struct FinanceInfoRow: View {
    let title: String
    let value: String
    var body: some View {
      if !value.isEmpty { DetailValueRow(title: title, value: value, alignment: .leading) }
    }
  }

  struct FinanceBranchNavigationRow: View {
    let institution: FinancialInstitution

    var body: some View {
      if institution.isOnlineBank {
        Text("网络银行")
      } else if !institution.branchName.isEmpty
        || institution.branchLocation != nil
      {
        Menu {
          ForEach(BankNavigationApplication.allCases) { app in
            Button {
              BankBranchNavigationService.open(
                app, branchName: institution.branchName,
                location: institution.branchLocation)
            } label: {
              Label(app.title, systemImage: app.systemImage)
            }
          }
        } label: {
          HStack(spacing: 8) {
            Image(
              systemName: institution.branchLocation?.isValid == true
                ? "mappin.and.ellipse"
                : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
              institution.branchLocation?.isValid == true ? .blue : .yellow)
            Text(
              institution.branchName.isEmpty
                ? "未填写" : institution.branchName
            )
            .foregroundStyle(.blue)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .copyableText(
          institution.branchName.isEmpty
            ? nil : institution.branchName)
      }
    }
  }

  struct FinanceInstitutionDetailsSection: View {
    let institution: FinancialInstitution
    var body: some View {
      if !institution.branchName.isEmpty
        || institution.branchLocation != nil
        || institution.isOnlineBank
      {
        Section("银行网点") { FinanceBranchNavigationRow(institution: institution) }
      }
      if ![
        institution.correspondenceAddressChinese,
        institution.correspondenceAddressEnglish,
        institution.residentialAddressChinese,
        institution.residentialAddressEnglish,
      ].allSatisfy(\.isEmpty) {
        Section("地址") {
          FinanceInfoRow(
            title: "通讯地址（中文）", value: institution.correspondenceAddressChinese)
          FinanceInfoRow(
            title: "通讯地址（英文）", value: institution.correspondenceAddressEnglish)
          FinanceInfoRow(
            title: "住宅地址（中文）", value: institution.residentialAddressChinese)
          FinanceInfoRow(
            title: "住宅地址（英文）", value: institution.residentialAddressEnglish)
        }
      }
    }
  }

  struct FinanceAccountInfoView: View {
    let institutionID: UUID
    let accountID: UUID
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var auth: AuthManager
    @State private var editing: FinanceRecordEditRequest?
    private var profile: FinancialInstitution? {
      store.financialInstitutions.first { $0.id == institutionID }
    }
    var body: some View {
      List {
        if let profile, let account = profile.allAccounts.first(where: { $0.id == accountID }) {
          let isPaymentAccount = profile.kind == .payment || profile.payment != nil || account.kind == .payment
          Section("账户资料") {
            if !profile.services.contains(.banking) && hasText(account.displayName) {
              AppAdaptiveRecordRow(title: "名称", value: account.displayName)
            }
            if hasText(account.typeTitle) { AppAdaptiveRecordRow(title: "类型", value: account.typeTitle) }
            if let brokerage = account.brokerage {
              AppAdaptiveRecordRow(title: "IBKR 账户类型", value: brokerage.accountType.title)
              AppAdaptiveRecordRow(title: "基准币种", value: brokerage.baseCurrency.title)
              if hasText(brokerage.legalEntity) { AppAdaptiveRecordRow(title: "开户实体", value: brokerage.legalEntity) }
              if hasText(brokerage.ownership) { AppAdaptiveRecordRow(title: "账户持有形式", value: brokerage.ownership) }
            }
            if hasText(account.accountNumber) { AppAdaptiveRecordRow(title: "账户号", value: account.accountNumber) }
            if hasText(account.holderName) { AppAdaptiveRecordRow(title: "持有人", value: account.holderName) }
            if hasText(account.currencySummary) { AppAdaptiveRecordRow(title: "币种", value: account.currencySummary) }
            if !isPaymentAccount && hasText(account.country) { AppAdaptiveRecordRow(title: "开户国家／地区", value: account.country) }
            if !isPaymentAccount && hasText(account.legalEntity) { AppAdaptiveRecordRow(title: "开户主体", value: account.legalEntity) }
            if !isPaymentAccount && hasText(account.branchName) { AppAdaptiveRecordRow(title: "开户网点", value: account.branchName) }
            if let date = account.openedAt, !isPaymentAccount {
              AppAdaptiveRecordRow(title: "开户日期", value: AppDateFormatter.string(from: date))
            }
            HStack {
              Text("状态")
              Spacer()
              AccountStatusText(status: account.status)
            }
            if hasText(account.note) { AppAdaptiveRecordRow(title: "备注", value: account.note) }
          }
          if isPaymentAccount, let receiving = account.receivingProfile {
            Section("收款信息") {
              if hasText(receiving.details.name) {
                AppAdaptiveRecordRow(title: "资料名称", value: receiving.details.name)
              }
              if hasText(receiving.details.currencySummary) {
                AppAdaptiveRecordRow(title: "币种", value: receiving.details.currencySummary)
              }
              ForEach(receiving.details.fields.filter { hasText($0.value) }) { field in
                AppAdaptiveRecordRow(title: field.title, value: field.value)
              }
            }
          }
          let cards = store.cards.filter {
            $0.accountID == institutionID
              && ($0.linkedFinancialAccountIDs ?? []).contains(accountID)
          }
          if !cards.isEmpty { Section("关联卡片") { ForEach(cards) { CardRow(card: $0) } } }
        } else {
          ContentUnavailableView("账户已不存在", systemImage: "wallet.bifold")
        }
      }
      .appNavigationTitle("账户资料")
      .diagnosticScreen("统一金融账户详情")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task {
              guard await auth.verifyWithBiometrics(),
                let institution = store.financialInstitutions.first(where: { $0.id == institutionID }),
                let account = institution.accounts.first(where: {
                  $0.id == accountID
                })
              else { return }
              editing = FinanceRecordEditRequest(
                institution: institution, record: .account(account))
            }
          } label: {
            Image(systemName: "square.and.pencil")
          }
        }
      }
      .sheet(item: $editing) { FinanceRecordEditor(request: $0).iOSLargeSheet() }
    }

    private func hasText(_ value: String) -> Bool {
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  struct FinanceReceivingInfoView: View {
    let institutionID: UUID
    let methodID: UUID
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var auth: AuthManager
    @State private var editing: FinanceRecordEditRequest?
    @Environment(\.dismiss) private var dismiss
    @State private var showsSharePreview = false
    private var method: FinanceReceivingMethod? {
      store.financialInstitutions.first { $0.id == institutionID }?.receivingMethods.first {
        $0.id == methodID
      }
    }
    var body: some View {
      NavigationStack {
        List {
          if let method {
            Section {
              FinanceInfoRow(title: "名称", value: method.details.displayName)
              FinanceInfoRow(title: "币种", value: method.details.currencySummary)
            }
            receivingFields(method.details)
            if !method.details.note.isEmpty {
              Section("备注") { Text(method.details.note).copyableText(method.details.note) }
            }
            Section { Button("预览并复制／分享收款资料") { showsSharePreview = true } }
          } else {
            ContentUnavailableView("收款方式已不存在", systemImage: "arrow.down.doc")
          }
        }
        .appNavigationTitle("收款／入金资料")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
          ToolbarItem(placement: .primaryAction) {
            Button {
              Task {
                guard await auth.verifyWithBiometrics(),
                  let institution = store.financialInstitutions.first(where: { $0.id == institutionID }),
                  let method
                else { return }
                editing = FinanceRecordEditRequest(
                  institution: institution, record: .receiving(method))
              }
            } label: {
              Image(systemName: "square.and.pencil")
            }
          }
        }
        .sheet(item: $editing) { FinanceRecordEditor(request: $0).iOSLargeSheet() }
        .sheet(isPresented: $showsSharePreview) {
          if let method {
            NavigationStack {
              ScrollView {
                Text(method.details.shareText).frame(maxWidth: .infinity, alignment: .leading)
                  .padding().copyableText(method.details.shareText)
              }
              .appNavigationTitle("收款资料预览")
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  Button("关闭") { showsSharePreview = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                  ShareLink(item: method.details.shareText)
                }
              }
            }.diagnosticScreen("收款资料分享预览")
          }
        }
      }.diagnosticScreen("收款方式详情")
    }
    private func receivingFields(_ details: FinanceReceivingDetails) -> some View {
      Section("收款资料") {
        ForEach(details.fields) { field in
          VStack(alignment: .leading, spacing: 5) {
            Text(field.title).appFont(.caption).foregroundStyle(
              field.kind == .reference ? .orange : .secondary)
            Text(field.value.isEmpty ? "未填写" : field.value).copyableText(
              field.value.isEmpty ? nil : field.value)
          }.padding(.vertical, 3)
        }
      }
    }
  }

#endif
