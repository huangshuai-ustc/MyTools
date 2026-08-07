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
    @State private var didSave = false
    let account: BankAccount
    let onSave: (BankCard) -> Void
    private let navigationTitle: String
    private let originalAttachmentIDs: Set<UUID>

    init(card: BankCard, account: BankAccount, onSave: @escaping (BankCard) -> Void) {
        var initialCard = card
        let isNewCard = card.accountID == nil
        if isNewCard, account.region == .domestic, initialCard.currencies.isEmpty {
            initialCard.currencies = [.cny]
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
                    DisclosureGroup("发卡组织（可多选）") {
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
                    }
                    LabeledContent("卡片名称：") {
                        IMESafeTextField(prompt: "可选，如 Visa 白金卡", text: $draft.card.cardType, alignment: .trailing)
                    }
                    Picker("卡片状态：", selection: $draft.card.status) {
                        ForEach(CardStatus.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("持卡人：") {
                        IMESafeTextField(
                            prompt: account.region == .overseas ? "拼音，如 HUANG SHUAI" : "未填写",
                            text: $draft.card.holderName,
                            alignment: .trailing,
                            mode: account.region == .overseas ? .asciiUppercase : .text
                        )
                    }
                    LabeledContent("完整卡号：") {
                        IMESafeTextField(prompt: "未填写", text: $draft.card.cardNumber, alignment: .trailing)
                    }
                    LabeledContent("CVV：") {
                        IMESafeTextField(prompt: "未填写", text: $draft.card.cvv, alignment: .trailing)
                            .focused($focusedField, equals: .cvv)
                    }
                    Picker("有效期格式：", selection: $draft.card.expiryPrecision) {
                        ForEach(CardExpiryPrecision.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if draft.card.expiryPrecision == .yearMonth {
                        YearMonthPicker(date: $draft.card.expiryDate)
                    } else {
                        DatePicker("有效期：", selection: $draft.card.expiryDate, displayedComponents: .date)
                    }
                    DatePicker("开卡时间：", selection: $draft.card.openedAt, displayedComponents: .date)
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
                        }
                        .onDelete(perform: deleteStatements)
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
                    Text("归属账户：\(account.name.isEmpty ? "未命名账户" : account.name)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(navigationTitle)
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
            didSave = true
            onSave(draft.card)
            dismiss()
        }
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

    private func deleteStatements(at offsets: IndexSet) {
        let ids = Set(offsets.map { sortedStatements[$0].id })
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

struct CreditCardStatementRow: View {
    let statement: CreditCardStatement

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.red)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppDateFormatter.string(from: statement.statementDate))
                    .font(.subheadline.weight(.semibold))
                Text(statement.attachment?.fileName ?? "尚未选择 PDF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !statement.note.isEmpty {
                    Text(statement.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let attachment = statement.attachment {
                Text(attachment.displaySize)
                    .font(.caption2)
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
                    DatePicker(
                        "账单月份：",
                        selection: $statement.statementDate,
                        displayedComponents: .date
                    )
                    if let attachment = statement.attachment {
                        LabeledContent("PDF 文件") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(attachment.fileName).lineLimit(2)
                                Text(attachment.displaySize)
                                    .font(.caption)
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
            .navigationTitle(statement.attachment == nil ? "添加信用卡账单" : "编辑信用卡账单")
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
    @Binding var date: Date
    private let calendar = Calendar.autoupdatingCurrent

    private var selectedYear: Int { calendar.component(.year, from: date) }
    private var selectedMonth: Int { calendar.component(.month, from: date) }
    private var years: ClosedRange<Int> {
        let currentYear = calendar.component(.year, from: Date())
        return min(currentYear - 10, selectedYear)...max(currentYear + 30, selectedYear)
    }

    var body: some View {
        LabeledContent("有效期：") {
            HStack(spacing: 4) {
                Picker("年份", selection: yearBinding) {
                    ForEach(Array(years), id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Text("年")
                Picker("月份", selection: monthBinding) {
                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Text("月")
            }
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
