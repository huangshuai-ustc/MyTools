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
                        DetailValueRow(title: "类型", value: document.typeTitle)
                            .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
                        detailRow("证照状态") {
                            CredentialVersionStatusLabel(status: document.versionStatus)
                        }
                        DetailValueRow.protected("持有人", value: document.holderName, isRevealed: canReveal)
                        DetailValueRow.protected(
                            "证件号码",
                            value: document.documentNumber,
                            isRevealed: canReveal,
                            monospaced: true,
                            truncationMode: .middle
                        )
                        DetailValueRow.protected(
                            "签发机构",
                            value: document.issuingAuthority,
                            isRevealed: canReveal,
                            truncationMode: .middle
                        )
                        if let date = document.issuedAt {
                            DetailValueRow.protected(
                                "签发日期",
                                value: AppDateFormatter.string(from: date),
                                isRevealed: canReveal
                            )
                        }
                    }

                    Section("有效期") {
                        DetailValueRow(title: "期限", value: document.validity.kind.title)
                        HStack(spacing: 12) {
                            Text("有效状态")
                            Spacer(minLength: 12)
                            CredentialStatusLabel(status: document.validityStatus())
                        }
                        .frame(maxWidth: .infinity)
                        if let date = document.issuedAt ?? document.validity.startDate {
                            DetailValueRow.protected(
                                "有效期起始",
                                value: AppDateFormatter.string(from: date),
                                isRevealed: canReveal
                            )
                        }
                        if let date = document.expirationDate() {
                            DetailValueRow.protected(
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
                            DetailValueRow(
                                title: "到期提醒",
                                value: reminderTitle(document.expiryReminder.daysBefore)
                            )
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
                                .appDeleteSwipeAction(isEnabled: auth.isAdmin && version.isVersion) {
                                    store.delete(ids: [version.id])
                                }
                            }
                        }
                    }
                }
                .appNavigationTitle(document.displayTitle)
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
            if isAdmin { hiddenFieldIDs = [] }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isUnlocked = false
                hiddenFieldIDs = []
            }
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
    private func detailRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale), alignment: .center)
    }

    @ViewBuilder
    private func fieldRow(_ field: CredentialField) -> some View {
        let revealed = !field.isSensitive || (canReveal && !hiddenFieldIDs.contains(field.id))
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(field.label.isEmpty ? "未命名字段" : field.label)
                    .appFont(.subheadline.weight(.medium))
                Spacer()
                if field.isSensitive, !field.value.isEmpty, canReveal {
                    Button {
                        if hiddenFieldIDs.contains(field.id) {
                            hiddenFieldIDs.remove(field.id)
                        } else {
                            hiddenFieldIDs.insert(field.id)
                        }
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(revealed ? "隐藏内容" : "显示内容")
                }
            }
            if revealed,
               field.inputType == .url,
               let url = URL(string: field.value.trimmingCharacters(in: .whitespacesAndNewlines)),
               !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Link(destination: url) {
                    Text(field.value)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.blue)
                        .underline()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                .copyableText(field.value)
            } else {
                Text(field.value.isEmpty ? "未填写" : (revealed ? field.value : "••••••"))
                    .fontDesign(revealed ? .monospaced : .default)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(field.isMultiline ? 8 : 2)
                    .copyableText(revealed && !field.value.isEmpty ? field.value : nil)
            }
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
        return "签发于 \(AppDateFormatter.string(from: issuedAt))"
    }
}

struct CredentialFieldTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var fontScale
    let documentType: CredentialDocumentType
    @State private var fields: [CredentialField]
    @State private var showingNewField = false
    @State private var newFieldName = ""
    @State private var draggedFieldID: UUID?
    @State private var editingFieldID: UUID?
    @State private var fieldNameDraft = ""
    let onSave: (CredentialFieldTemplate) -> Void

    init(
        documentType: CredentialDocumentType,
        template: CredentialFieldTemplate,
        onSave: @escaping (CredentialFieldTemplate) -> Void
    ) {
        self.documentType = documentType
        _fields = State(initialValue: template.fields)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($fields) { field in
                        HStack(spacing: 12) {
                            TextField("字段名称", text: field.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Picker("字段类型", selection: field.inputType) {
                                ForEach(CredentialFieldInputType.allCases) { inputType in
                                    Text(inputType.title).tag(inputType)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .frame(height: AppListMetrics.minimumRowHeight(fontScale: fontScale))
                        }
                        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale), alignment: .center)
                        .appListRowStyle()
                        .onDrag {
                            draggedFieldID = field.wrappedValue.id
                            return NSItemProvider(object: NSString(string: field.wrappedValue.id.uuidString))
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TemplateFieldDropDelegate(
                                targetID: field.wrappedValue.id,
                                draggedID: $draggedFieldID,
                                move: moveField
                            )
                        )
                        .appTemplateFieldSwipeActions(
                            isSensitive: field.wrappedValue.isSensitive
                        ) {
                            field.wrappedValue.isSensitive.toggle()
                        } onRename: {
                            editingFieldID = field.wrappedValue.id
                            fieldNameDraft = field.wrappedValue.label
                        }
                        .appDeleteSwipeAction {
                            fields.removeAll { $0.id == field.wrappedValue.id }
                        }
                    }
                    Button {
                        newFieldName = ""
                        showingNewField = true
                    } label: {
                        Label("添加模板字段", systemImage: "plus.circle")
                    }
                } header: {
                    Text("字段模板 · \(documentType.title)")
                } footer: {
                    Text("模板只保存字段定义；右滑可显示/隐藏内容或编辑名称，左滑可删除，长按可拖动调整顺序；新建证照时会生成空白字段。")
                }
            }
            .appNavigationTitle("字段模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let cleaned = fields.filter {
                            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }.map {
                            CredentialField(
                                label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                kind: $0.kind,
                                inputType: $0.inputType,
                                isSensitive: $0.isSensitive
                            )
                        }
                        onSave(CredentialFieldTemplate(documentType: documentType, fields: cleaned))
                        dismiss()
                    }
                    .disabled(fields.allSatisfy {
                        $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
                }
            }
            .alert("添加模板字段", isPresented: $showingNewField) {
                TextField("字段名称", text: $newFieldName)
                Button("取消", role: .cancel) {}
                Button("添加") {
                    let label = newFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return }
                    fields.append(CredentialField(label: label, isSensitive: true))
                }
            }
            .alert(
                "编辑字段名称",
                isPresented: Binding(
                    get: { editingFieldID != nil },
                    set: { if !$0 { editingFieldID = nil } }
                )
            ) {
                TextField("字段名称", text: $fieldNameDraft)
                Button("取消", role: .cancel) { editingFieldID = nil }
                Button("保存") { saveFieldName() }
            } message: {
                Text("请输入字段的显示名称。")
            }
        }
    }

    private func moveField(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let sourceIndex = fields.firstIndex(where: { $0.id == draggedID }) else {
            return
        }
        let movedField = fields.remove(at: sourceIndex)
        let insertionIndex = fields.firstIndex(where: { $0.id == targetID }) ?? fields.count
        fields.insert(movedField, at: insertionIndex)
    }

    private func saveFieldName() {
        guard let editingFieldID else { return }
        let label = fieldNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              let index = fields.firstIndex(where: { $0.id == editingFieldID }) else {
            return
        }
        fields[index].label = label
        self.editingFieldID = nil
    }
}

#endif
