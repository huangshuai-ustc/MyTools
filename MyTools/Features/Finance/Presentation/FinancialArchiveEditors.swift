#if MYTOOLS_FEATURE_FINANCE
  import SwiftUI
  import UniformTypeIdentifiers

  private final class FinanceInstitutionDraft: ObservableObject {
    let original: FinancialInstitution
    let originalCards: [BankCard]
    @Published var institution: FinancialInstitution
    var cards: [BankCard] { get { institution.cards } set { institution.cards = newValue } }
    var attachmentSession: AttachmentEditSession
    init(institution: FinancialInstitution, cards: [BankCard]) {
      original = institution
      originalCards = cards
      var value = institution
      value.cards = cards
      self.institution = value
      attachmentSession = AttachmentEditSession(
        originalAttachments: institution.financeAttachments
          + cards.flatMap(\.statements).compactMap(\.attachment))
    }
    var envelope: FinancialInstitution { institution }
  }

  struct FinanceRecordEditRequest: Identifiable {
    enum Record {
      case account(FinancialAccount)
      case receiving(FinanceReceivingMethod)
      case login(FinanceLogin)
    }
    let id = UUID()
    let institution: FinancialInstitution
    let record: Record
  }

  /// Reuses the same editor for creation and detail editing, with an explicit save boundary.
  struct FinanceRecordEditor: View {
    @EnvironmentObject private var store: FinanceStore
    let request: FinanceRecordEditRequest
    @State private var errorMessage: String?
    private var profile: FinancialInstitution { request.institution }

    var body: some View {
      Group {
        switch request.record {
        case .account(let account):
          FinanceAccountEditorView(
            account: account, accounts: profile.accounts,
            isBank: profile.services.contains(.banking)
          ) { value in
            save { replace(value, in: &$0.accounts) }
          }
        case .receiving(let method):
          FinanceReceivingEditorView(method: method, accounts: profile.accounts, isBank: false) {
            value in
            save { replace(value, in: &$0.receivingMethods) }
          }
        case .login(let login):
          FinanceLoginEditorView(
            login: login, accounts: profile.accounts, region: profile.loginTemplateRegion
          ) { value in
            save { replace(value, in: &$0.logins) }
          }
        }
      }
      .alert(
        "无法保存",
        isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("确定", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
    }

    private func replace<T: Identifiable>(_ value: T, in values: inout [T]) {
      if let index = values.firstIndex(where: { $0.id == value.id }) {
        values[index] = value
      } else {
        values.append(value)
      }
    }

    private func save(_ edit: (inout FinancialInstitution) -> Void) -> Bool {
      do {
        var institution = request.institution
        var profile = self.profile
        edit(&profile)
        institution = profile
        let cards = store.cards(for: request.institution)
        guard
          try store.saveInstitution(
            institution, cards: cards, expected: request.institution, expectedCards: cards)
        else {
          errorMessage = "编辑期间资料已变化，请关闭后重新打开编辑。"
          return false
        }
        return true
      } catch {
        errorMessage = error.localizedDescription
        return false
      }
    }
  }

  struct FinanceInstitutionEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: FinanceInstitutionDraft
    let isNew: Bool
    @State private var editingAccount: FinancialAccount?
    @State private var editingCard: BankCard?
    @State private var editingMethod: FinanceReceivingMethod?
    @State private var editingLogin: FinanceLogin?
    @State private var editingDocument: FinanceDocument?
    @State private var pickingBranch = false
    @State private var importing = false
    @State private var importerPresented = false
    @State private var importTask: Task<Void, Never>?
    @State private var saved = false
    @State private var errorMessage: String?

    init(institution: FinancialInstitution, isNew: Bool, cards: [BankCard] = []) {
      _draft = StateObject(
        wrappedValue: FinanceInstitutionDraft(institution: institution, cards: cards))
      self.isNew = isNew
    }

    var body: some View {
      NavigationStack {
        Form {
          Group {
            Section("机构") {
              FieldEditorRow(title: "名称", prompt: "例如中国银行、支付平台或券商", text: $draft.institution.name)
              ReadOnlyFieldRow(title: "机构类型", value: draft.institution.serviceSummary)
              if draft.institution.kind == .bank {
                PickerFieldRow(title: "银行地区", selection: $draft.institution.region) {
                  ForEach(BankRegion.allCases) { Text($0.title).tag($0) }
                }
              }
              FieldEditorRow(title: "国家／地区", prompt: "可选", text: $draft.institution.country)
              FieldEditorRow(title: "官网", prompt: "可选", text: $draft.institution.website)
              FieldEditorRow(title: "客服电话", prompt: "可选", text: $draft.institution.phone)
            }
          }
          Group {
            Section {
              ForEach(draft.institution.accounts) { account in
                Button {
                  editingAccount = account
                } label: {
                  FinanceAccountRow(
                    account: account, bankStyle: draft.institution.services.contains(.banking))
                }.buttonStyle(.plain)
                  .appDeleteSwipeAction { removeAccount(account.id) }
              }
              Button {
                var account = FinancialAccount()
                if draft.institution.kind == .brokerage { account.kind = .securities; account.brokerage = BrokerageAccountDetails() }
                if draft.institution.kind == .payment { account.kind = .payment }
                editingAccount = account
              } label: {
                Label("添加账户", systemImage: "plus.circle")
              }
            } header: {
              Text(draft.institution.kind == .payment ? "币种收款账户" : "账户")
            } footer: {
              Text("机构下具有独立账号的账户，如投资、养老金、外汇账户。一个账户可以支持多个币种。")
            }
            if draft.institution.kind == .bank {
            Section("卡片") {
              ForEach(draft.cards) { card in
                Button {
                  editingCard = card
                } label: {
                  CardRow(card: card)
                }.buttonStyle(.plain)
                  .appDeleteSwipeAction { removeCard(card.id) }
              }
              Button {
                var card = BankCard()
                card.openingDateKnown = false
                card.expiryDateKnown = false
                editingCard = card
              } label: {
                Label("添加卡片", systemImage: "plus.circle")
              }
            }
            }
          }
          Group {
            Section("收款／入金资料") {
              ForEach(draft.institution.receivingMethods) { method in
                Button {
                  editingMethod = method
                } label: {
                  FinanceReceivingRow(method: method, accounts: draft.institution.accounts)
                }.buttonStyle(.plain)
                  .appDeleteSwipeAction { draft.institution.removeReceivingMethod(id: method.id) }
              }
              Button {
                var method = FinanceReceivingMethod()
                if draft.institution.kind == .brokerage { method.details.fields = FinanceReceivingTemplates.brokerageDeposit().map { FinanceReceivingField(kind: $0) } }
                editingMethod = method
              } label: {
                Label("添加收款资料", systemImage: "plus.circle")
              }
            }
            Section("登录信息") {
              ForEach(draft.institution.logins) { login in
                Button {
                  editingLogin = login
                } label: {
                  Label(login.name, systemImage: "key")
                }
                .appDeleteSwipeAction { draft.institution.logins.removeAll { $0.id == login.id } }
              }
              Button {
                var login = FinanceLogin()
                login.fields = store.makeLoginFields(for: draft.institution.loginTemplateRegion)
                editingLogin = login
              } label: {
                Label("添加登录信息", systemImage: "plus.circle")
              }
              if draft.institution.kind == .bank {
              Picker("新登录信息的字段模板", selection: $draft.institution.loginTemplateRegion) {
                ForEach(BankRegion.allCases) { Text($0.title).tag($0) }
              }.pickerStyle(.menu)
              }
            }
            Section("文件") {
              ForEach(draft.institution.documents) { document in
                Button {
                  editingDocument = document
                } label: {
                  Label(
                    document.title.isEmpty ? document.attachment.fileName : document.title,
                    systemImage: "doc"
                  ).foregroundStyle(.primary)
                }.appDeleteSwipeAction { removeDocument(document.id) }
              }
              Button {
                importerPresented = true
              } label: {
                Label("添加文件", systemImage: "doc.badge.plus")
              }.disabled(importing)
              if importing { ProgressView("正在导入文件") }
            }
            }
          }
          Group {
            if draft.institution.kind == .bank {
            Section("开户网点（可选）") {
              Toggle("网络银行", isOn: $draft.institution.isOnlineBank)
              OptionalOpeningDateRow(date: $draft.institution.openedAt)
              if !draft.institution.isOnlineBank {
                FieldEditorRow(title: "网点名称", prompt: "可选", text: $draft.institution.branchName)
                Button("选择地图位置") { pickingBranch = true }
              }
            }
          }
          Group {
            if draft.institution.kind == .bank {
            Section("通讯与住宅地址") {
              AppMultilineFieldRow(
                title: "通讯地址（中文）", text: $draft.institution.correspondenceAddressChinese)
              AppMultilineFieldRow(
                title: "通讯地址（英文）", text: $draft.institution.correspondenceAddressEnglish)
              AppMultilineFieldRow(
                title: "住宅地址（中文）", text: $draft.institution.residentialAddressChinese)
              AppMultilineFieldRow(
                title: "住宅地址（英文）", text: $draft.institution.residentialAddressEnglish)
            }
            }
            Section("备注") {
              AppMultilineFieldRow(title: "备注", text: $draft.institution.note)
            }
          }
        }
        .appNavigationTitle(isNew ? "添加金融机构" : "编辑金融档案")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { commitPendingTextInput { save() } }.disabled(importing)
          }
        }
        .sheet(item: $editingAccount) { account in
          FinanceAccountEditorView(
            account: account, accounts: draft.institution.accounts,
            isBank: draft.institution.services.contains(.banking)
          ) {
            upsert($0, in: &draft.institution.accounts)
            return true
          }.iOSLargeSheet()
        }
        .sheet(item: $editingCard) { card in
          CardEditorView(card: card, account: draft.envelope) { upsert($0, in: &draft.cards) }
            .iOSLargeSheet()
        }
        .sheet(item: $editingMethod) { method in
          FinanceReceivingEditorView(
            method: method, accounts: draft.institution.accounts,
            isBank: draft.institution.services.contains(.banking)
              && !draft.institution.services.contains(.payments)
          ) { value in
            upsert(value, in: &draft.institution.receivingMethods)
            return true
          }.iOSLargeSheet()
        }
        .sheet(item: $editingLogin) { login in
          FinanceLoginEditorView(
            login: login, accounts: draft.institution.accounts,
            region: draft.institution.loginTemplateRegion
          ) {
            upsert($0, in: &draft.institution.logins)
            return true
          }.iOSLargeSheet()
        }
        .sheet(item: $editingDocument) { document in
          FinanceDocumentEditorView(document: document, profile: draft.institution) {
            upsert($0, in: &draft.institution.documents)
          }.iOSLargeSheet()
        }
        .sheet(isPresented: $pickingBranch) {
          BankBranchLocationPickerView(
            branchName: draft.institution.branchName, location: draft.institution.branchLocation
          ) {
            draft.institution.branchName = $0.name
            draft.institution.branchLocation = $0.location
          }.iOSLargeSheet()
        }
        .fileImporter(
          isPresented: $importerPresented, allowedContentTypes: [.pdf, .image, .plainText],
          allowsMultipleSelection: false, onCompletion: importFile
        )
        .alert(
          "无法保存金融档案",
          isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
          Button("确定", role: .cancel) {}
        } message: {
          Text(errorMessage ?? "")
        }
        .onDisappear(perform: cleanup)
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          .scrollDismissesKeyboard(.interactively)
        #endif
      }.diagnosticScreen("统一金融档案编辑")
    }

    private func upsert<T: Identifiable>(_ value: T, in values: inout [T]) {
      if let card = value as? BankCard {
        for file in card.statements.compactMap(\.attachment) {
          draft.attachmentSession.trackRename(file)
        }
      }
      if let index = values.firstIndex(where: { $0.id == value.id }) {
        values[index] = value
      } else {
        values.append(value)
      }
    }

    private func save() {
      draft.institution.name = draft.institution.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !draft.institution.name.isEmpty else {
        errorMessage = "请填写机构名称。"
        return
      }

      do {
        guard
          try store.saveInstitution(
            draft.envelope, cards: draft.cards, expected: isNew ? nil : draft.original,
            expectedCards: draft.originalCards)
        else {
          errorMessage = "档案或卡片在编辑期间已发生变化。草稿已保留，请重新核对后再编辑。"
          return
        }
        saved = true
        draft.attachmentSession.commit()
        dismiss()
      } catch { errorMessage = error.localizedDescription }
    }

    private var originalAttachmentIDs: Set<UUID> {
      Set(
        (draft.original.financeAttachments
          + draft.originalCards.flatMap(\.statements).compactMap(\.attachment)).map(\.id))
    }
    private func removeAccount(_ id: UUID) {
      draft.institution.removeAccount(id: id)
      for index in draft.cards.indices { draft.cards[index].linkedFinancialAccountIDs?.remove(id) }
    }
    private func removeCard(_ id: UUID) {
      if let card = draft.cards.first(where: { $0.id == id }) {
        for file in card.statements.compactMap(\.attachment)
        where !originalAttachmentIDs.contains(file.id) { store.deleteUncommittedAttachment(file) }
      }
      draft.cards.removeAll { $0.id == id }
      for index in draft.cards.indices where draft.cards[index].replacedByCardID == id {
        draft.cards[index].replacedByCardID = nil
      }
    }
    private func removeDocument(_ id: UUID) {
      if let document = draft.institution.documents.first(where: { $0.id == id }),
        !originalAttachmentIDs.contains(document.attachment.id)
      {
        store.deleteUncommittedAttachment(document.attachment)
      }
      draft.institution.documents.removeAll { $0.id == id }
    }
    private func importFile(_ result: Result<[URL], Error>) {
      do {
        guard let url = try result.get().first else { return }
        importing = true
        importTask = Task { @MainActor in
          defer { importing = false }
          do {
            let file = try await store.importFinanceDocument(from: url)
            guard !Task.isCancelled else {
              store.deleteUncommittedAttachment(file)
              return
            }
            draft.institution.documents.append(FinanceDocument(title: file.fileName, attachment: file))
          } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
      } catch { errorMessage = error.localizedDescription }
    }
    private func cleanup() {
      importTask?.cancel()
      guard !saved else { return }
      let files =
        draft.institution.documents.map(\.attachment)
        + draft.cards.flatMap(\.statements).compactMap(\.attachment)
      let failures = draft.attachmentSession.rollback(
        currentAttachments: files, delete: store.deleteUncommittedAttachment,
        restoreLocation: store.restoreAttachmentLocation)
      if !failures.isEmpty {
        DiagnosticLogger.shared.log(.data, "金融草稿附件恢复失败 count=\(failures.count)", level: .error)
      }
    }
  }

  struct BrokerageInstitutionEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State var institution: FinancialInstitution
    let isNew: Bool
    let original: FinancialInstitution
    init(institution: FinancialInstitution, isNew: Bool) { _institution = State(initialValue: institution); self.isNew = isNew; self.original = institution }
    var body: some View {
      NavigationStack {
        Form {
          Section("IBKR 券商") {
            FieldEditorRow(title: "机构名称", prompt: "例如 Interactive Brokers", text: $institution.name)
            FieldEditorRow(title: "国家／地区", prompt: "可选", text: $institution.country)
            FieldEditorRow(title: "官网", prompt: "可选", text: $institution.website)
            FieldEditorRow(title: "平台", prompt: "IBKR", text: Binding(get: { institution.brokerage?.platform ?? "IBKR" }, set: { institution.brokerage?.platform = $0 }))
          }
          Section("账户") {
            ForEach(institution.brokerageAccounts) { account in
              NavigationLink { BrokerageAccountDetailView(institutionID: institution.id, accountID: account.id) } label: {
                VStack(alignment: .leading) { Text(account.displayName).appFont(.headline); Text(account.maskedAccountNumber).foregroundStyle(.secondary) }
              }
            }
            Button {
              institution.brokerageAccounts.append(BrokerageAccount())
            } label: { Label("添加 IBKR 账户", systemImage: "plus.circle") }
          }
          Section("入金资料") {
            ForEach(institution.receivingMethods) { method in FinanceReceivingRow(method: method, accounts: []) }
            Button {
              var method = FinanceReceivingMethod(); method.details.fields = FinanceReceivingTemplates.brokerageDeposit().map { FinanceReceivingField(kind: $0) }; institution.receivingMethods.append(method)
            } label: { Label("添加入金资料", systemImage: "plus.circle") }
          }
          Section("备注") { AppMultilineFieldRow(title: "备注", text: $institution.note) }
        }
        .appNavigationTitle(isNew ? "添加券商档案" : "编辑券商档案")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { commitPendingTextInput { do { try store.saveInstitution(institution, cards: [], expected: isNew ? nil : original, expectedCards: []); dismiss() } catch {} } }
          }
        }
      }.diagnosticScreen("券商机构编辑")
    }
  }

  struct PaymentInstitutionEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State var institution: FinancialInstitution
    let isNew: Bool
    let original: FinancialInstitution
    @State private var editingAccount: PaymentAccount?
    @State private var editingMethod: FinanceReceivingMethod?
    @State private var editingWiseTemplate = false
    private var isWise: Bool { institution.payment?.platform.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Wise") == .orderedSame }
    private var sortedPaymentAccounts: [PaymentAccount] {
      institution.paymentAccounts.sorted { lhs, rhs in
        let left = CurrencyCode.financialOrdered(lhs.currencies).first.map { CurrencyCode.financialPriority.firstIndex(of: $0) ?? Int.max } ?? Int.max
        let right = CurrencyCode.financialOrdered(rhs.currencies).first.map { CurrencyCode.financialPriority.firstIndex(of: $0) ?? Int.max } ?? Int.max
        if left != right { return left < right }
        return AppAlphabeticalSort.isOrderedBefore(rhs.displayName, lhs.displayName, lhsTieBreaker: rhs.id.uuidString, rhsTieBreaker: lhs.id.uuidString)
      }
    }
    init(institution: FinancialInstitution, isNew: Bool) { _institution = State(initialValue: institution); self.isNew = isNew; self.original = institution }
    var body: some View {
      NavigationStack {
        Form {
          Section(isWise ? "Wise 支付机构" : "支付机构资料") {
            FieldEditorRow(title: "机构名称", prompt: "例如支付平台名称", text: $institution.name)
            FieldEditorRow(title: "平台", prompt: "例如 Wise、PayPal 或其他平台", text: Binding(get: { institution.payment?.platform ?? "" }, set: { institution.payment?.platform = $0 }))
            FieldEditorRow(title: "资料类型", prompt: "个人或企业", text: Binding(get: { institution.payment?.profileType ?? "个人" }, set: { institution.payment?.profileType = $0 }))
            FieldEditorRow(title: "国家／地区", prompt: "可选", text: $institution.country)
            if isWise { Button { editingWiseTemplate = true } label: { Label("编辑 Wise 收款模板", systemImage: "slider.horizontal.3") } }
          }
          Section("币种账户") {
            ForEach(sortedPaymentAccounts) { account in
              PaymentAccountEditorRow(account: account) { editingAccount = account }
              .buttonStyle(.plain)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
              .appDeleteSwipeAction { institution.paymentAccounts.removeAll { $0.id == account.id } }
            }
            Button {
              editingAccount = PaymentAccount()
            } label: { Label("添加币种账户", systemImage: "plus.circle") }
          }
          Section("备注") { AppMultilineFieldRow(title: "备注", text: $institution.note) }
        }
        .appNavigationTitle(isNew ? "添加支付机构" : "编辑支付机构")
        .sheet(isPresented: $editingWiseTemplate) { WiseReceivingTemplateEditor().iOSLargeSheet() }
        .sheet(item: $editingAccount) { account in
          PaymentAccountEditorView(account: account, onSave: { value in
            if let index = institution.paymentAccounts.firstIndex(where: { $0.id == value.id }) { institution.paymentAccounts[index] = value }
            else { institution.paymentAccounts.append(value) }
            return true
          }, isWise: isWise).iOSLargeSheet()
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { commitPendingTextInput { do { try store.saveInstitution(institution, cards: [], expected: isNew ? nil : original, expectedCards: []); dismiss() } catch {} } }
          }
        }
      }.diagnosticScreen("支付机构编辑")
    }
  }

  private struct PaymentAccountEditorRow: View {
    let account: PaymentAccount
    let action: () -> Void
    var body: some View {
      Button(action: action) {
        AppAdaptiveRecordRow(
          title: account.name.isEmpty ? "未命名币种账户" : account.name,
          value: [
            account.currencySummary.isEmpty ? "未设置币种" : account.currencySummary,
            account.maskedAccountNumber.isEmpty ? "" : account.maskedAccountNumber
          ].filter { !$0.isEmpty }.joined(separator: " · "),
          titleFont: .body,
          valueFont: .caption,
          verticalPadding: 0
        )
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
  }

  struct PaymentAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var account: PaymentAccount
    let onSave: (PaymentAccount) -> Bool
    let isWise: Bool
    @State private var editingProfile: FinanceReceivingMethod?
    var body: some View {
      NavigationStack {
        Form {
          Section("币种账户") {
            FieldEditorRow(title: "名称", prompt: "例如港元账户", text: $account.name)
            FieldEditorRow(title: "账户号", prompt: "可选", text: $account.accountNumber)
            CurrencySelectionRows(currencies: $account.currencies, region: .overseas, wrapsInField: true)
            CardStatusDisclosurePicker(title: "状态", status: $account.status)
          }
          Section(isWise ? "Wise 收款资料" : "收款资料") {
              if let profile = account.receivingProfile {
              Button { editingProfile = profile } label: { FinanceReceivingRow(method: profile, accounts: [], linkedAccountName: account.displayName) }.buttonStyle(.plain)
            }
            Button {
              var profile = account.receivingProfile ?? FinanceReceivingMethod()
              profile.accountID = account.id
              if account.receivingProfile == nil {
                profile.details.fields = FinanceReceivingTemplates.wiseTemplate(for: account.currencies).map { FinanceReceivingField(kind: $0) }
                profile.details.name = account.currencySummary.isEmpty ? "通用收款" : "\(account.currencySummary) 收款"
              }
              editingProfile = profile
            } label: {
              Label(account.receivingProfile == nil ? "添加收款资料" : "编辑收款资料", systemImage: "pencil")
            }
          }
          Section("备注") { AppMultilineFieldRow(title: "备注", text: $account.note) }
        }
        .appNavigationTitle(isWise ? "Wise 币种账户" : "币种账户")
        .sheet(item: $editingProfile) { profile in
          FinanceReceivingEditorView(method: profile, accounts: [], isBank: false, onSave: { value in account.receivingProfile = value; return true }, isWise: isWise, isBoundToAccount: true).iOSLargeSheet()
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) { Button("保存") { commitPendingTextInput { if onSave(account) { dismiss() } } } }
        }
      }
    }
  }

  private struct WiseReceivingTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currency: CurrencyCode = .usd
    @State private var isOther = false
    @State private var fields: Set<FinanceReceivingFieldKind> = []
    private var available: [FinanceReceivingFieldKind] { [.beneficiary, .bankNameAndAddress, .aba, .sortCode, .bsb, .bankCode, .branchCode, .institutionNumber, .accountType, .bankAccountNumber, .iban, .bic, .reference, .instructions] }
    var body: some View {
      NavigationStack {
        Form {
          Picker("模板", selection: $isOther) {
            Text(FinanceReceivingTemplates.wiseOtherCurrency).tag(true)
            Text("截图币种").tag(false)
          }
          if !isOther { Picker("币种", selection: $currency) { ForEach(FinanceReceivingTemplates.wiseScreenshotCurrencies, id: \.self) { Text($0.title).tag($0) } } }
          Section("字段") {
            ForEach(available, id: \.self) { field in
              Toggle(field.title, isOn: Binding(get: { fields.contains(field) }, set: { if $0 { fields.insert(field) } else { fields.remove(field) } }))
            }
          }
        }
        .appNavigationTitle("Wise 收款模板")
        .onAppear { fields = Set(isOther ? FinanceReceivingTemplates.wiseOtherConfigured() : FinanceReceivingTemplates.wise(currency: currency)) }
        .onChange(of: isOther) { _, value in fields = Set(value ? FinanceReceivingTemplates.wiseOtherConfigured() : FinanceReceivingTemplates.wise(currency: currency)) }
        .onChange(of: currency) { _, value in fields = Set(FinanceReceivingTemplates.wise(currency: value)) }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) { Button("保存") { if isOther { FinanceReceivingTemplates.saveWiseOther(fields: Array(fields)) } else { FinanceReceivingTemplates.saveWise(currency: currency, fields: Array(fields)) }; dismiss() } }
        }
      }
    }
  }

  struct FinanceAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var account: FinancialAccount
    let accounts: [FinancialAccount]
    let isBank: Bool
    var isSubaccount = false
    let onSave: (FinancialAccount) -> Bool
    @State private var editingSubaccount: FinancialAccount?
    @State private var editingReceivingProfile: FinanceReceivingMethod?

    var body: some View {
      NavigationStack {
        Form {
          Section("账户") {
            FieldEditorRow(title: "名称", prompt: "账户或子账户名称", text: $account.name)
            Picker("类型", selection: $account.kind) {
              ForEach(FinanceAccountKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            if account.kind == .other {
              FieldEditorRow(title: "自定义类型", prompt: "可选", text: $account.customType)
            }
            FieldEditorRow(title: "账户号", prompt: "没有独立账号可留空", text: $account.accountNumber)
            FieldEditorRow(title: "持有人", prompt: "可选，联名可填写多人", text: $account.holderName)

          }
          if isBank && !isSubaccount {
            Section("子账户") {
              ForEach(account.subaccounts) { child in
                Button { editingSubaccount = child } label: { FinanceAccountRow(account: child, bankStyle: true) }
                  .appDeleteSwipeAction { account.subaccounts.removeAll { $0.id == child.id } }
              }
              Button { editingSubaccount = FinancialAccount() } label: { Label("添加子账户", systemImage: "plus") }
            }
          }
          if account.brokerage != nil {
            Section("IBKR 账户") {
              BrokerageAccountFieldsEditor(details: Binding(get: { account.brokerage! }, set: { account.brokerage = $0 }))
            }
          }
          if account.kind == .payment {
            Section("收款资料") {
              if let profile = account.receivingProfile {
                Button { editingReceivingProfile = profile } label: {
                  FinanceReceivingRow(method: profile, accounts: [account])
                }.buttonStyle(.plain)
              }
              Button {
                var profile = account.receivingProfile ?? FinanceReceivingMethod()
                profile.accountID = account.id
                if account.receivingProfile == nil {
                  profile.details.fields = FinanceReceivingTemplates.wiseTemplate(for: account.currencies).map { FinanceReceivingField(kind: $0) }
                  profile.details.name = account.currencySummary.isEmpty ? "通用收款" : "\(account.currencySummary) 收款"
                }
                editingReceivingProfile = profile
              } label: {
                Label(account.receivingProfile == nil ? "添加收款资料" : "编辑收款资料", systemImage: "pencil")
              }
            }
          }
          Section {
            CurrencySelectionRows(currencies: $account.currencies, region: .overseas)
          } header: {
            Text("已开通币种")
          } footer: {
            Text(isBank ? "主账户和子账户可分别记录已开通币种。" : "这里只记录账户资料，不维护投资持仓或资金流水。")
          }
          Section("状态与备注") {
            CardStatusDisclosurePicker(title: "账户状态", status: $account.status)
            AppMultilineFieldRow(title: "备注", text: $account.note)
          }
        }
        .sheet(item: $editingSubaccount) { child in
          FinanceAccountEditorView(account: child, accounts: [], isBank: true, isSubaccount: true) { child in
            if let i = account.subaccounts.firstIndex(where: { $0.id == child.id }) { account.subaccounts[i] = child }
            else { account.subaccounts.append(child) }
            return true
          }.iOSLargeSheet()
        }
        .sheet(item: $editingReceivingProfile) { profile in
          FinanceReceivingEditorView(method: profile, accounts: [account], isBank: false) { value in
            account.receivingProfile = value
            return true
          }.iOSLargeSheet()
        }
        .appNavigationTitle(isSubaccount ? "子账户资料" : "账户资料")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { commitPendingTextInput { if onSave(account) { dismiss() } } }
          }
        }
      }.diagnosticScreen("统一金融账户编辑")
    }

  }

  struct FinanceReceivingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var method: FinanceReceivingMethod
    let accounts: [FinancialAccount]
    let isBank: Bool
    let onSave: (FinanceReceivingMethod) -> Bool
    var isWise = false
    var isBoundToAccount = false
    private var isInlinePaymentProfile: Bool {
      isBoundToAccount || (accounts.count == 1 && accounts.first?.kind == .payment)
    }
    var body: some View {
      NavigationStack {
        Form {
          Section("适用范围") {
            FieldEditorRow(title: "名称", prompt: "可选，例如美元收款资料", text: $method.details.name)
            if !isInlinePaymentProfile {
              Picker("转入账户", selection: $method.accountID) {
                Text("暂未关联").tag(nil as UUID?)
                ForEach(accounts) { Text($0.displayName).tag(Optional($0.id)) }
              }
              .pickerStyle(.menu)
            }
          }
          if !isInlinePaymentProfile {
          Section("收款币种") {
            CurrencySelectionRows(
              currencies: Binding(
                get: { method.details.effectiveCurrencies },
                set: { selected in
                  method.details.currencies = selected
                  method.details.currency = CurrencyCode.displayOrdered(selected).first
                }
              ))
          }
          }
          Section {
            ForEach($method.details.fields) { $field in
              AppAdaptiveEditableRow(
                title: field.kind == .custom ? "自定义字段" : field.title,
                prefersStacked: [.beneficiaryAddress, .bankName, .bankAddress, .bankNameAndAddress, .instructions].contains(field.kind)
              ) {
                VStack(alignment: .leading, spacing: 5) {
                  if field.kind == .custom {
                    IMESafeTextField(prompt: "字段名称", text: $field.customName)
                  }
                  if [.bankNameAndAddress, .bankAddress, .instructions].contains(field.kind) {
                    IMESafeMultilineTextField(
                      prompt: "请输入机构提供的原始资料",
                      text: $field.value,
                      minHeight: 44,
                      maxHeight: 120
                    )
                  } else {
                    IMESafeTextField(prompt: "请输入机构提供的原始资料", text: $field.value, alignment: .leading)
                  }
                }
              }
              .appDeleteSwipeAction { method.details.fields.removeAll { $0.id == field.id } }
            }
            Menu {
              Button("国际汇款模板") { addFields(FinanceReceivingTemplates.bankTransfer()) }
              Button("IBKR 入金模板") { addFields(FinanceReceivingTemplates.brokerageDeposit()) }
              if isWise { Menu("Wise 收款模板") {
              ForEach(FinanceReceivingTemplates.wiseScreenshotCurrencies, id: \.self) { currency in
                  Button(currency.title) {
                    if !isInlinePaymentProfile {
                      method.details.currencies = [currency]
                      method.details.name = method.details.name.isEmpty ? "Wise " + currency.rawValue + " 收款" : method.details.name
                    }
                    addFields(FinanceReceivingTemplates.wise(currency: currency))
                  }
                }
              Button(FinanceReceivingTemplates.wiseOtherCurrency) {
                addFields(FinanceReceivingTemplates.wiseOtherConfigured())
              }
              } }
              Button("只添加一个字段") { method.details.fields.append(FinanceReceivingField()) }
            } label: { Label("使用收款模板", systemImage: "plus.circle") }
          } header: {
            Text("收款资料")
          } footer: {
            Text("证券账户号、收款银行账号和最终入账附言请分别填写。没有普通账号时可仅填写 IBAN。")
          }
          Section("备注") { AppMultilineFieldRow(title: "备注", text: $method.details.note) }
        }
        .appNavigationTitle("收款／入金方式")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { commitPendingTextInput { if isInlinePaymentProfile, method.accountID == nil { method.accountID = accounts[0].id }; if onSave(method) { dismiss() } } }
          }
        }
      }.diagnosticScreen("收款方式编辑")
    }
    private func addFields(_ kinds: [FinanceReceivingFieldKind]) {
      for kind in kinds where !method.details.fields.contains(where: { $0.kind == kind }) {
        method.details.fields.append(FinanceReceivingField(kind: kind))
      }
    }
  }

  private extension PaymentInstitutionEditorView {
    static func accountDescending(_ lhs: FinancialAccount, _ rhs: FinancialAccount) -> Bool {
      AppAlphabeticalSort.isOrderedBefore(rhs.displayName, lhs.displayName, lhsTieBreaker: rhs.id.uuidString, rhsTieBreaker: lhs.id.uuidString)
    }
  }

  struct FinanceLoginEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State var login: FinanceLogin
    let accounts: [FinancialAccount]
    let region: BankRegion
    let onSave: (FinanceLogin) -> Bool
    @State private var editingTemplate = false
    var body: some View {
      NavigationStack {
        Form {
          Section {
            FieldEditorRow(title: "名称", prompt: "例如网银、交易平台", text: $login.name)
            if !accounts.isEmpty {
              DisclosureGroup {
                ForEach(accounts) { account in
                  Button {
                    if login.accountIDs.contains(account.id) {
                      login.accountIDs.remove(account.id)
                    } else {
                      login.accountIDs.insert(account.id)
                    }
                  } label: {
                    HStack {
                      Text(account.displayName).foregroundStyle(.primary)
                      Spacer()
                      Image(
                        systemName: login.accountIDs.contains(account.id)
                          ? "checkmark.square.fill" : "square"
                      )
                      .foregroundStyle(
                        login.accountIDs.contains(account.id) ? Color.accentColor : Color.secondary)
                    }.contentShape(Rectangle())
                  }.buttonStyle(.plain)
                }
              } label: {
                HStack {
                  Text("关联账户").foregroundStyle(.secondary)
                  Spacer()
                  Text(login.accountIDs.isEmpty ? "机构通用" : "已选 \(login.accountIDs.count) 个")
                    .foregroundStyle(.primary)
                }
              }
            }
          }
          Section("登录字段") {
            ForEach($login.fields) { $field in
              HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                  IMESafeTextField(prompt: "字段名称", text: $field.name)
                  if field.isSensitive { SecureField("内容", text: $field.value) }
                  else { IMESafeMultilineTextField(prompt: "内容", text: $field.value) }
                }
                Toggle("敏感", isOn: $field.isSensitive).labelsHidden().frame(width: 52)
              }
              .padding(.vertical, 4)
              .appDeleteSwipeAction { login.fields.removeAll { $0.id == field.id } }
            }
            HStack {
              Button { login.fields.append(AdditionalLoginField()) } label: { Label("添加字段", systemImage: "plus") }
              Spacer()
              Button("管理模板") { editingTemplate = true }
            }
          }
        }
        .appNavigationTitle("登录信息")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { commitPendingTextInput { if onSave(login) { dismiss() } } }
          }
        }
        .sheet(isPresented: $editingTemplate) {
          BankLoginTemplateEditorView(
            region: region, templates: store.loginFieldTemplates(for: region)
          ).iOSLargeSheet()
        }
      }.diagnosticScreen("金融登录信息编辑")
    }
  }

  struct FinanceDocumentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var document: FinanceDocument
    let profile: FinancialInstitution
    let onSave: (FinanceDocument) -> Void
    var body: some View {
      NavigationStack {
        Form {
          FieldEditorRow(title: "文件标题", prompt: "可选", text: $document.title)
          Text(document.attachment.fileName).foregroundStyle(.secondary)
          Picker("关联账户", selection: $document.accountID) {
            Text("机构资料").tag(nil as UUID?)
            ForEach(profile.accounts) { Text($0.displayName).tag(Optional($0.id)) }
          }
          .pickerStyle(.menu)
          Picker("关联收款方式", selection: $document.receivingMethodID) {
            Text("无").tag(nil as UUID?)
            ForEach(profile.receivingMethods) { Text($0.details.displayName).tag(Optional($0.id)) }
          }
          .pickerStyle(.menu)
        }
        .appNavigationTitle("文件资料")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") {
              commitPendingTextInput {
                onSave(document)
                dismiss()
              }
            }
          }
        }
      }.diagnosticScreen("金融文件资料编辑")
    }
  }
  private struct BrokerageAccountFieldsEditor: View {
    @Binding var details: BrokerageAccountDetails
    var body: some View {
      PickerFieldRow(title: "账户类型", selection: $details.accountType) { ForEach(BrokerageAccountType.allCases) { Text($0.title).tag($0) } }
      PickerFieldRow(title: "基准币种", selection: $details.baseCurrency) { ForEach(CurrencyCode.selectableCases(including: details.baseCurrency)) { Text($0.title).tag($0) } }
      FieldEditorRow(title: "开户实体", prompt: "例如 Interactive Brokers LLC", text: $details.legalEntity)
      FieldEditorRow(title: "账户持有形式", prompt: "个人、联名或机构", text: $details.ownership)
      OptionalOpeningDateRow(date: $details.openedAt)
    }
  }
  private struct OptionalOpeningDateRow: View {
    @Binding var date: Date?
    var body: some View {
      ToggleFieldRow(title: "已知开户日期", isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? Date()) : nil }))
      if date != nil { DateFieldRow(title: "开户日期", date: Binding(get: { date ?? Date() }, set: { date = $0 })) }
    }
  }
#endif
