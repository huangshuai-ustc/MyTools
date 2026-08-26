#if MYTOOLS_FEATURE_DOCUMENTS
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct CredentialEditorView: View {
    @EnvironmentObject private var store: DocumentsStore
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var notifications: AppNotificationService
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CredentialDocument
    @State private var tagsText: String
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var showingCamera = false
    @State private var showingAuthentication = false
    @State private var showingFieldNameEditor = false
    @State private var showingNewFieldNameEditor = false
    @State private var showingTemplateEditor = false
    @State private var editingFieldID: UUID?
    @State private var fieldNameDraft = ""
    @State private var newFieldNameDraft = ""
    @State private var renamingAttachment: CredentialAttachment?
    @State private var ocrAttachment: CredentialAttachment?
    @State private var errorMessage: String?
    @State private var attachmentSession: AttachmentEditSession
    @State private var didFinish = false

    init(document: CredentialDocument) {
        _draft = State(initialValue: document)
        _tagsText = State(initialValue: AppTagSupport.joined(document.tags))
        _attachmentSession = State(
            initialValue: AttachmentEditSession(originalAttachments: document.attachmentFiles)
        )
    }

    private var isExisting: Bool {
        store.documents.contains { $0.id == draft.id }
    }

    private var canSave: Bool {
        (draft.type != .other || !draft.customTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && draft.issuedAt != nil
            && CredentialValidityKind.isAllowed(draft.validity.kind, for: draft.type)
            && (draft.validity.kind != .dateRange || draft.validity.endDate != nil)
            && draft.fields.allSatisfy {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                basicInformationSection
                validitySection
                customFieldsSection
                attachmentSection
                Section("标签") {
                    AppTagEditor(text: $tagsText, suggestions: store.knownTags)
                }
                Section("备注") {
                    IMESafeMultilineTextField(prompt: "备注", text: $draft.note)
                }
            }
            .appListSpacing()
            .appNavigationTitle(isExisting ? "编辑证照" : "新增证照")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave)
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: saveAfterAuthentication)
                    .iOSAuthenticationSheet()
            }
            .sheet(item: $renamingAttachment) { attachment in
                CredentialAttachmentRenameView(fileName: attachment.file.fileName) { name in
                    rename(attachment, to: name)
                }
            }
            .sheet(item: $ocrAttachment) { attachment in
                CredentialOCRView(attachment: attachment.file, documentType: draft.type) { suggestion in
                    apply(suggestion)
                }
                .iOSLargeSheet()
            }
            .sheet(isPresented: $showingTemplateEditor) {
                CredentialFieldTemplateEditorView(
                    documentType: draft.type,
                    template: store.fieldTemplate(for: draft.type)
                ) { template in
                    let previousTemplate = store.fieldTemplate(for: draft.type)
                    let shouldRefreshDraft = !isExisting
                        && fieldsMatchTemplate(draft.fields, template: previousTemplate)
                    store.upsertFieldTemplate(template)
                    if shouldRefreshDraft {
                        draft.fields = template.makeFields()
                    } else {
                        draft.fields = applyTemplateSensitivity(
                            to: draft.fields,
                            matching: template
                        )
                    }
                }
                .iOSLargeSheet()
            }
#if os(iOS)
            .sheet(isPresented: $showingCamera) {
                OCRCameraPicker(
                    onCapture: { data in
                        showingCamera = false
                        saveCapturedPhoto(data)
                    },
                    onCancel: { showingCamera = false }
                )
                .ignoresSafeArea()
            }
#endif
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image, .pdf],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
            .onChange(of: draft.expiryReminder.isEnabled) { _, isEnabled in
                guard isEnabled, !notifications.canNotify else { return }
                Task { _ = await notifications.requestAuthorization() }
            }
            .onDisappear {
                guard !didFinish else { return }
                rollbackAttachments()
            }
            .alert(
                "无法完成操作",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("编辑字段名称", isPresented: $showingFieldNameEditor) {
                TextField("字段名称", text: $fieldNameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") { saveFieldName() }
            } message: {
                Text("保存后只更新字段显示名称，不会改变字段内容。")
            }
            .alert("添加字段", isPresented: $showingNewFieldNameEditor) {
                TextField("字段名称", text: $newFieldNameDraft)
                Button("取消", role: .cancel) {}
                Button("添加") { addNewField() }
            } message: {
                Text("请输入新字段的显示名称。")
            }
        }
    }

    private var basicInformationSection: some View {
        Section("基本信息") {
            Picker("证照类型", selection: $draft.type) {
                ForEach(CredentialDocumentType.allCases) { type in
                    Label(type.title, systemImage: type.systemImage).tag(type)
                }
            }
            .onChange(of: draft.type) { oldType, newType in
                typeDidChange(from: oldType, to: newType)
            }
            if draft.type == .other {
                labeledField("类型名称", prompt: "必填", text: $draft.customTypeName)
            }
            Picker("证照状态", selection: $draft.versionStatus) {
                ForEach(CredentialVersionStatus.allCases) { status in
                    Label(status.title, systemImage: status.systemImage).tag(status)
                }
            }
            .pickerStyle(.menu)
            labeledField("持有人", prompt: "姓名或权利人", text: $draft.holderName)
            labeledField("证件号码", prompt: "可选", text: $draft.documentNumber)
            labeledField("签发机构", prompt: "可选", text: $draft.issuingAuthority)
            requiredDateRow("签发日期", date: $draft.issuedAt)
                .onChange(of: draft.issuedAt) { _, value in
                    if draft.validity.kind == .dateRange {
                        draft.validity.startDate = value
                    }
                }
        }
    }

    private var validitySection: some View {
        Section("有效期") {
            Picker("期限", selection: $draft.validity.kind) {
                if draft.validity.kind == .unspecified {
                    Text("请选择期限（必填）")
                        .tag(CredentialValidityKind.unspecified)
                        .disabled(true)
                }
                ForEach(validityOptions) { kind in
                    Text(kind == .dateRange ? "固定期限（已有记录）" : kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draft.validity.kind) { _, kind in
                validityKindDidChange(kind)
            }
            if draft.validity.kind.durationYears != nil {
                if let endDate = draft.expirationDate() {
                    LabeledContent("自动计算到期日", value: AppDateFormatter.string(from: endDate))
                    Text(CredentialValidityKind.endDateRule(for: draft.type).title)
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("到期日将从签发日期自动计算。")
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if draft.validity.kind == .dateRange {
                LabeledContent("有效期起始", value: issuedDateText)
                expirationDatePicker
            } else if draft.validity.kind == .permanent {
                LabeledContent("生效日期", value: issuedDateText)
            }

            if draft.expirationDate() != nil {
                Toggle("到期提醒", isOn: $draft.expiryReminder.isEnabled)
                if draft.expiryReminder.isEnabled {
                    Picker("提醒时间", selection: $draft.expiryReminder.daysBefore) {
                        ForEach(CredentialExpiryReminder.dayOptions, id: \.self) { days in
                            Text(days == 0 ? "到期当天" : "提前 \(days) 天").tag(days)
                        }
                    }
                }
            }
        }
    }

    private var validityOptions: [CredentialValidityKind] {
        var options = CredentialValidityKind.options(for: draft.type)
        if draft.validity.kind == .dateRange && !options.contains(.dateRange) {
            options.insert(.dateRange, at: 0)
        }
        return options
    }

    private var issuedDateText: String {
        draft.issuedAt.map { AppDateFormatter.string(from: $0) } ?? "请先填写签发日期"
    }

    private var expirationDatePicker: some View {
        DatePicker(
            "到期日期",
            selection: Binding(
                get: { draft.validity.endDate ?? Date() },
                set: { draft.validity.endDate = $0 }
            ),
            displayedComponents: .date
        )
    }

    private var customFieldsSection: some View {
        return Section {
            if draft.fields.isEmpty {
                Text("暂无其他字段")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.fields) { field in
                let binding = fieldBinding(for: field.id, fallback: field)
                credentialFieldEditorRow(field: binding)
                    .modifier(CredentialFieldSwipeActionsModifier(
                        field: binding,
                        onRename: { beginFieldNameEdit(field) }
                    ))
                    .appDeleteSwipeAction {
                        draft.fields.removeAll { $0.id == field.id }
                    }
            }
            .onMove { draft.fields.move(fromOffsets: $0, toOffset: $1) }
            Button {
                newFieldNameDraft = ""
                showingNewFieldNameEditor = true
            } label: {
                Label("添加字段", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text("其他信息")
                Spacer()
                Button("字段模板") { showingTemplateEditor = true }
                    .appFont(.subheadline)
                    .foregroundStyle(.blue)
                    .underline()
            }
        }
    }

    private var attachmentSection: some View {
        Section("附件") {
            if draft.attachments.isEmpty {
                Text("暂无附件")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.attachments) { attachment in
                let binding = attachmentBinding(for: attachment.id, fallback: attachment)
                VStack(alignment: .leading, spacing: 8) {
                    CredentialAttachmentRow(
                        attachment: binding.wrappedValue,
                        url: store.attachmentURL(for: binding.wrappedValue.file)
                    )
                    Picker("页面类型", selection: binding.role) {
                        ForEach(CredentialAttachmentRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    HStack(spacing: 18) {
                        Button {
                            ocrAttachment = binding.wrappedValue
                        } label: {
                            Label("识别信息", systemImage: "text.viewfinder")
                        }
                        Button {
                            renamingAttachment = binding.wrappedValue
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            remove(binding.wrappedValue)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }

            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 20, matching: .images) {
                Label("从照片添加", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("从文件添加图片或 PDF", systemImage: "folder.badge.plus")
            }
#if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingCamera = true
                } label: {
                    Label("拍摄证照", systemImage: "camera")
                }
            }
#endif
        }
    }

    private func labeledField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            IMESafeTextField(prompt: prompt, text: text, alignment: .trailing)
                .frame(maxWidth: 260)
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight)
    }

    private func optionalDateRow(_ title: String, date: Binding<Date?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                title,
                isOn: Binding(
                    get: { date.wrappedValue != nil },
                    set: { date.wrappedValue = $0 ? (date.wrappedValue ?? Date()) : nil }
                )
            )
            if date.wrappedValue != nil {
                DatePicker(
                    title,
                    selection: Binding(
                        get: { date.wrappedValue ?? Date() },
                        set: { date.wrappedValue = $0 }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
            }
        }
    }

    private func requiredDateRow(_ title: String, date: Binding<Date?>) -> some View {
        LabeledContent(title) {
            DatePicker(
                "",
                selection: Binding(
                    get: { date.wrappedValue ?? Date() },
                    set: { date.wrappedValue = $0 }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight)
    }

    private func fieldBinding(for id: UUID, fallback: CredentialField) -> Binding<CredentialField> {
        Binding(
            get: { draft.fields.first(where: { $0.id == id }) ?? fallback },
            set: { value in
                guard let index = draft.fields.firstIndex(where: { $0.id == id }) else { return }
                draft.fields[index] = value
            }
        )
    }

    @ViewBuilder
    private func credentialFieldEditorRow(field: Binding<CredentialField>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(field.wrappedValue.label.isEmpty ? "未命名字段" : field.wrappedValue.label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            switch field.wrappedValue.inputType {
            case .date:
                DatePicker(
                    "",
                    selection: dateBinding(for: field),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .text, .url:
                if field.wrappedValue.isMultiline {
                    IMESafeMultilineTextField(
                        prompt: "请在此处键入\(field.wrappedValue.label)",
                        text: field.value,
                        minHeight: 34,
                        maxHeight: 180
                    )
                } else {
                    IMESafeTextField(
                        prompt: "请在此处键入\(field.wrappedValue.label)",
                        text: field.value,
                        alignment: .leading,
                        mode: field.wrappedValue.inputType == .url ? .url : .text
                    )
                }
            }
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight, alignment: .center)
        .onChange(of: field.wrappedValue.value) { _, value in
            guard field.wrappedValue.inputType != .date else { return }
            field.wrappedValue.kind = value.contains(where: { $0.isNewline }) ? .multiline : .text
        }
    }

    private func dateBinding(for field: Binding<CredentialField>) -> Binding<Date> {
        Binding(
            get: { Self.dateFormatter.date(from: field.wrappedValue.value) ?? Date() },
            set: { field.wrappedValue.value = Self.dateFormatter.string(from: $0) }
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func beginFieldNameEdit(_ field: CredentialField) {
        editingFieldID = field.id
        fieldNameDraft = field.label
        showingFieldNameEditor = true
    }

    private func saveFieldName() {
        guard let editingFieldID else { return }
        let label = fieldNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              let index = draft.fields.firstIndex(where: { $0.id == editingFieldID }) else {
            return
        }
        draft.fields[index].label = label
        self.editingFieldID = nil
    }

    private func addNewField() {
        let label = newFieldNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        draft.fields.append(CredentialField(label: label, kind: .text, inputType: .text))
    }

    private func fieldsMatchTemplate(
        _ fields: [CredentialField],
        template: CredentialFieldTemplate
    ) -> Bool {
        let normalizedFields = fields
            .filter { $0.value.isEmpty }
            .map { "\($0.label)|\($0.isMultiline)|\($0.inputType.rawValue)|\($0.isSensitive)" }
            .sorted()
        let normalizedTemplate = template.fields
            .map { "\($0.label)|\($0.isMultiline)|\($0.inputType.rawValue)|\($0.isSensitive)" }
            .sorted()
        return fields.count == template.fields.count && normalizedFields == normalizedTemplate
    }

    private func fieldsMatchTemplate(
        _ fields: [CredentialField],
        for type: CredentialDocumentType
    ) -> Bool {
        fieldsMatchTemplate(
            fields,
            template: store.fieldTemplate(for: type)
        )
    }

    private func applyTemplateSensitivity(
        to fields: [CredentialField],
        matching template: CredentialFieldTemplate
    ) -> [CredentialField] {
        fields.map { field in
            guard let templateField = template.fields.first(where: {
                $0.label == field.label && $0.inputType == field.inputType
            }) else {
                return field
            }
            var updated = field
            updated.isSensitive = templateField.isSensitive
            return updated
        }
    }

    private func attachmentBinding(
        for id: UUID,
        fallback: CredentialAttachment
    ) -> Binding<CredentialAttachment> {
        Binding(
            get: { draft.attachments.first(where: { $0.id == id }) ?? fallback },
            set: { value in
                guard let index = draft.attachments.firstIndex(where: { $0.id == id }) else { return }
                draft.attachments[index] = value
            }
        )
    }

    private func typeDidChange(from oldType: CredentialDocumentType, to newType: CredentialDocumentType) {
        if fieldsMatchTemplate(draft.fields, for: oldType) {
            draft.fields = store.makeFields(for: newType)
        }
        let previousEndDate = draft.expirationDate()
        if CredentialValidityKind.isAlwaysPermanent(for: newType) {
            draft.validity = CredentialValidity(kind: .permanent)
        } else if !CredentialValidityKind.options(for: newType).contains(draft.validity.kind) {
            if let previousEndDate {
                draft.validity = CredentialValidity(
                    kind: .dateRange,
                    startDate: draft.issuedAt,
                    endDate: previousEndDate
                )
            } else {
                draft.validity = CredentialValidity(
                    kind: CredentialValidityKind.options(for: newType).first ?? .permanent
                )
            }
        }
    }

    private func validityKindDidChange(_ kind: CredentialValidityKind) {
        switch kind {
        case .unspecified:
            draft.validity.startDate = nil
            draft.validity.endDate = nil
            draft.expiryReminder.isEnabled = false
        case .dateRange:
            draft.validity.startDate = draft.issuedAt
        case .fiveYears, .sixYears, .tenYears, .twentyYears:
            draft.validity.startDate = nil
            draft.validity.endDate = nil
            if draft.issuedAt == nil {
                draft.expiryReminder.isEnabled = false
            }
        case .permanent:
            draft.validity.startDate = nil
            draft.validity.endDate = nil
            draft.expiryReminder.isEnabled = false
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                let file = try store.importAttachment(from: url)
                let role: CredentialAttachmentRole = file.contentType.conforms(to: .pdf) ? .scan : .other
                draft.attachments.append(CredentialAttachment(file: file, role: role))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentStoreError.invalidFile
                }
                let contentType = item.supportedContentTypes.first ?? .jpeg
                let suffix = contentType.preferredFilenameExtension ?? "jpg"
                let name = "证照照片-\(UUID().uuidString.prefix(8)).\(suffix)"
                let file = try store.savePhoto(data: data, fileName: name, contentType: contentType)
                draft.attachments.append(CredentialAttachment(file: file))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveCapturedPhoto(_ data: Data) {
        do {
            let name = "证照拍摄-\(UUID().uuidString.prefix(8)).jpg"
            let file = try store.savePhoto(data: data, fileName: name, contentType: .jpeg)
            let attachment = CredentialAttachment(file: file)
            draft.attachments.append(attachment)
            ocrAttachment = attachment
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ attachment: CredentialAttachment) {
        draft.attachments.removeAll { $0.id == attachment.id }
        if !attachmentSession.isOriginal(attachment.file) {
            store.deleteUncommittedAttachment(attachment.file)
        }
    }

    private func rename(_ attachment: CredentialAttachment, to name: String) {
        do {
            let renamed = try store.renameAttachment(attachment.file, to: name)
            guard let index = draft.attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
            draft.attachments[index].file = renamed
            attachmentSession.trackRename(renamed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ suggestion: CredentialOCRSuggestion) {
        draft.applyOCRSuggestion(suggestion)
    }

    private func requestSave() {
        commitPendingTextInput { validateAndRequestSave() }
    }

    private func validateAndRequestSave() {
        if draft.type == .other,
           draft.customTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "请填写自定义证照类型。"
            return
        }
        if draft.validity.kind == .dateRange {
            guard let endDate = draft.validity.endDate else {
                errorMessage = "请填写到期日期。"
                return
            }
            if let startDate = draft.validity.startDate, startDate > endDate {
                errorMessage = "有效期开始日期不能晚于到期日期。"
                return
            }
        }
        if draft.issuedAt == nil {
            errorMessage = "请填写签发日期。"
            return
        }
        if draft.validity.kind == .dateRange,
           let startDate = draft.validity.startDate,
           let issuedAt = draft.issuedAt,
           Calendar.autoupdatingCurrent.startOfDay(for: startDate)
                != Calendar.autoupdatingCurrent.startOfDay(for: issuedAt) {
            errorMessage = "有效期起始日期必须与签发日期一致。"
            return
        }
        if !CredentialValidityKind.isAllowed(draft.validity.kind, for: draft.type) {
            errorMessage = "请选择适用于该证照类型的期限。"
            return
        }
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
        draft.tags = AppTagSupport.parse(tagsText)
        store.upsert(draft)
        attachmentSession.commit()
        didFinish = true
        dismiss()
    }

    private func cancel() {
        rollbackAttachments()
        didFinish = true
        dismiss()
    }

    private func rollbackAttachments() {
        let failures = attachmentSession.rollback(
            currentAttachments: draft.attachmentFiles,
            delete: store.deleteUncommittedAttachment,
            restoreLocation: store.restoreAttachmentLocation
        )
        if !failures.isEmpty {
            DiagnosticLogger.shared.log(
                .persistence,
                "取消证照编辑时，附件回滚失败：\(failures.joined(separator: "；"))",
                level: .error
            )
        }
    }
}

private struct CredentialFieldSwipeActionsModifier: ViewModifier {
    let field: Binding<CredentialField>
    let onRename: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        content.appSwipeActions(edge: .leading, style: AppSwipeActions.secondary) {
            Button {
                field.wrappedValue.isSensitive.toggle()
            } label: {
                Label(
                    field.wrappedValue.isSensitive ? "显示内容" : "隐藏内容",
                    systemImage: field.wrappedValue.isSensitive ? "eye" : "eye.slash"
                )
            }
            .tint(AppSwipeActions.visibility.tint)
            Button(action: onRename) {
                Label("编辑名称", systemImage: "pencil")
            }
            .tint(AppSwipeActions.edit.tint)
        }
    }
}

#endif
