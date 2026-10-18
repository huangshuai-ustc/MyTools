#if MYTOOLS_FEATURE_DOCUMENTS
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct CredentialDetailView: View {
    @EnvironmentObject private var store: DocumentsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appFontScale) private var fontScale
    let documentID: UUID
    @Binding var isUnlocked: Bool
    @State private var hiddenFieldIDs: Set<UUID> = []
    @State private var editingDocument: CredentialDocument?
    @State private var previewAttachment: FileAttachment?
    @State private var attachmentError: String?
    @State private var deletingVersion: CredentialDocument?

    private var document: CredentialDocument? {
        store.documents.first { $0.id == documentID }
    }

    private var canReveal: Bool { isUnlocked }

    private func openEditor(_ document: CredentialDocument) {
        Task {
            guard await SensitiveEditAccess.isGranted(
                isUnlocked: isUnlocked,
                verify: { await auth.verifyWithBiometrics(reason: "验证本人身份后编辑证照") }
            ) else { return }
            isUnlocked = true
            editingDocument = document
        }
    }

    private var versionGroup: [CredentialDocument] {
        guard let document else { return [] }
        return store.versionGroup(for: document)
    }

    private var otherVersions: [CredentialDocument] {
        versionGroup.filter { $0.id != documentID }
    }

    var body: some View {
        Group {
            if let document {
                Form {
                    Section {
                        credentialHero(document)
                            .appListRowStyle()
                    }
                    Section("证照信息") {
                        AppAdaptiveRecordRow(title: "类型", value: document.typeTitle)
                            .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
                        detailRow("证照状态") {
                            CredentialVersionStatusLabel(status: document.versionStatus)
                        }
                        protectedRow("持有人", value: document.holderName, isRevealed: canReveal)
                        protectedRow(
                            "证件号码",
                            value: document.documentNumber,
                            isRevealed: canReveal,
                            monospaced: true
                        )
                        protectedRow(
                            "签发机构",
                            value: document.issuingAuthority,
                            isRevealed: canReveal
                        )
                        if let date = document.issuedAt {
                            protectedRow(
                                "签发日期",
                                value: AppDateFormatter.string(from: date),
                                isRevealed: canReveal
                            )
                        }
                    }

                    Section("有效期") {
                        AppAdaptiveRecordRow(title: "期限", value: document.validity.kind.title)
                        detailRow("有效状态") {
                            CredentialStatusLabel(status: document.validityStatus())
                        }
                        if let date = document.issuedAt ?? document.validity.startDate {
                            protectedRow(
                                "有效期起始",
                                value: AppDateFormatter.string(from: date),
                                isRevealed: canReveal
                            )
                        }
                        if let date = document.expirationDate() {
                            protectedRow(
                                "到期日期",
                                value: AppDateFormatter.string(from: date),
                                isRevealed: canReveal
                            )
                        }
                        if document.validity.kind.durationYears != nil {
                            Text(CredentialValidityKind.endDateRule(for: document.type).title)
                                .appFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if document.expiryReminder.isEnabled {
                            AppAdaptiveRecordRow(
                                title: "到期提醒",
                                value: reminderTitle(document.expiryReminder.daysBefore)
                            )
                        }
                    }

                    let filledFields = document.fields.filter {
                        !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if !filledFields.isEmpty {
                        Section("其他信息") {
                            ForEach(filledFields) { field in
                                fieldRow(field)
                            }
                        }
                    }

                    if !document.tags.isEmpty {
                        Section("标签") {
                            AppTagCapsules(tags: document.tags)
                        }
                    }

                    if !document.note.isEmpty {
                        Section("备注") {
                            Text(canReveal ? document.note : "••••••")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .copyableText(canReveal ? document.note : nil)
                        }
                    }

                    if !document.attachments.isEmpty {
                        Section("附件") {
                            if canReveal {
                                ForEach(document.attachments) { attachment in
                                    Button {
                                        open(attachment.file)
                                    } label: {
                                        CredentialAttachmentRow(
                                            attachment: attachment,
                                            url: store.attachmentURL(for: attachment.file),
                                            showsDisclosure: true
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Label("附件已隐藏", systemImage: "lock.fill")
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task { if await auth.verifyWithBiometrics() { isUnlocked = true } }
                                } label: {
                                    Label("验证身份后查看附件", systemImage: "faceid")
                                }
                            }
                        }
                    }

                    if versionGroup.count > 1 {
                        Section("其他版本") {
                            ForEach(otherVersions) { version in
                                NavigationLink {
                                    CredentialDetailView(
                                        documentID: version.id,
                                        isUnlocked: $isUnlocked
                                    )
                                } label: {
                                    CredentialVersionRow(document: version, isRevealed: canReveal)
                                }
                                .appListRowStyle()
                                .appDeleteSwipeAction(isEnabled: version.isVersion) {
                                    deletingVersion = version
                                }
                            }
                        }
                    }
                }
                .appNavigationTitle(document.displayTitle(revealsHolder: canReveal))
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            openEditor(document)
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("编辑证照")
                    }
                }
            } else {
                ContentUnavailableView("证照不存在", systemImage: "doc.badge.xmark")
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(item: $editingDocument) { document in
            CredentialEditorView(document: document)
                .id(document.id)
                .iOSLargeSheet()
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
            if phase != .active {
                isUnlocked = false
                hiddenFieldIDs = []
            }
        }
        .alert(
            "删除此版本？",
            isPresented: Binding(get: { deletingVersion != nil }, set: { if !$0 { deletingVersion = nil } })
        ) {
            Button("取消", role: .cancel) { deletingVersion = nil }
            Button("删除", role: .destructive) {
                if let deletingVersion { store.delete(ids: [deletingVersion.id]) }
                deletingVersion = nil
            }
        } message: {
            Text("将同时删除该版本的附件和到期提醒，无法撤销。")
        }
        .alert(
            "无法打开附件",
            isPresented: Binding(
                get: { attachmentError != nil },
                set: { if !$0 { attachmentError = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private func credentialHero(_ document: CredentialDocument) -> some View {
        let status = document.validityStatus()
        return HStack(spacing: 14) {
            Image(systemName: document.type.systemImage)
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 54, height: 54)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(document.typeTitle).font(.headline)
                Text(document.versionStatus.title).font(.caption).foregroundStyle(.secondary)
                CredentialStatusLabel(status: status)
            }
            Spacer()
            Button {
                if canReveal {
                    isUnlocked = false
                    hiddenFieldIDs = []
                } else {
                    Task { if await auth.verifyWithBiometrics() { isUnlocked = true } }
                }
            } label: {
                Image(systemName: canReveal ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(canReveal ? "锁定证照私密信息" : "解锁查看证照私密信息")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func detailRow<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        AppLabeledContentRow(title) { content() }
    }

    private func protectedRow(
        _ title: String,
        value: String,
        isRevealed: Bool,
        monospaced: Bool = false
    ) -> some View {
        AppAdaptiveRecordRow(
            title: title,
            value: value.isEmpty ? "未填写" : (isRevealed ? value : "••••••"),
            valueFont: monospaced && isRevealed ? .subheadline.monospaced() : .subheadline,
            allowsCopy: isRevealed && !value.isEmpty
        )
    }

    @ViewBuilder
    private func fieldRow(_ field: CredentialField) -> some View {
        let revealed = !field.isSensitive || (canReveal && !hiddenFieldIDs.contains(field.id))
        let title = field.label.isEmpty ? "未命名字段" : field.label
        if revealed, field.inputType == .url,
           let url = URL(string: field.value.trimmingCharacters(in: .whitespacesAndNewlines)),
           !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppLabeledContentRow(title) {
                Link(destination: url) {
                    Text(field.value)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.blue)
                        .underline()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .copyableText(field.value)
                fieldVisibilityButton(field, revealed: revealed)
            }
        } else {
            AppAdaptiveRecordRowWithAccessory(
                title: title,
                value: field.value.isEmpty ? "未填写" : (revealed ? field.value : "••••••"),
                allowsCopy: revealed && !field.value.isEmpty
            ) {
                fieldVisibilityButton(field, revealed: revealed)
            }
        }
    }

    @ViewBuilder
    private func fieldVisibilityButton(_ field: CredentialField, revealed: Bool) -> some View {
        if field.isSensitive, !field.value.isEmpty, canReveal {
            Button {
                if hiddenFieldIDs.contains(field.id) { hiddenFieldIDs.remove(field.id) }
                else { hiddenFieldIDs.insert(field.id) }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "隐藏内容" : "显示内容")
        }
    }

    private func reminderTitle(_ days: Int) -> String {
        days == 0 ? "到期当天" : "提前 \(days) 天"
    }

    private func open(_ attachment: FileAttachment) {
        let url = store.attachmentURL(for: attachment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            attachmentError = "附件已不在本机，请进入编辑页面重新添加。"
            return
        }
#if os(iOS)
        previewAttachment = attachment
#elseif os(macOS)
        NSWorkspace.shared.open(url)
#endif
    }
}

private struct CredentialVersionRow: View {
    let document: CredentialDocument
    let isRevealed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(document.displayTitle(revealsHolder: isRevealed))
                    .appFont(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                CredentialVersionStatusLabel(status: document.versionStatus)
                    .layoutPriority(1)
            }
            HStack(spacing: 8) {
                Text(issueDateTitle)
                    .lineLimit(1)
                Spacer(minLength: 8)
                CredentialStatusLabel(status: document.validityStatus())
                    .layoutPriority(1)
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var issueDateTitle: String {
        guard let issuedAt = document.issuedAt else { return "未设置签发日期" }
        return "签发于 \(isRevealed ? AppDateFormatter.string(from: issuedAt) : "••••••")"
    }
}

#endif
