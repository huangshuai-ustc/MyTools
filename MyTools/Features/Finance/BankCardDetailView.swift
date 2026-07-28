import SwiftUI
#if os(iOS)
import QuickLook
#elseif os(macOS)
import AppKit
#endif

struct CardDetailView: View {
    let card: BankCard
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sensitiveInformationRevealed = false
    @State private var showingSensitiveAccess = false
    @State private var previewAttachment: FileAttachment?
    @State private var showingAttachmentError = false
    @State private var attachmentError = ""

    private var canShowSensitiveInformation: Bool {
        auth.isAdmin || sensitiveInformationRevealed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CopyableValueRow(title: "卡片名称", value: card.cardType)
                    CopyableValueRow(title: "卡片类型", value: card.kind.title)
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
                    LabeledContent("发卡组织") {
                        if card.networks.isEmpty {
                            Text("未选择").foregroundStyle(.secondary)
                        } else {
                            CardNetworkTags(networks: card.networks)
                        }
                    }
                    CopyableValueRow(
                        title: "开卡时间",
                        value: card.openedAt.formatted(date: .numeric, time: .omitted)
                    )
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

                    if !auth.isAdmin, hasSensitiveInformation {
                        Button {
                            if sensitiveInformationRevealed {
                                sensitiveInformationRevealed = false
                            } else {
                                showingSensitiveAccess = true
                            }
                        } label: {
                            Label(
                                sensitiveInformationRevealed ? "隐藏敏感信息" : "验证身份后查看敏感信息",
                                systemImage: sensitiveInformationRevealed ? "lock" : "faceid"
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

                if card.kind == .credit, !card.statements.isEmpty {
                    Section("信用卡账单") {
                        if canShowSensitiveInformation {
                            ForEach(sortedStatements) { statement in
                                Button { open(statement) } label: {
                                    CreditCardStatementRow(statement: statement)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Label("账单 PDF 已隐藏", systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                            Button { showingSensitiveAccess = true } label: {
                                Label("验证身份后查看账单", systemImage: "faceid")
                            }
                        }
                    }
                }

            }
            .navigationTitle("银行卡详情")
            .adminModeIndicator()
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
                    .iOSAuthenticationSheet()
            }
#if os(iOS)
            .sheet(item: $previewAttachment) { attachment in
                NavigationStack {
                    FinanceAttachmentPreview(url: store.financeAttachmentURL(for: attachment))
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(attachment.fileName)
                        .adminModeIndicator()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { previewAttachment = nil }
                            }
                        }
                }
            }
#endif
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { sensitiveInformationRevealed = false }
            }
            .onChange(of: auth.isAdmin) { _, _ in
                sensitiveInformationRevealed = false
            }
            .alert("无法打开账单", isPresented: $showingAttachmentError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(attachmentError)
            }
        }
    }

    private var hasSensitiveInformation: Bool {
        !card.cardNumber.isEmpty || !card.cvv.isEmpty || !card.statements.isEmpty
    }

    private var sortedStatements: [CreditCardStatement] {
        card.statements.sorted { $0.statementDate > $1.statementDate }
    }

    private var maskedCardNumber: String {
        guard !card.cardNumber.isEmpty else { return "未填写" }
        return "•••• " + String(card.cardNumber.suffix(4))
    }

    private var expiryText: String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: card.expiryDate
        )
        if card.expiryPrecision == .yearMonth {
            return String(
                format: "%02d/%02d",
                components.month ?? 0,
                (components.year ?? 0) % 100
            )
        }
        return String(
            format: "%02d/%02d/%04d",
            components.month ?? 0,
            components.day ?? 0,
            components.year ?? 0
        )
    }

    private func open(_ statement: CreditCardStatement) {
        guard let attachment = statement.attachment else {
            attachmentError = "这条账单没有关联 PDF 文件。"
            showingAttachmentError = true
            return
        }
        let url = store.financeAttachmentURL(for: attachment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            attachmentError = "账单文件已不在本机，请编辑银行档案并重新添加。"
            showingAttachmentError = true
            return
        }
#if os(iOS)
        previewAttachment = attachment
#elseif os(macOS)
        NSWorkspace.shared.open(url)
#endif
    }
}

#if os(iOS)
private struct FinanceAttachmentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
