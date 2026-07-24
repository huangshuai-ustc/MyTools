import SwiftUI

struct CardDetailView: View {
    let card: BankCard
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sensitiveInformationRevealed = false
    @State private var showingSensitiveAccess = false

    private var canShowSensitiveInformation: Bool {
        auth.isAdmin || sensitiveInformationRevealed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    CopyableValueRow(title: "银行", value: card.bankName)
                    CopyableValueRow(title: "支行", value: card.branchName)
                    CopyableValueRow(title: "卡片类型", value: card.kind.title)
                    CopyableValueRow(title: "卡片名称", value: card.cardType)
                    LabeledContent("发卡组织") {
                        if card.networks.isEmpty {
                            Text("未选择").foregroundStyle(.secondary)
                        } else {
                            CardNetworkTags(networks: card.networks)
                        }
                    }
                    LabeledContent("状态") {
                        CardStatusText(status: card.status)
                            .copyableText(card.status.title)
                    }
                    CopyableValueRow(
                        title: "币种",
                        value: card.currencySummary,
                        emptyValue: "未选择"
                    )
                    CopyableValueRow(title: "持卡人", value: card.holderName)
                    CopyableValueRow(title: "Apple Pay", value: card.applePay ? "已添加" : "未添加")
                    CopyableValueRow(title: "默认支付", value: card.defaultPayment ? "是" : "否")
                }

                Section {
                    ProtectedValueRow(
                        title: "卡号",
                        value: card.cardNumber,
                        concealedValue: maskedCardNumber,
                        isRevealed: canShowSensitiveInformation
                    )
                    ProtectedValueRow(
                        title: "CVV",
                        value: card.cvv,
                        concealedValue: "•••",
                        isRevealed: canShowSensitiveInformation
                    )
                    LabeledContent("有效期") {
                        Text(canShowSensitiveInformation ? expiryText : "已隐藏")
                            .fontDesign(canShowSensitiveInformation ? .monospaced : .default)
                            .copyableText(canShowSensitiveInformation ? expiryText : nil)
                    }
                    CopyableValueRow(
                        title: "开户时间",
                        value: card.openedAt.formatted(date: .numeric, time: .omitted)
                    )

                    if !auth.isAdmin, hasSensitiveInformation {
                        Button { showingSensitiveAccess = true } label: {
                            Label(
                                sensitiveInformationRevealed ? "重新验证身份" : "验证身份后查看敏感信息",
                                systemImage: sensitiveInformationRevealed ? "lock.open" : "faceid"
                            )
                        }
                    }
                } header: {
                    Text("卡片信息")
                } footer: {
                    if !canShowSensitiveInformation, hasSensitiveInformation {
                        Text("完整卡号、CVV 和有效期仅在当前详情页验证身份后显示，验证不会进入管理员编辑模式。")
                    }
                }

                if !card.note.isEmpty {
                    Section("备注") {
                        Text(card.note)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(card.bankName.isEmpty ? "银行卡详情" : card.bankName)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingSensitiveAccess) {
                SensitiveAccessView { sensitiveInformationRevealed = true }
                    .iOSLargeSheet()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { sensitiveInformationRevealed = false }
            }
        }
    }

    private var hasSensitiveInformation: Bool {
        !card.cardNumber.isEmpty || !card.cvv.isEmpty
    }

    private var maskedCardNumber: String {
        guard !card.cardNumber.isEmpty else { return "未填写" }
        return "•••• " + String(card.cardNumber.suffix(4))
    }

    private var expiryText: String {
        guard card.expiryPrecision == .yearMonth else {
            return card.expiryDate.formatted(date: .numeric, time: .omitted)
        }
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: card.expiryDate)
        return String(format: "%04d年%02d月", components.year ?? 0, components.month ?? 0)
    }
}
