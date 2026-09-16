#if MYTOOLS_FEATURE_PARTNERSHIP
import SwiftUI

enum PartnershipAction: String, CaseIterable, Identifiable {
    case proportional, contribution, withdrawal, settlement, valuation, member, rename
    var id: Self { self }
    var title: String {
        switch self {
        case .proportional: "按当前比例注资"
        case .contribution: "单人注资"
        case .withdrawal: "个人取出"
        case .settlement: "记录盈亏"
        case .valuation: "更新净值"
        case .member: "新成员加入"
        case .rename: "修改账本名称"
        }
    }
    var entryKind: PartnershipEntryKind {
        switch self {
        case .withdrawal: .withdrawal
        case .settlement: .settlement
        case .valuation: .valuation
        default: .contribution
        }
    }
}

struct PartnershipCreateView: View {
    @EnvironmentObject private var store: PartnershipStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "合伙股票账户"
    @State private var manager = "我"
    @State private var partner = "合伙人"
    @State private var managerAmount = "9000"
    @State private var partnerAmount = "1500"
    @State private var rate = "5"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账本") {
                    FieldEditorRow(title: "名称", prompt: "账本名称", text: $name)
                    Text("记账币种：人民币")
                }
                Section("初始出资") {
                    FieldEditorRow(title: "管理方", prompt: "姓名", text: $manager)
                    NumericFieldRow(title: "管理方出资", prompt: "9000", text: $managerAmount)
                    FieldEditorRow(title: "合伙人", prompt: "姓名", text: $partner)
                    NumericFieldRow(title: "合伙人出资", prompt: "1500", text: $partnerAmount)
                }
                Section("规则") {
                    NumericFieldRow(title: "抽成 / 补偿（%）", prompt: "5", text: $rate)
                    Text("同一比例用于利润抽成和亏损补偿，每次结算固定分配结果。").foregroundStyle(.secondary)
                }
            }
            .appNavigationTitle("新建合伙账本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commitPendingTextInput { save() } }
                }
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("确定", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
    private func save() {
        do {
            guard let first = DecimalTextParser.decimal(from: managerAmount),
                  let second = DecimalTextParser.decimal(from: partnerAmount),
                  let percent = DecimalTextParser.decimal(from: rate) else {
                throw PartnershipError.invalid("请输入有效的金额和调整比例。")
            }
            try store.create(name: name, manager: manager, partner: partner, amounts: [first, second], rate: percent / 100)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct PartnershipActionView: View {
    @EnvironmentObject private var store: PartnershipStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let action: PartnershipAction
    @State private var amount = ""
    @State private var name = ""
    @State private var note = ""
    @State private var memberID: UUID?
    @State private var error: String?
    private var book: PartnershipBook? { store.books.first { $0.id == bookID } }

    var body: some View {
        NavigationStack {
            Form {
                if let book {
                    Section {
                        if action == .member || action == .rename {
                            FieldEditorRow(title: action == .member ? "姓名" : "名称", prompt: "必填", text: $name)
                        }
                        if action == .withdrawal || action == .contribution {
                            PickerFieldRow(title: "成员", selection: $memberID) {
                                ForEach(book.members) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        if action != .rename {
NumericFieldRow(title: action == .settlement ? "盈亏（亏损填负数）" : "金额", prompt: "0.00", text: $amount, allowsExpression: action == .settlement)
                            FieldEditorRow(title: "备注", prompt: "选填", text: $note)
                        }
                    }
                    if (action == .proportional || action == .settlement),
                       let value = DecimalTextParser.decimal(from: amount),
                       PartnershipCalculator.validAmount(value, allowNegative: action == .settlement),
                       let preview = try? PartnershipCalculator.split(value, book: book, adjusted: action == .settlement) {
                        Section("分配预览") {
                            ForEach(preview, id: \.memberID) { allocation in
                                LabeledContent(book.members.first { $0.id == allocation.memberID }?.name ?? "成员",
                                               value: PartnershipFormat.money(allocation.actual, currency: book.currency))
                            }
                        }
                    }
                    Section {
                        Text("资金变更前请先更新并结算净值。取出不能超过个人权益；已结算的历史分配不会因后续比例变化而重算。")
                            .appFont(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .appNavigationTitle(action.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commitPendingTextInput { save() } }.disabled(book == nil)
                }
            }
            .onAppear {
                memberID = book?.members.first?.id
                if action == .rename { name = book?.name ?? "" }
                if action == .settlement, let book {
                    let pending = PartnershipCalculator.summary(book).pendingProfit
                    if pending != 0 { amount = NSDecimalNumber(decimal: pending).stringValue }
                }
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("确定", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
    private func save() {
        do {
            if action == .rename {
                try store.rename(id: bookID, name: name)
            } else {
                guard let value = DecimalTextParser.decimal(from: amount) else { throw PartnershipError.invalid("请输入有效金额。") }
                if action == .member {
                    try store.addMember(bookID: bookID, name: name, amount: value)
                } else {
                    try store.record(bookID: bookID, kind: action.entryKind, amount: value, memberID: memberID,
                                     proportional: action == .proportional, note: note)
                }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
#endif
