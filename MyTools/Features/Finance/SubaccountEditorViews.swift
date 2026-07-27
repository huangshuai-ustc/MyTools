import SwiftUI

struct DomesticSubaccountRow: View {
    let subaccount: DomesticSubaccount

    var body: some View {
        SubaccountSummaryRow(
            name: subaccount.name,
            accountType: subaccount.type,
            accountNumber: subaccount.accountNumber,
            status: subaccount.status
        )
    }
}

struct DomesticSubaccountDetailRow: View {
    let subaccount: DomesticSubaccount

    var body: some View {
        DomesticSubaccountRow(subaccount: subaccount)
    }
}

struct DomesticSubaccountReadOnlyView: View {
    let subaccount: DomesticSubaccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    CopyableValueRow(title: "账户名称", value: subaccount.name)
                    LabeledContent("账户类型", value: subaccount.type.isEmpty ? "未填写" : subaccount.type)
                    CopyableValueRow(title: "账户号", value: subaccount.accountNumber)
                    LabeledContent("状态") { AccountStatusText(status: subaccount.status) }
                    LabeledContent("币种", value: subaccount.currencySummary.isEmpty ? "未选择" : subaccount.currencySummary)
                }
            }
            .navigationTitle(subaccount.name.isEmpty ? "子账户详情" : subaccount.name)
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private final class DomesticSubaccountDraft: ObservableObject {
    @Published var subaccount: DomesticSubaccount
    init(subaccount: DomesticSubaccount) { self.subaccount = subaccount }
}

struct DomesticSubaccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: DomesticSubaccountDraft
    @State private var selectedType: DomesticAccountType
    let onSave: (DomesticSubaccount) -> Void

    init(subaccount: DomesticSubaccount, onSave: @escaping (DomesticSubaccount) -> Void) {
        let selection = DomesticAccountType.selection(for: subaccount.type)
        var preparedSubaccount = subaccount
        if preparedSubaccount.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preparedSubaccount.type = selection.title
        }
        _draft = StateObject(wrappedValue: DomesticSubaccountDraft(subaccount: preparedSubaccount))
        _selectedType = State(initialValue: selection)
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.subaccount.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.accountNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.currencies.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    LabeledContent("账户名称：") {
                        IMESafeTextField(prompt: "例如退休金账户", text: $draft.subaccount.name, alignment: .trailing)
                    }
                    Picker("账户类型：", selection: $selectedType) {
                        ForEach(DomesticAccountType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    if selectedType == .other {
                        LabeledContent("自定义类型：") {
                            IMESafeTextField(prompt: "例如私人理财账户", text: $draft.subaccount.type, alignment: .trailing)
                        }
                    }
                    LabeledContent("账户号：") {
                        IMESafeTextField(prompt: "未填写", text: $draft.subaccount.accountNumber, alignment: .trailing)
                    }
                    Picker("状态：", selection: $draft.subaccount.status) {
                        ForEach(AccountStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    CurrencySelectionRows(currencies: $draft.subaccount.currencies, region: .domestic)
                } header: {
                    Text("币种")
                } footer: {
                    if draft.subaccount.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(
                draft.subaccount.name.isEmpty && draft.subaccount.accountNumber.isEmpty
                    ? "新增子账户"
                    : "编辑子账户"
            )
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave).disabled(!canSave)
                }
            }
            .onChange(of: selectedType) { _, type in
                if type == .other {
                    let matchesPreset = DomesticAccountType.allCases.contains {
                        $0 != .other && $0.title == draft.subaccount.type
                    }
                    if matchesPreset { draft.subaccount.type = "" }
                } else {
                    draft.subaccount.type = type.title
                }
            }
        }
    }

    private func requestSave() {
        commitPendingTextInput {
            onSave(draft.subaccount)
            dismiss()
        }
    }
}

struct ForeignSubaccountRow: View {
    let subaccount: ForeignSubaccount

    var body: some View {
        SubaccountSummaryRow(
            name: subaccount.name,
            accountType: subaccount.typeTitle,
            accountNumber: subaccount.accountNumber,
            status: subaccount.status
        )
    }
}

struct ForeignSubaccountDetailRow: View {
    let subaccount: ForeignSubaccount

    var body: some View {
        ForeignSubaccountRow(subaccount: subaccount)
    }
}

private struct SubaccountSummaryRow: View {
    let name: String
    let accountType: String
    let accountNumber: String
    let status: AccountStatus

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name.isEmpty ? "未命名子账户" : name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AccountStatusText(status: status)
            }
            Text(accountType.isEmpty ? "未填写账户类型" : accountType)
                .font(.subheadline)
                .foregroundStyle(accountType.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
            Text(accountNumber.isEmpty ? "未填写账户号" : accountNumber)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(accountNumber.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ForeignSubaccountReadOnlyView: View {
    let subaccount: ForeignSubaccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    CopyableValueRow(title: "账户名称", value: subaccount.name)
                    LabeledContent("账户类型", value: subaccount.typeTitle)
                    CopyableValueRow(title: "账户号", value: subaccount.accountNumber)
                    LabeledContent("状态") { AccountStatusText(status: subaccount.status) }
                    LabeledContent("币种", value: subaccount.currencySummary.isEmpty ? "未选择" : subaccount.currencySummary)
                }
            }
            .navigationTitle(subaccount.name.isEmpty ? "子账户详情" : subaccount.name)
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private final class ForeignSubaccountDraft: ObservableObject {
    @Published var subaccount: ForeignSubaccount
    init(subaccount: ForeignSubaccount) { self.subaccount = subaccount }
}

struct ForeignSubaccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: ForeignSubaccountDraft
    let onSave: (ForeignSubaccount) -> Void

    init(subaccount: ForeignSubaccount, onSave: @escaping (ForeignSubaccount) -> Void) {
        _draft = StateObject(wrappedValue: ForeignSubaccountDraft(subaccount: subaccount))
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.subaccount.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.accountNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.currencies.isEmpty
            && (draft.subaccount.type != .other
                || !(draft.subaccount.customType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    LabeledContent("账户名称：") {
                        IMESafeTextField(prompt: "例如港币储蓄", text: $draft.subaccount.name, alignment: .trailing)
                    }
                    Picker("账户类型：", selection: $draft.subaccount.type) {
                        ForEach(ForeignAccountType.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.subaccount.type == .other {
                        LabeledContent("自定义类型：") {
                            IMESafeTextField(prompt: "例如贵金属账户", text: customType, alignment: .trailing)
                        }
                    }
                    LabeledContent("账户号：") {
                        IMESafeTextField(prompt: "未填写", text: $draft.subaccount.accountNumber, alignment: .trailing)
                    }
                    Picker("状态：", selection: $draft.subaccount.status) {
                        ForEach(AccountStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    CurrencySelectionRows(currencies: $draft.subaccount.currencies, region: .overseas)
                } header: {
                    Text("币种")
                } footer: {
                    if draft.subaccount.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.subaccount.accountNumber.isEmpty ? "新增子账户" : "编辑子账户")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave).disabled(!canSave)
                }
            }
        }
    }

    private func requestSave() {
        commitPendingTextInput {
            if draft.subaccount.type != .other {
                draft.subaccount.customType = nil
            }
            onSave(draft.subaccount)
            dismiss()
        }
    }

    private var customType: Binding<String> {
        Binding(
            get: { draft.subaccount.customType ?? "" },
            set: { draft.subaccount.customType = $0 }
        )
    }
}

struct AccountStatusText: View {
    let status: AccountStatus

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

struct CurrencySelectionRows: View {
    @Binding var currencies: Set<CurrencyCode>
    var region: BankRegion = .overseas

    private var primaryCurrencies: [CurrencyCode] {
        CurrencyCode.preferredFinanceCases(for: region)
    }

    private var additionalCurrencies: [CurrencyCode] {
        CurrencyCode.additionalFinanceCases(for: region, including: currencies)
    }

    var body: some View {
        Group {
            ForEach(primaryCurrencies) { currency in
                currencyRow(currency)
            }
            if !additionalCurrencies.isEmpty {
                DisclosureGroup("更多币种") {
                    ForEach(additionalCurrencies) { currency in
                        currencyRow(currency)
                    }
                }
            }
        }
    }

    private func currencyRow(_ currency: CurrencyCode) -> some View {
        Button { toggle(currency) } label: {
            HStack {
                Text(currency.title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: currencies.contains(currency) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(currencies.contains(currency) ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currency.title)
        .accessibilityValue(currencies.contains(currency) ? "已选择" : "未选择")
    }

    private func toggle(_ currency: CurrencyCode) {
        if currencies.contains(currency) { currencies.remove(currency) } else { currencies.insert(currency) }
    }
}
