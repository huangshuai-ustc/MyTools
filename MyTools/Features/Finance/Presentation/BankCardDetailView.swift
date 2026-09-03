#if MYTOOLS_FEATURE_FINANCE
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct CardDetailView: View {
    private let initialCard: BankCard
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var sensitiveInformationRevealed = false
    @State private var showingSensitiveAccess = false
    @State private var editingCard: BankCard?
    @State private var previewAttachment: FileAttachment?
    @State private var showingAttachmentError = false
    @State private var attachmentError = ""

    init(card: BankCard) {
        initialCard = card
    }

    private var card: BankCard {
        store.cards.first { $0.id == initialCard.id } ?? initialCard
    }

    private var account: BankAccount? {
        store.accounts.first { $0.id == card.accountID }
    }

    private var canShowSensitiveInformation: Bool {
        sensitiveInformationRevealed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行卡档案") {
                    cardArchiveCard
                }

                Section("主卡号") {
                    credentialCard(
                        name: card.cardType.isEmpty ? "主卡" : card.cardType,
                        networks: card.networks,
                        cardNumber: card.cardNumber,
                        cvv: card.cvv,
                        expiryDate: card.expiryDate,
                        currencies: card.currencies,
                        holderName: card.holderName,
                        status: card.status,
                        isPrimary: true
                    )
                }

                ForEach(card.additionalCredentials) { credential in
                    Section("其他卡号") {
                        credentialCard(
                            name: credential.displayName,
                            networks: credential.networks,
                            cardNumber: credential.cardNumber,
                            cvv: credential.cvv,
                            expiryDate: credential.expiryDate,
                            currencies: credential.currencies,
                            holderName: credential.holderName,
                            status: credential.status,
                            isPrimary: false
                        )
                    }
                }

                if hasSensitiveInformation {
                    Section {
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
                    } footer: {
                        if !canShowSensitiveInformation {
                            Text("完整卡号、CVV 和有效期仅在当前详情页验证身份后显示，验证不会进入管理员编辑模式。")
                        }
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
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        editingCard = card
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("编辑银行卡")
                    .help("编辑银行卡")
                }
            }
            .sheet(item: $editingCard) { cardToEdit in
                if let account = store.accounts.first(where: { $0.id == cardToEdit.accountID }) {
                    CardEditorView(card: cardToEdit, account: account) { updated in
                        store.replaceAccount(
                            account,
                            cards: store.cards(for: account).map { $0.id == updated.id ? updated : $0 }
                        )
                    }
                    .iOSLargeSheet()
                }
            }
            .sheet(isPresented: $showingSensitiveAccess) {
                SensitiveAccessView { sensitiveInformationRevealed = true }
                    .iOSAuthenticationSheet()
            }
#if os(iOS)
            .sheet(item: $previewAttachment) { attachment in
                AttachmentPreviewSheet(
                    attachment: attachment,
                    url: store.attachmentURL(for: attachment),
                    onDismiss: { previewAttachment = nil }
                )
            }
#endif
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { sensitiveInformationRevealed = false }
            }
            .alert("无法打开账单", isPresented: $showingAttachmentError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(attachmentError)
            }
        }
    }

    private var hasSensitiveInformation: Bool {
        !card.cardNumber.isEmpty
            || !card.cvv.isEmpty
            || card.additionalCredentials.contains {
                !$0.cardNumber.isEmpty
            }
            || !card.statements.isEmpty
    }

    private var sortedStatements: [CreditCardStatement] {
        card.statements.sorted { $0.statementDate > $1.statementDate }
    }

    private var cardArchiveCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 12
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("卡片类型")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    BankCardKindBadge(kind: card.kind)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                credentialFact(
                    title: "开卡时间",
                    value: AppDateFormatter.string(from: card.openedAt),
                    copyValue: AppDateFormatter.string(from: card.openedAt)
                )
            }
            if account?.region == .domestic {
                openingBranchFact
            }
        }
        .padding(.vertical, 6)
    }

    private var openingBranchFact: some View {
        let branch = resolvedOpeningBranch
        return VStack(alignment: .leading, spacing: 4) {
            Text("开卡网点")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            if account?.isOnlineBank == true {
                Text("网络银行")
            } else {
                Menu {
                    ForEach(BankNavigationApplication.allCases) { application in
                        Button {
                            BankBranchNavigationService.open(
                                application,
                                branchName: branch.name,
                                location: branch.location
                            )
                        } label: {
                            Label(application.title, systemImage: application.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: branch.location?.isValid == true
                              ? "mappin.and.ellipse"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(branch.location?.isValid == true ? .blue : .yellow)
                        Text(branch.name.isEmpty ? "未填写" : branch.name)
                            .foregroundStyle(.blue)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .menuStyle(.borderlessButton)
                .copyableText(branch.name)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedOpeningBranch: BankBranchReference {
        guard let account else {
            return BankBranchReference(
                name: card.branchName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                location: card.branchLocation
            )
        }
        return card.resolvedOpeningBranch(for: account)
    }

    private func expiryText(date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month],
            from: date
        )
        return String(
            format: "%02d/%02d",
            components.month ?? 0,
            (components.year ?? 0) % 100
        )
    }

    private func credentialCard(
        name: String,
        networks: Set<CardNetwork>,
        cardNumber: String,
        cvv: String,
        expiryDate: Date,
        currencies: Set<CurrencyCode>,
        holderName: String,
        status: CardStatus,
        isPrimary: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .appFont(.headline)
                    .lineLimit(2)
                if isPrimary {
                    Text("主卡")
                        .appFont(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill")
                        .appFont(.caption2)
                        .foregroundStyle(statusColor(status))
                    Text(status.title)
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(status))
                }
            }

            if networks.isEmpty {
                Text("未选择发卡组织")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                CardNetworkTags(networks: networks)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("卡号")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Text(cardNumberDisplay(cardNumber))
                    .appFont(.title3.weight(.semibold))
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .copyableText(canShowSensitiveInformation && !cardNumber.isEmpty ? cardNumber : nil)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 12
            ) {
                credentialFact(
                    title: "CVV",
                    value: canShowSensitiveInformation ? (cvv.isEmpty ? "未填写" : cvv) : "•••",
                    copyValue: canShowSensitiveInformation && !cvv.isEmpty ? cvv : nil,
                    monospaced: true
                )
                credentialFact(
                    title: "有效期",
                    value: canShowSensitiveInformation ? expiryText(date: expiryDate) : "已隐藏",
                    copyValue: canShowSensitiveInformation ? expiryText(date: expiryDate) : nil,
                    monospaced: canShowSensitiveInformation
                )
            }

            credentialFact(
                title: "持卡人",
                value: holderName.isEmpty ? "未填写" : holderName,
                copyValue: holderName.isEmpty ? nil : holderName
            )
            credentialFact(
                title: "币种",
                value: currencyText(currencies),
                copyValue: currencies.isEmpty ? nil : currencyText(currencies)
            )
        }
        .padding(.vertical, 6)
    }

    private func credentialFact(
        title: String,
        value: String,
        copyValue: String?,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appFont(.subheadline)
                .fontDesign(monospaced ? .monospaced : .default)
                .fixedSize(horizontal: false, vertical: true)
                .copyableText(copyValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardNumberDisplay(_ cardNumber: String) -> String {
        guard !cardNumber.isEmpty else { return "未填写" }
        return canShowSensitiveInformation ? cardNumber : "•••• •••• •••• \(cardNumber.suffix(4))"
    }

    private func currencyText(_ currencies: Set<CurrencyCode>) -> String {
        guard !currencies.isEmpty else { return "未选择" }
        return CurrencyCode.displayOrdered(currencies).map(\.rawValue).joined(separator: " · ")
    }

    private func statusColor(_ status: CardStatus) -> Color {
        switch status {
        case .normal: .green
        case .abnormal: .orange
        case .closed: .red
        }
    }

    private func open(_ statement: CreditCardStatement) {
        guard let attachment = statement.attachment else {
            attachmentError = "这条账单没有关联 PDF 文件。"
            showingAttachmentError = true
            return
        }
        let url = store.attachmentURL(for: attachment)
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

private struct BankCardKindBadge: View {
    let kind: BankCardKind

    private var color: Color {
        kind == .debit ? .blue : .purple
    }

    var body: some View {
        Text(kind.title)
            .appFont(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .copyableText(kind.title)
    }
}

#endif
