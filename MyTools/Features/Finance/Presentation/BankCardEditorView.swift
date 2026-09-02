#if MYTOOLS_FEATURE_FINANCE
import SwiftUI
import UniformTypeIdentifiers

private final class BankCardEditorDraft: ObservableObject {
    @Published var card: BankCard
    init(card: BankCard) { self.card = card }
}

struct CardEditorView: View {
    private enum Field: Hashable { case cvv }

    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: BankCardEditorDraft
    @FocusState private var focusedField: Field?
    @State private var editingStatement: CreditCardStatement?
    @State private var editingCredential: BankCardCredential?
    @State private var showingBranchLocationPicker = false
    @State private var didSave = false
    let account: BankAccount
    let onSave: (BankCard) -> Void
    private let navigationTitle: String
    private let originalAttachmentIDs: Set<UUID>

    init(card: BankCard, account: BankAccount, onSave: @escaping (BankCard) -> Void) {
        var initialCard = card
        let isNewCard = card.accountID == nil
        if account.region == .domestic {
            initialCard.applyDefaultOpeningBranch(from: account)
            if isNewCard, initialCard.currencies.isEmpty {
                initialCard.currencies = [.cny]
            }
        }
        _draft = StateObject(wrappedValue: BankCardEditorDraft(card: initialCard))
        self.account = account
        self.onSave = onSave
        originalAttachmentIDs = Set(card.statements.compactMap { $0.attachment?.id })
        navigationTitle = isNewCard ? "新增银行卡" : "编辑银行卡"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行卡") {
                    Picker("卡片类型：", selection: $draft.card.kind) {
                        ForEach(BankCardKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DisclosureGroup {
                        ForEach(CardNetwork.allCases) { network in
                            Button { toggleNetwork(network) } label: {
                                HStack {
                                    Text(network.title).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: draft.card.networks.contains(network) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(draft.card.networks.contains(network) ? Color.accentColor : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Text("发卡组织")
                            .foregroundStyle(.secondary)
                    }
                    FieldEditorRow(title: "卡片名称：", prompt: "可选，如 Visa 白金卡", text: $draft.card.cardType)
                    if account.region == .domestic {
                        AppLabeledContentRow("开卡网点") {
                            if account.isOnlineBank {
                                Text("网络银行")
                            } else {
                                Button {
                                    showingBranchLocationPicker = true
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
                    }
                    CardStatusDisclosurePicker(status: $draft.card.status)
                    FieldEditorRow(
                        title: "持卡人：",
                        prompt: account.region == .overseas ? "拼音，如 HUANG SHUAI" : "未填写",
                        text: $draft.card.holderName,
                        mode: account.region == .overseas ? .asciiUppercase : .text
                    )
                    FieldEditorRow(title: "完整卡号：", prompt: "未填写", text: $draft.card.cardNumber)
                    FieldEditorRow(title: "CVV：", prompt: "未填写", text: $draft.card.cvv)
                        .focused($focusedField, equals: .cvv)
                    YearMonthPicker(date: $draft.card.expiryDate)
                    DateFieldRow(title: "开卡时间：", date: $draft.card.openedAt)
                }
                Section {
                    ForEach(draft.card.additionalCredentials) { credential in
                        Button { editingCredential = credential } label: {
                            AdditionalCardCredentialRow(credential: credential)
                        }
                        .buttonStyle(.plain)
                        .appDeleteSwipeAction {
                            draft.card.additionalCredentials.removeAll { $0.id == credential.id }
                        }
                    }
                    Button { editingCredential = newCredentialInheritingMainCard() } label: {
                        Label("添加其他卡号", systemImage: "creditcard.and.123")
                    }
                } header: {
                    Text("其他卡号")
                } footer: {
                    Text("新增时自动继承主卡资料，之后可以单独修改。")
                }
                if draft.card.kind == .credit {
                    Section {
                        if sortedStatements.isEmpty {
                            Text("暂无信用卡账单").foregroundStyle(.secondary)
                        }
                        ForEach(sortedStatements) { statement in
                            Button { editingStatement = statement } label: {
                                CreditCardStatementRow(statement: statement)
                            }
                            .buttonStyle(.plain)
                            .appDeleteSwipeAction {
                                deleteStatements(ids: [statement.id])
                            }
                        }
                        Button { editingStatement = CreditCardStatement() } label: {
                            Label("添加 PDF 账单", systemImage: "doc.badge.plus")
                        }
                    } header: {
                        Text("信用卡账单")
                    } footer: {
                        Text("账单 PDF 保存在本机应用目录，并随加密 .mytools 备份导出。")
                    }
                }
                Section {
                    CurrencySelectionRows(
                        currencies: $draft.card.currencies,
                        region: account.region
                    )
                } header: {
                    Text("币种")
                } footer: {
                    if draft.card.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存").foregroundStyle(.red)
                    }
                }
                Section {
                    Text("归属银行：\(account.bankName.isEmpty ? "未命名银行" : account.bankName)")
                        .appFont(.footnote).foregroundStyle(.secondary)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave).disabled(draft.card.currencies.isEmpty)
                }
            }
            .sheet(item: $editingStatement) { statement in
                CreditCardStatementEditorView(statement: statement, onSave: upsertStatement)
                    .id(statement.id)
                    .iOSLargeSheet()
            }
            .sheet(item: $editingCredential) { credential in
                BankCardCredentialEditorView(
                    credential: credential,
                    region: account.region
                ) { updated in
                    upsertCredential(updated)
                }
                .id(credential.id)
                .iOSLargeSheet()
            }
            .sheet(isPresented: $showingBranchLocationPicker) {
                BankBranchLocationPickerView(
                    branchName: draft.card.branchName ?? "",
                    location: draft.card.branchLocation,
                    title: "开卡网点",
                    markerFallback: "开卡网点"
                ) { branch in
                    draft.card.branchLocation = branch.location
                    if !branch.name.isEmpty {
                        draft.card.branchName = branch.name
                    }
                }
                .iOSLargeSheet()
            }
            .onDisappear(perform: cleanUpUncommittedAttachments)
        }
    }

    private var sortedStatements: [CreditCardStatement] {
        draft.card.statements.sorted { lhs, rhs in
            lhs.statementDate == rhs.statementDate
                ? lhs.createdAt > rhs.createdAt
                : lhs.statementDate > rhs.statementDate
        }
    }

    private func requestSave() {
        commitPendingTextInput {
            let branchName = draft.card.branchName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if account.isOnlineBank {
                draft.card.branchName = nil
                draft.card.branchLocation = nil
            } else if account.region == .domestic {
                draft.card.branchName = branchName.isEmpty ? nil : branchName
            } else {
                draft.card.branchName = nil
                draft.card.branchLocation = nil
            }
            draft.card.expiryPrecision = .yearMonth
            didSave = true
            onSave(draft.card)
            dismiss()
        }
    }

    private var branchLocationDisplayText: String {
        guard let location = draft.card.branchLocation, location.isValid else {
            return "设置位置"
        }
        let name = draft.card.branchName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty
            ? String(format: "%.5f, %.5f", location.latitude, location.longitude)
            : name
    }

    private func toggleNetwork(_ network: CardNetwork) {
        if draft.card.networks.contains(network) {
            draft.card.networks.remove(network)
        } else {
            draft.card.networks.insert(network)
        }
    }

    private func upsertStatement(_ statement: CreditCardStatement) {
        if let index = draft.card.statements.firstIndex(where: { $0.id == statement.id }) {
            draft.card.statements[index] = statement
        } else {
            draft.card.statements.append(statement)
        }
    }

    private func upsertCredential(_ credential: BankCardCredential) {
        var credentials = draft.card.additionalCredentials
        if let index = credentials.firstIndex(where: { $0.id == credential.id }) {
            credentials[index] = credential
        } else {
            credentials.append(credential)
        }
        draft.card.additionalCredentials = credentials
        editingCredential = nil
    }

    private func newCredentialInheritingMainCard() -> BankCardCredential {
        BankCardCredential(
            networks: draft.card.networks,
            cvv: draft.card.cvv,
            expiryDate: draft.card.expiryDate,
            currencies: draft.card.currencies,
            holderName: draft.card.holderName,
            status: draft.card.status
        )
    }

    private func deleteStatements(ids: Set<UUID>) {
        for statement in draft.card.statements where ids.contains(statement.id) {
            guard let attachment = statement.attachment,
                  !originalAttachmentIDs.contains(attachment.id) else { continue }
            store.deleteUncommittedAttachment(attachment)
        }
        draft.card.statements.removeAll { ids.contains($0.id) }
    }

    private func cleanUpUncommittedAttachments() {
        guard !didSave else { return }
        for attachment in draft.card.statements.compactMap(\.attachment)
        where !originalAttachmentIDs.contains(attachment.id) {
            store.deleteUncommittedAttachment(attachment)
        }
    }
}

private struct AdditionalCardCredentialRow: View {
    let credential: BankCardCredential

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "creditcard")
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(credential.displayName)
                    .appFont(.subheadline.weight(.semibold))
                Text(credential.networks.isEmpty
                     ? "未选择卡组织"
                     : credential.networks.map(\.title).sorted().joined(separator: " · "))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(credential.cardNumber.isEmpty ? "未填写" : "•••• \(credential.cardNumber.suffix(4))")
                .appFont(.subheadline)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct BankCardCredentialEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var credential: BankCardCredential
    let region: BankRegion
    let onSave: (BankCardCredential) -> Void

    init(
        credential: BankCardCredential,
        region: BankRegion,
        onSave: @escaping (BankCardCredential) -> Void
    ) {
        _credential = State(initialValue: credential)
        self.region = region
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("卡号信息") {
                    FieldEditorRow(title: "名称：", prompt: "如银联卡号", text: $credential.name)
                    FieldEditorRow(title: "完整卡号：", prompt: "未填写", text: $credential.cardNumber)
                    DisclosureGroup {
                        ForEach(CardNetwork.allCases) { network in
                            Button { toggleNetwork(network) } label: {
                                HStack {
                                    Text(network.title).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: credential.networks.contains(network) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(credential.networks.contains(network) ? Color.accentColor : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Text("发卡组织")
                            .foregroundStyle(.secondary)
                    }
                    FieldEditorRow(title: "CVV：", prompt: "未填写", text: $credential.cvv)
                    YearMonthPicker(date: $credential.expiryDate)
                    CardStatusDisclosurePicker(status: $credential.status)
                    FieldEditorRow(title: "持卡人：", prompt: "未填写", text: $credential.holderName)
                }
                Section {
                    CurrencySelectionRows(currencies: $credential.currencies, region: region)
                } header: {
                    Text("币种")
                } footer: {
                    Text("以上资料创建时继承自主卡，可按实际情况分别修改。")
                }
            }
            .appNavigationTitle(credential.name.isEmpty ? "添加其他卡号" : "编辑其他卡号")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        credential.name = credential.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(credential)
                        dismiss()
                    }
                    .disabled(credential.cardNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func toggleNetwork(_ network: CardNetwork) {
        if credential.networks.contains(network) {
            credential.networks.remove(network)
        } else {
            credential.networks.insert(network)
        }
    }
}

private struct CardStatusDisclosurePicker: View {
    @Binding var status: CardStatus

    var body: some View {
        AppLabeledContentRow("卡片状态") {
            Menu {
                ForEach(CardStatus.allCases) { option in
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

    private func statusDot(for option: CardStatus) -> String {
        switch option {
        case .normal: "🟢"
        case .abnormal: "🟠"
        case .closed: "🔴"
        }
    }
}

struct CreditCardStatementRow: View {
    let statement: CreditCardStatement

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.red)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppDateFormatter.string(from: statement.statementDate))
                    .appFont(.subheadline.weight(.semibold))
                Text(statement.attachment?.fileName ?? "尚未选择 PDF")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !statement.note.isEmpty {
                    Text(statement.note)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let attachment = statement.attachment {
                Text(attachment.displaySize)
                    .appFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct CreditCardStatementEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var statement: CreditCardStatement
    @State private var showingFileImporter = false
    @State private var renamingAttachment: FileAttachment?
    @State private var renameText = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var didSave = false
    private let originalAttachmentID: UUID?
    let onSave: (CreditCardStatement) -> Void

    init(
        statement: CreditCardStatement,
        onSave: @escaping (CreditCardStatement) -> Void
    ) {
        _statement = State(initialValue: statement)
        originalAttachmentID = statement.attachment?.id
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账单信息") {
                    DateFieldRow(title: "账单月份：", date: $statement.statementDate)
                    if let attachment = statement.attachment {
                        LabeledContent("PDF 文件") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(attachment.fileName).lineLimit(2)
                                Text(attachment.displaySize)
                                    .appFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            beginRename(attachment)
                        } label: {
                            Label("重命名 PDF", systemImage: "pencil")
                        }
                        .tint(.blue)
                    } else {
                        Text("请选择一份 PDF 账单").foregroundStyle(.secondary)
                    }
                    Button { showingFileImporter = true } label: {
                        Label(
                            statement.attachment == nil ? "选择 PDF 文件" : "更换 PDF 文件",
                            systemImage: "folder.badge.plus"
                        )
                    }
                    .tint(statement.attachment == nil ? .accentColor : .red)
                }
                Section("备注") {
                    IMESafeMultilineTextField(prompt: "可选", text: $statement.note)
                }
            }
            .appNavigationTitle(statement.attachment == nil ? "添加信用卡账单" : "编辑信用卡账单")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(statement.attachment == nil)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false,
                onCompletion: importPDF
            )
            .onDisappear(perform: cleanUpUncommittedAttachment)
            .alert("无法添加账单", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .alert(
                "重命名附件",
                isPresented: Binding(
                    get: { renamingAttachment != nil },
                    set: { if !$0 { renamingAttachment = nil } }
                )
            ) {
                TextField("文件名", text: $renameText)
                Button("取消", role: .cancel) { renamingAttachment = nil }
                Button("保存") { renameAttachment() }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("文件格式会保持不变。")
            }
        }
    }

    private func importPDF(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let attachment = try store.importCreditCardStatement(from: url)
            if let previous = statement.attachment,
               previous.id != originalAttachmentID {
                store.deleteUncommittedAttachment(previous)
            }
            statement.attachment = attachment
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func save() {
        guard statement.attachment != nil else { return }
        didSave = true
        onSave(statement)
        dismiss()
    }

    private func beginRename(_ attachment: FileAttachment) {
        renamingAttachment = attachment
        renameText = attachment.fileName
    }

    private func renameAttachment() {
        guard let attachment = renamingAttachment,
              statement.attachment?.id == attachment.id else {
            renamingAttachment = nil
            return
        }

        do {
            statement.attachment = try store.renameAttachment(attachment, to: renameText)
            renamingAttachment = nil
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func cleanUpUncommittedAttachment() {
        guard !didSave,
              let attachment = statement.attachment,
              attachment.id != originalAttachmentID else { return }
        store.deleteUncommittedAttachment(attachment)
    }
}

private struct YearMonthPicker: View {
    @Environment(\.appFontScale) private var fontScale
    @Binding var date: Date
    private let calendar = Calendar.autoupdatingCurrent

    private var selectedYear: Int { calendar.component(.year, from: date) }
    private var selectedMonth: Int { calendar.component(.month, from: date) }
    private var years: ClosedRange<Int> {
        let currentYear = calendar.component(.year, from: Date())
        return min(currentYear - 10, selectedYear)...max(currentYear + 30, selectedYear)
    }

    var body: some View {
        AppLabeledContentRow("有效期：") {
            HStack(spacing: 4) {
                Picker("年份", selection: yearBinding) {
                    ForEach(Array(years), id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                .frame(height: AppListMetrics.minimumRowHeight(fontScale: fontScale))
                .fixedSize(horizontal: true, vertical: false)
                Text("年")
                    .fixedSize()
                Picker("月份", selection: monthBinding) {
                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                .frame(height: AppListMetrics.minimumRowHeight(fontScale: fontScale))
                .fixedSize(horizontal: true, vertical: false)
                Text("月")
                    .fixedSize()
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
    }

    private var yearBinding: Binding<Int> {
        Binding(get: { selectedYear }, set: { updateDate(year: $0, month: selectedMonth) })
    }
    private var monthBinding: Binding<Int> {
        Binding(get: { selectedMonth }, set: { updateDate(year: selectedYear, month: $0) })
    }
    private func updateDate(year: Int, month: Int) {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = 1
        if let newDate = calendar.date(from: components) { date = newDate }
    }
}

#endif
