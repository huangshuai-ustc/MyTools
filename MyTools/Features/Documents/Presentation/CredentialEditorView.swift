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
    @State private var renamingAttachment: CredentialAttachment?
    @State private var ocrAttachment: CredentialAttachment?
    @State private var errorMessage: String?
    @State private var attachmentSession: AttachmentEditSession
    @State private var didFinish = false

    init(document: CredentialDocument) {
        _draft = State(initialValue: document)
        _tagsText = State(initialValue: document.tags.joined(separator: "，"))
        _attachmentSession = State(
            initialValue: AttachmentEditSession(originalAttachments: document.attachmentFiles)
        )
    }

    private var isExisting: Bool {
        store.documents.contains { $0.id == draft.id }
    }

    private var canSave: Bool {
        (draft.type != .other || !draft.customTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (draft.type != .identityCard || draft.validity.kind != .unspecified)
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
                    IMESafeTextField(prompt: "用逗号或顿号分隔", text: $tagsText)
                }
                Section("备注") {
                    IMESafeMultilineTextField(prompt: "备注", text: $draft.note)
                }
            }
            .navigationTitle(isExisting ? "编辑证照" : "新增证照")
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
            labeledField("显示名称", prompt: draft.typeTitle, text: $draft.title)
            Picker("证照状态", selection: $draft.versionStatus) {
                ForEach(CredentialVersionStatus.allCases) { status in
                    Label(status.title, systemImage: status.systemImage).tag(status)
                }
            }
            .pickerStyle(.menu)
            labeledField("持有人", prompt: "姓名或权利人", text: $draft.holderName)
            labeledField("证件号码", prompt: "可选", text: $draft.documentNumber)
            labeledField("签发机构", prompt: "可选", text: $draft.issuingAuthority)
            optionalDateRow("签发日期", date: $draft.issuedAt)
        }
    }

    private var validitySection: some View {
        Section("有效期") {
            if draft.type == .identityCard {
                Picker("身份证期限", selection: $draft.validity.kind) {
                    if draft.validity.kind == .unspecified {
                        Text("请选择期限（必填）")
                            .tag(CredentialValidityKind.unspecified)
                            .disabled(true)
                    }
                    ForEach(identityCardValidityOptions) { kind in
                        Text(
                            kind == .dateRange
                                ? "固定期限（已有记录）"
                                : kind.title
                        )
                        .tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: draft.validity.kind) { _, kind in
                    validityKindDidChange(kind)
                }
                if draft.validity.kind.durationYears != nil {
                    if let endDate = draft.expirationDate() {
                        LabeledContent("自动计算到期日", value: AppDateFormatter.string(from: endDate))
                    } else {
                        Text("设置签发日期后自动计算到期日。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if draft.validity.kind == .dateRange {
                    optionalDateRow("开始日期", date: $draft.validity.startDate)
                    expirationDatePicker
                }
            } else {
                Picker("期限", selection: $draft.validity.kind) {
                    ForEach(CredentialValidityKind.standardOptions) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.validity.kind) { _, kind in
                    validityKindDidChange(kind)
                }
                if draft.validity.kind == .dateRange || draft.validity.kind == .permanent {
                    optionalDateRow("开始日期", date: $draft.validity.startDate)
                }
                if draft.validity.kind == .dateRange {
                    expirationDatePicker
                }
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

    private var identityCardValidityOptions: [CredentialValidityKind] {
        if draft.validity.kind == .dateRange {
            return CredentialValidityKind.identityCardOptions.dropLast() + [.dateRange, .permanent]
        }
        return CredentialValidityKind.identityCardOptions
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
        Section("其他信息") {
            if draft.fields.isEmpty {
                Text("暂无其他字段")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.fields) { field in
                let binding = fieldBinding(for: field.id, fallback: field)
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("字段名称") {
                        IMESafeTextField(
                            prompt: "字段名称",
                            text: binding.label,
                            alignment: .trailing
                        )
                        .frame(maxWidth: 240)
                    }
                    Picker("输入形式", selection: binding.kind) {
                        ForEach(CredentialFieldKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    Toggle("查看时隐藏内容", isOn: binding.isSensitive)
                    if binding.wrappedValue.kind == .multiline {
                        IMESafeMultilineTextField(prompt: "字段内容", text: binding.value)
                    } else {
                        IMESafeTextField(prompt: "字段内容", text: binding.value)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { draft.fields.remove(atOffsets: $0) }
            .onMove { draft.fields.move(fromOffsets: $0, toOffset: $1) }
            Button {
                draft.fields.append(CredentialField(label: "新字段"))
            } label: {
                Label("添加字段", systemImage: "plus.circle")
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
                            Label("移除", systemImage: "trash")
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

    private func fieldBinding(for id: UUID, fallback: CredentialField) -> Binding<CredentialField> {
        Binding(
            get: { draft.fields.first(where: { $0.id == id }) ?? fallback },
            set: { value in
                guard let index = draft.fields.firstIndex(where: { $0.id == id }) else { return }
                draft.fields[index] = value
            }
        )
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
            draft.fields = newType.defaultFields
        }
        if draft.title == oldType.title {
            draft.title = newType.title
        }
        if newType == .identityCard,
           draft.validity.kind == .dateRange,
           let startDate = draft.issuedAt ?? draft.validity.startDate,
           let endDate = draft.validity.endDate,
           let term = CredentialValidityKind.identityCardTerm(from: startDate, to: endDate) {
            draft.issuedAt = startDate
            draft.validity = CredentialValidity(kind: term)
        } else if newType != .identityCard, draft.validity.kind.durationYears != nil {
            let endDate = draft.expirationDate()
            draft.validity = CredentialValidity(
                kind: .dateRange,
                startDate: draft.issuedAt,
                endDate: endDate
            )
        }
    }

    private func fieldsMatchTemplate(
        _ fields: [CredentialField],
        for type: CredentialDocumentType
    ) -> Bool {
        let template = type.defaultFields
        guard fields.count == template.count else { return false }
        return zip(fields, template).allSatisfy { field, expected in
            field.label == expected.label
                && field.value.isEmpty
                && field.kind == expected.kind
                && field.isSensitive == expected.isSensitive
        }
    }

    private func validityKindDidChange(_ kind: CredentialValidityKind) {
        switch kind {
        case .unspecified:
            draft.validity.startDate = nil
            draft.validity.endDate = nil
            draft.expiryReminder.isEnabled = false
        case .dateRange:
            draft.validity.endDate = draft.validity.endDate ?? Date()
        case .fiveYears, .tenYears, .twentyYears:
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
        if draft.type == .identityCard,
           draft.validity.kind == .unspecified {
            errorMessage = "请选择身份证有效期时长。"
            return
        }
        if draft.type == .identityCard,
           draft.validity.kind.durationYears != nil,
           draft.issuedAt == nil {
            errorMessage = "请填写签发日期，以便自动计算身份证到期日。"
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
        draft.tags = tagsText.components(separatedBy: CharacterSet(charactersIn: ",，、"))
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

#endif
