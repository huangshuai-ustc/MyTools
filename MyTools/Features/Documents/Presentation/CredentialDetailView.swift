#if MYTOOLS_FEATURE_DOCUMENTS
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct CredentialDetailView: View {
    @EnvironmentObject private var store: DocumentsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    let documentID: UUID
    @Binding var isUnlocked: Bool
    @State private var showingSensitiveAccess = false
    @State private var editingDocument: CredentialDocument?
    @State private var previewAttachment: FileAttachment?
    @State private var attachmentError: String?

    private var document: CredentialDocument? {
        store.documents.first { $0.id == documentID }
    }

    private var canReveal: Bool { auth.isAdmin || isUnlocked }

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
                    Section("证照信息") {
                        LabeledContent("类型", value: document.typeTitle)
                        HStack(spacing: 12) {
                            Text("证照状态")
                            Spacer(minLength: 12)
                            CredentialVersionStatusLabel(status: document.versionStatus)
                        }
                        .frame(maxWidth: .infinity)
                        protectedRow("持有人", value: document.holderName)
                        protectedRow("证件号码", value: document.documentNumber, monospaced: true)
                        protectedRow("签发机构", value: document.issuingAuthority)
                        if let date = document.issuedAt {
                            protectedRow("签发日期", value: AppDateFormatter.string(from: date))
                        }
                    }

                    Section("有效期") {
                        LabeledContent("期限", value: document.validity.kind.title)
                        HStack(spacing: 12) {
                            Text("有效状态")
                            Spacer(minLength: 12)
                            CredentialStatusLabel(status: document.validityStatus())
                        }
                        .frame(maxWidth: .infinity)
                        if let date = document.issuedAt ?? document.validity.startDate {
                            protectedRow("有效期起始", value: AppDateFormatter.string(from: date))
                        }
                        if let date = document.expirationDate() {
                            protectedRow("到期日期", value: AppDateFormatter.string(from: date))
                        }
                        if document.validity.kind.durationYears != nil {
                            Text(CredentialValidityKind.endDateRule(for: document.type).title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if document.expiryReminder.isEnabled {
                            LabeledContent("到期提醒", value: reminderTitle(document.expiryReminder.daysBefore))
                        }
                    }

                    if !document.fields.isEmpty {
                        Section("其他信息") {
                            ForEach(document.fields) { field in
                                fieldRow(field)
                            }
                        }
                    }

                    if !document.tags.isEmpty {
                        Section("标签") {
                            Text(document.tags.joined(separator: "、"))
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
                                    showingSensitiveAccess = true
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
                                    CredentialVersionRow(document: version)
                                }
                                .appListRowStyle()
                                .swipeActions {
                                    if auth.isAdmin, version.isVersion {
                                        Button(role: .destructive) {
                                            store.delete(ids: [version.id])
                                        } label: {
                                            Label("删除版本", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(document.displayTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !canReveal {
                            Button {
                                showingSensitiveAccess = true
                            } label: {
                                Image(systemName: "faceid")
                            }
                            .accessibilityLabel("验证身份后查看证照信息")
                        }
                        AdminEditAccessButton()
                        if auth.isAdmin {
                            Button {
                                editingDocument = CredentialDocument(versionOf: document)
                            } label: {
                                Image(systemName: "doc.badge.plus")
                            }
                            .accessibilityLabel("添加证照新版本")
                            Button {
                                editingDocument = document
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .accessibilityLabel("编辑证照")
                        }
                    }
                }
            } else {
                ContentUnavailableView("证照不存在", systemImage: "doc.badge.xmark")
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $showingSensitiveAccess) {
            SensitiveAccessView { isUnlocked = true }
                .iOSAuthenticationSheet()
        }
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
        .onChange(of: auth.isAdmin) { _, isAdmin in
            isUnlocked = isAdmin
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isUnlocked = false }
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

    @ViewBuilder
    private func protectedRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "未填写" : (canReveal ? value : "••••••"))
                .fontDesign(monospaced && canReveal ? .monospaced : .default)
                .multilineTextAlignment(.trailing)
                .copyableText(canReveal && !value.isEmpty ? value : nil)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: CredentialField) -> some View {
        let revealed = canReveal || !field.isSensitive
        VStack(alignment: .leading, spacing: 5) {
            Text(field.label)
                .font(.subheadline.weight(.medium))
            Text(field.value.isEmpty ? "未填写" : (revealed ? field.value : "••••••"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(field.kind == .multiline ? 8 : 2)
                .copyableText(revealed && !field.value.isEmpty ? field.value : nil)
        }
        .padding(.vertical, 3)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(document.displayTitle)
                    .font(.subheadline.weight(.medium))
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var issueDateTitle: String {
        guard let issuedAt = document.issuedAt else { return "未设置签发日期" }
        return "签发于 \(AppDateFormatter.string(from: issuedAt))"
    }
}

#endif
