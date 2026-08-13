#if MYTOOLS_FEATURE_BILLS
import SwiftUI

struct BillEditorView: View {
    @EnvironmentObject private var store: BillsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BillRecord
    @State private var amountText: String
    @State private var tagsText: String
    @State private var secondsText: String
    @State private var showingAuthentication = false
    @State private var errorMessage: String?

    init(record: BillRecord) {
        _draft = State(initialValue: record)
        _amountText = State(
            initialValue: record.amount == 0 ? "" : NSDecimalNumber(decimal: record.amount).stringValue
        )
        _tagsText = State(initialValue: record.tags.joined(separator: "，"))
        _secondsText = State(initialValue: String(Calendar.autoupdatingCurrent.component(.second, from: record.occurredAt)))
    }

    private var isExisting: Bool {
        store.records.contains { $0.id == draft.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("交易") {
                    Picker("收支类型", selection: $draft.direction) {
                        ForEach(BillDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("金额") {
                        TextField("必填", text: $amountText)
                            .multilineTextAlignment(.trailing)
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                    }
                    Picker("币种", selection: $draft.currency) {
                        ForEach(CurrencyCode.selectableCases) { currency in
                            Text(currency.title).tag(currency)
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent("交易时间") {
                        HStack(spacing: 6) {
                            DatePicker("", selection: $draft.occurredAt, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                            Text(":")
                                .foregroundStyle(.secondary)
                            TextField("00", text: $secondsText)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 38)
#if os(iOS)
                                .keyboardType(.numberPad)
#endif
                        }
                    }
                    Picker("状态", selection: $draft.status) {
                        ForEach(BillTransactionStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("分类", selection: $draft.category) {
                        ForEach(BillCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("明细") {
                    safeField("商户", prompt: "可选", text: $draft.merchant)
                    safeField("交易对方", prompt: "可选", text: $draft.counterparty)
                    safeField("商品说明", prompt: "可选", text: $draft.itemDescription)
                    safeField("支付方式", prompt: "如微信支付或银行卡", text: $draft.paymentMethod)
                    safeField("付款账户", prompt: "如尾号 1234", text: $draft.accountHint)
                }

                Section("标签") {
                    IMESafeTextField(prompt: "用逗号或顿号分隔", text: $tagsText)
                }
                Section("备注") {
                    IMESafeMultilineTextField(prompt: "备注", text: $draft.note)
                }
            }
            .navigationTitle(isExisting ? "编辑账单" : "新增账单")
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
                    Button("保存", action: requestSave)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: saveAfterAuthentication)
                    .iOSAuthenticationSheet()
            }
            .alert(
                "无法保存",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func safeField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            IMESafeTextField(prompt: prompt, text: text, alignment: .trailing)
        }
    }

    private func requestSave() {
        commitPendingTextInput { validateAndRequestSave() }
    }

    private func validateAndRequestSave() {
        guard let amount = DecimalTextParser.expression(from: amountText), amount > 0 else {
            errorMessage = "请输入大于 0 的有效金额。"
            return
        }
        draft.amount = amount
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        save()
    }

    private func saveAfterAuthentication() {
        showingAuthentication = false
        save()
    }

    private func save() {
        applySeconds()
        draft.tags = tagsText.components(separatedBy: CharacterSet(charactersIn: ",，、"))
        store.upsert(draft)
        dismiss()
    }

    private func applySeconds() {
        guard let seconds = Int(secondsText.trimmingCharacters(in: .whitespacesAndNewlines)), (0...59).contains(seconds) else {
            return
        }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: draft.occurredAt)
        var updated = components
        updated.second = seconds
        if let date = calendar.date(from: updated) {
            draft.occurredAt = date
        }
    }
}

#endif
