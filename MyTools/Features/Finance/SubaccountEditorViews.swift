import SwiftUI

struct DomesticSubaccountRow: View {
    let subaccount: DomesticSubaccount

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(subaccount.type.isEmpty ? "未填写账户类型" : subaccount.type).font(.headline)
                if !subaccount.name.isEmpty {
                    Text(subaccount.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                AccountStatusText(status: subaccount.status)
            }
            if !subaccount.accountNumber.isEmpty {
                Text(subaccount.accountNumber).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(subaccount.currencySummary.isEmpty ? "未选择币种" : subaccount.currencySummary)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct DomesticSubaccountDetailRow: View {
    let subaccount: DomesticSubaccount

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !subaccount.name.isEmpty { Text(subaccount.name).font(.headline) }
            LabeledContent("账户类型", value: subaccount.type.isEmpty ? "未填写" : subaccount.type)
            if !subaccount.accountNumber.isEmpty { LabeledContent("账户号", value: subaccount.accountNumber) }
            LabeledContent("币种", value: subaccount.currencySummary.isEmpty ? "未选择" : subaccount.currencySummary)
            LabeledContent("状态") { AccountStatusText(status: subaccount.status) }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct DomesticSubaccountReadOnlyView: View {
    let subaccount: DomesticSubaccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    LabeledContent("账户类型", value: subaccount.type.isEmpty ? "未填写" : subaccount.type)
                    if !subaccount.name.isEmpty {
                        LabeledContent("备注名称", value: subaccount.name)
                    }
                    CopyableValueRow(title: "账户号", value: subaccount.accountNumber)
                    LabeledContent("币种", value: subaccount.currencySummary.isEmpty ? "未选择" : subaccount.currencySummary)
                    LabeledContent("状态") { AccountStatusText(status: subaccount.status) }
                }
            }
            .navigationTitle(subaccount.name.isEmpty ? "子账户详情" : subaccount.name)
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
    let onSave: (DomesticSubaccount) -> Void

    init(subaccount: DomesticSubaccount, onSave: @escaping (DomesticSubaccount) -> Void) {
        _draft = StateObject(wrappedValue: DomesticSubaccountDraft(subaccount: subaccount))
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.subaccount.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.currencies.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    LabeledContent("账户类型：") {
                        IMESafeTextField(prompt: "例如个人养老金", text: $draft.subaccount.type, alignment: .trailing)
                    }
                    LabeledContent("备注名称：") {
                        IMESafeTextField(prompt: "可选", text: $draft.subaccount.name, alignment: .trailing)
                    }
                    LabeledContent("账户号：") {
                        IMESafeTextField(prompt: "可选", text: $draft.subaccount.accountNumber, alignment: .trailing)
                    }
                    Picker("状态：", selection: $draft.subaccount.status) {
                        ForEach(AccountStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    CurrencySelectionRows(currencies: $draft.subaccount.currencies)
                } header: {
                    Text("币种")
                } footer: {
                    if draft.subaccount.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.subaccount.type.isEmpty ? "新增子账户" : "编辑子账户")
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
            onSave(draft.subaccount)
            dismiss()
        }
    }
}

struct ForeignSubaccountRow: View {
    let subaccount: ForeignSubaccount

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(subaccount.type.title).font(.headline)
                if !subaccount.name.isEmpty {
                    Text(subaccount.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                AccountStatusText(status: subaccount.status)
            }
            Text(subaccount.accountNumber.isEmpty ? "未填写账户号" : subaccount.accountNumber)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(subaccount.accountNumber.isEmpty ? .secondary : .primary)
            if !subaccount.currencySummary.isEmpty {
                Text(subaccount.currencySummary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct ForeignSubaccountDetailRow: View {
    let subaccount: ForeignSubaccount

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !subaccount.name.isEmpty { Text(subaccount.name).font(.headline) }
            LabeledContent("账户类型", value: subaccount.type.title)
            LabeledContent("账户号", value: subaccount.accountNumber.isEmpty ? "未填写" : subaccount.accountNumber)
            LabeledContent("币种", value: subaccount.currencySummary.isEmpty ? "未选择" : subaccount.currencySummary)
            LabeledContent("状态") { AccountStatusText(status: subaccount.status) }
        }
        .padding(.vertical, 4)
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
                    LabeledContent("账户类型", value: subaccount.type.title)
                    if !subaccount.name.isEmpty {
                        LabeledContent("备注名称", value: subaccount.name)
                    }
                    CopyableValueRow(title: "账户号", value: subaccount.accountNumber)
                    LabeledContent("币种", value: subaccount.currencySummary.isEmpty ? "未选择" : subaccount.currencySummary)
                    LabeledContent("状态") { AccountStatusText(status: subaccount.status) }
                }
            }
            .navigationTitle(subaccount.name.isEmpty ? "子账户详情" : subaccount.name)
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
        !draft.subaccount.accountNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.subaccount.currencies.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    Picker("账户类型：", selection: $draft.subaccount.type) {
                        ForEach(ForeignAccountType.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("备注名称：") {
                        IMESafeTextField(prompt: "可选", text: $draft.subaccount.name, alignment: .trailing)
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
                    CurrencySelectionRows(currencies: $draft.subaccount.currencies)
                } header: {
                    Text("币种")
                } footer: {
                    if draft.subaccount.currencies.isEmpty {
                        Text("请选择至少一个币种后再保存").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.subaccount.accountNumber.isEmpty ? "新增子账户" : "编辑子账户")
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
            onSave(draft.subaccount)
            dismiss()
        }
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

    var body: some View {
        ForEach(CurrencyCode.selectableCases(including: currencies)) { currency in
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
    }

    private func toggle(_ currency: CurrencyCode) {
        if currencies.contains(currency) { currencies.remove(currency) } else { currencies.insert(currency) }
    }
}
