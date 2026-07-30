import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private enum SecretCategoryFilter: Hashable, Identifiable {
    case all
    case category(SecretCategory)

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case let .category(category): return category.title
        }
    }

    func includes(_ item: SecretItem) -> Bool {
        switch self {
        case .all: return true
        case let .category(category): return item.category == category
        }
    }
}

private final class SecretEditorDraft: ObservableObject {
    @Published var item: SecretItem

    init(item: SecretItem) {
        self.item = item
    }
}

struct SecretVaultView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var categoryFilter: SecretCategoryFilter = .all
    @State private var isUnlocked = false
    @State private var showingSensitiveAccess = false
    @State private var editingItem: SecretItem?
    @State private var isCreating = false

    private var canAccess: Bool {
        auth.isAdmin || isUnlocked
    }

    private var visibleItems: [SecretItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.secretItems
            .filter(categoryFilter.includes)
            .filter { item in
                term.isEmpty
                    || item.title.localizedCaseInsensitiveContains(term)
                    || item.category.title.localizedCaseInsensitiveContains(term)
                    || item.tags.localizedCaseInsensitiveContains(term)
                    || item.fields.contains { $0.label.localizedCaseInsensitiveContains(term) }
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var body: some View {
        List {
            Section {
                Picker("分类", selection: $categoryFilter) {
                    Text(SecretCategoryFilter.all.title).tag(SecretCategoryFilter.all)
                    ForEach(SecretCategory.allCases) { category in
                        Text(category.title).tag(SecretCategoryFilter.category(category))
                    }
                }
                .pickerStyle(.menu)
            }

            Section("保密条目") {
                if visibleItems.isEmpty {
                    ContentUnavailableView(
                        store.secretItems.isEmpty ? "暂无保密资料" : "没有匹配的条目",
                        systemImage: store.secretItems.isEmpty ? "lock.shield" : "magnifyingglass"
                    )
                }
                ForEach(visibleItems) { item in
                    NavigationLink {
                        SecretDetailView(itemID: item.id, isUnlocked: $isUnlocked)
                    } label: {
                        SecretItemRow(item: item)
                    }
                    .appListRowStyle()
                }
                .onDelete {
                    guard auth.isAdmin else { return }
                    let ids = Set($0.map { visibleItems[$0].id })
                    store.deleteSecrets(ids: ids)
                }
            }
        }
        .navigationTitle(ToolModule.secrets.title)
        .iOSLabeledBackButton("工具箱")
        .searchable(text: $query, prompt: "搜索名称、分类或字段名称")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !canAccess {
                    Button {
                        showingSensitiveAccess = true
                    } label: {
                        Image(systemName: "faceid")
                    }
                    .accessibilityLabel("验证身份后查看保密资料")
                }
                AdminEditAccessButton()
                if canAccess, auth.isAdmin {
                    Button {
                        isCreating = true
                        editingItem = SecretItem()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加保密条目")
                }
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
#endif
        .sheet(isPresented: $showingSensitiveAccess) {
            SensitiveAccessView { isUnlocked = true }
                .iOSAuthenticationSheet()
        }
        .sheet(item: $editingItem) { item in
            SecretEditorView(item: item, isNew: isCreating)
                .id(item.id)
                .iOSLargeSheet()
        }
        .onChange(of: auth.isAdmin) { _, isAdmin in
            if isAdmin {
                isUnlocked = true
            } else {
                isUnlocked = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isUnlocked = false
            }
        }
        .onChange(of: editingItem) { _, item in
            if item == nil { isCreating = false }
        }
    }

}

private struct SecretItemRow: View {
    let item: SecretItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text(item.title.isEmpty ? "未命名条目" : item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.category.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SecretAttachmentRow: View {
    let attachment: FileAttachment
    let showsDisclosure: Bool

    init(attachment: FileAttachment, showsDisclosure: Bool = false) {
        self.attachment = attachment
        self.showsDisclosure = showsDisclosure
    }

    private var systemImage: String {
        attachment.contentType.conforms(to: .pdf) ? "doc.richtext" : "photo"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.pink)
                .frame(width: 40, height: 40)
                .background(.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(attachment.contentType.conforms(to: .pdf) ? "PDF" : "图片") · \(attachment.displaySize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsDisclosure {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

struct SecretDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    let itemID: UUID
    @Binding var isUnlocked: Bool
    @State private var hiddenFieldIDs: Set<UUID> = []
    @State private var showingSensitiveAccess = false
    @State private var editingItem: SecretItem?
    @State private var previewAttachment: FileAttachment?
    @State private var showingAttachmentError = false
    @State private var attachmentError = ""

    private var canRevealSensitiveFields: Bool {
        auth.isAdmin || isUnlocked
    }

    private var item: SecretItem? {
        store.secretItems.first { $0.id == itemID }
    }

    var body: some View {
        Group {
            if let item {
                Form {
                    Section {
                        LabeledContent("分类", value: item.category.title)
                        if !item.tags.isEmpty {
                            LabeledContent(
                                "标签",
                                value: canRevealSensitiveFields ? item.tags : "••••••"
                            )
                        }
                    }

                    Section("保密字段") {
                        ForEach(item.fields) { field in
                            SecretFieldValueRow(
                                field: field,
                                hiddenFieldIDs: $hiddenFieldIDs,
                                canRevealSensitiveFields: canRevealSensitiveFields
                            )
                        }
                    }

                    if !item.note.isEmpty {
                        Section("备注") {
                            Text(canRevealSensitiveFields ? item.note : "••••••")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(SecretTextSelectionModifier(isEnabled: canRevealSensitiveFields))
                                .copyableText(canRevealSensitiveFields ? item.note : nil)
                        }
                    }

                    if !item.attachments.isEmpty {
                        Section("附件") {
                            if canRevealSensitiveFields {
                                ForEach(item.attachments) { attachment in
                                    Button {
                                        openAttachment(attachment)
                                    } label: {
                                        SecretAttachmentRow(attachment: attachment, showsDisclosure: true)
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
                }
                .navigationTitle(item.title.isEmpty ? "保密资料" : item.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !canRevealSensitiveFields {
                            Button {
                                showingSensitiveAccess = true
                            } label: {
                                Image(systemName: "faceid")
                            }
                            .accessibilityLabel("验证身份后查看保密内容")
                        }
                        AdminEditAccessButton()
                        if auth.isAdmin {
                            Button {
                                editingItem = item
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("编辑保密条目")
                        }
                    }
                }
            } else {
                ContentUnavailableView("条目不存在", systemImage: "lock.slash")
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $showingSensitiveAccess) {
            SensitiveAccessView {
                isUnlocked = true
                hiddenFieldIDs = []
            }
            .iOSAuthenticationSheet()
        }
        .sheet(item: $editingItem) { item in
            SecretEditorView(item: item, isNew: false)
                .id(item.id)
                .iOSLargeSheet()
        }
#if os(iOS)
        .sheet(item: $previewAttachment) { attachment in
            NavigationStack {
                AttachmentPreview(url: store.secretAttachmentURL(for: attachment))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(attachment.fileName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { previewAttachment = nil } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("关闭预览")
                        }
                    }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .interactiveDismissDisabled(false)
            .iOSLargeSheet()
        }
#endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hiddenFieldIDs = [] }
        }
        .onChange(of: auth.isAdmin) { _, isAdmin in
            if isAdmin {
                isUnlocked = true
                hiddenFieldIDs = []
            } else {
                isUnlocked = false
                hiddenFieldIDs = []
            }
        }
        .alert("无法打开附件", isPresented: $showingAttachmentError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(attachmentError)
        }
    }

    private func openAttachment(_ attachment: FileAttachment) {
        let url = store.secretAttachmentURL(for: attachment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            attachmentError = "附件已不在本机，请进入编辑页面重新添加。"
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

private struct SecretFieldValueRow: View {
    let field: SecretField
    @Binding var hiddenFieldIDs: Set<UUID>
    let canRevealSensitiveFields: Bool

    private var isRevealed: Bool {
        canRevealSensitiveFields && (!field.isSensitive || !hiddenFieldIDs.contains(field.id))
    }

    private var displayValue: String {
        guard !field.value.isEmpty else { return "未填写" }
        return isRevealed ? field.value : "••••••"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label.isEmpty ? "未命名字段" : field.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if field.isSensitive, !field.value.isEmpty, canRevealSensitiveFields {
                    Button {
                        toggleReveal()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isRevealed ? "隐藏字段" : "显示字段")
                }
            }
            Text(displayValue)
                .fontDesign(isRevealed ? .monospaced : .default)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(field.kind.isMultiline ? 8 : 2)
                .copyableText(isRevealed ? field.value : nil)
        }
        .padding(.vertical, 4)
    }

    private func toggleReveal() {
        if hiddenFieldIDs.contains(field.id) {
            hiddenFieldIDs.remove(field.id)
        } else {
            hiddenFieldIDs.insert(field.id)
        }
    }
}

private struct SecretTextSelectionModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

struct SecretEditorView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: SecretEditorDraft
#if os(iOS)
    @State private var fieldEditMode: EditMode = .inactive
#endif
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var showingAuthentication = false
    @State private var renamingAttachment: FileAttachment?
    @State private var renameText = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var didSave = false
    private let originalAttachmentIDs: Set<UUID>
    let isNew: Bool

    init(item: SecretItem, isNew: Bool) {
        _draft = StateObject(wrappedValue: SecretEditorDraft(item: item))
        originalAttachmentIDs = Set(item.attachments.map(\.id))
        self.isNew = isNew
    }

    private var canSave: Bool {
        !draft.item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.item.fields.allSatisfy {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("条目信息") {
                    LabeledContent("名称：") {
                        IMESafeTextField(prompt: "例如 Cloudflare", text: $draft.item.title, alignment: .trailing)
                    }
                    Picker("分类：", selection: $draft.item.category) {
                        ForEach(SecretCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(category)
                        }
                    }
                    .onChange(of: draft.item.category) { oldCategory, newCategory in
                        guard isNew, fieldsMatchDefault(draft.item.fields, for: oldCategory) else { return }
                        draft.item.fields = newCategory.defaultFields
                    }
                    LabeledContent("标签：") {
                        IMESafeTextField(prompt: "可选，用逗号分隔", text: $draft.item.tags, alignment: .trailing)
                    }
                }

                Section("字段") {
                    ForEach(draft.item.fields) { field in
                        let fieldBinding = binding(for: field.id, fallback: field)
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("字段名称：") {
                                IMESafeTextField(
                                    prompt: "例如授权姓名",
                                    text: fieldBinding.label,
                                    alignment: .trailing
                                )
                            }
                            Picker("输入形式：", selection: inputStyleBinding(for: fieldBinding)) {
                                Text("单行文本").tag(SecretFieldKind.text)
                                Text("多行文本").tag(SecretFieldKind.multiline)
                            }
                            Toggle("查看时隐藏内容", isOn: fieldBinding.isSensitive)
                            fieldValueEditor(field: fieldBinding)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        draft.item.fields.remove(atOffsets: offsets)
                    }
                    .onMove { source, destination in
                        draft.item.fields.move(fromOffsets: source, toOffset: destination)
                    }
                    Button {
                        draft.item.fields.append(SecretField(label: "新字段", kind: .text))
                    } label: {
                        Label("添加字段", systemImage: "plus.circle")
                    }
                }

                attachmentSection

                Section("备注") {
                    TextEditor(text: $draft.item.note)
                        .frame(minHeight: 90)
                }
            }
            .navigationTitle(isNew ? "新增保密资料" : "编辑保密资料")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
#if os(iOS)
                ToolbarItem(placement: .automatic) {
                    EditButton()
                }
#endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave)
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSAuthenticationSheet()
            }
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
            .onDisappear(perform: cleanUpUncommittedAttachments)
            .alert("无法添加附件", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .alert(
                "重命名附件",
                isPresented: Binding(
                    get: { renamingAttachment != nil },
                    set: { if !$0 { renamingAttachment = nil } }
                )
            ) {
                TextField("文件名", text: $renameText)
                Button("取消", role: .cancel) { renamingAttachment = nil }
                Button("保存") { renameAttachment() }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("文件格式会保持不变。")
            }
        }
#if os(iOS)
        .environment(\.editMode, $fieldEditMode)
#endif
    }

    private func binding(for id: UUID, fallback: SecretField) -> Binding<SecretField> {
        Binding(
            get: {
                draft.item.fields.first(where: { $0.id == id }) ?? fallback
            },
            set: { updatedField in
                guard let index = draft.item.fields.firstIndex(where: { $0.id == id }) else {
                    return
                }
                draft.item.fields[index] = updatedField
            }
        )
    }

    private func inputStyleBinding(for field: Binding<SecretField>) -> Binding<SecretFieldKind> {
        Binding(
            get: {
                field.wrappedValue.kind.isMultiline ? .multiline : .text
            },
            set: { style in
                field.wrappedValue.kind = style
            }
        )
    }

    private func fieldsMatchDefault(_ fields: [SecretField], for category: SecretCategory) -> Bool {
        let defaults = category.defaultFields
        guard fields.count == defaults.count else { return false }
        return zip(fields, defaults).allSatisfy { field, template in
            field.label == template.label
                && field.value.isEmpty
                && field.kind == template.kind
                && field.isSensitive == template.isSensitive
        }
    }

    @ViewBuilder
    private func fieldValueEditor(field: Binding<SecretField>) -> some View {
        if field.wrappedValue.kind.isMultiline {
            IMESafeMultilineTextField(prompt: "字段内容", text: field.value)
        } else {
            IMESafeTextField(prompt: "字段内容", text: field.value, alignment: .leading)
        }
    }

    private var attachmentSection: some View {
        Section {
            if draft.item.attachments.isEmpty {
                Text("暂无附件")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.item.attachments) { attachment in
                SecretAttachmentRow(attachment: attachment)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            beginRename(attachment)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.blue)
                        Button(role: .destructive) {
                            removeAttachment(attachment)
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                        .tint(.red)
                    }
            }

            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: 20,
                matching: .images
            ) {
                Label("从照片添加", systemImage: "photo.on.rectangle.angled")
            }
            Button { showingFileImporter = true } label: {
                Label("从文件添加图片或 PDF", systemImage: "folder.badge.plus")
            }
        } header: {
            Text("附件")
        } footer: {
            Text("附件保存在本机应用目录，并会随加密 .mytools 备份导出。")
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                draft.item.attachments.append(try store.importSecretAttachment(from: url))
            }
        } catch {
            reportError(error.localizedDescription)
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
                let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
                let suffix = contentType.preferredFilenameExtension ?? "jpg"
                let name = "照片-\(UUID().uuidString.prefix(8)).\(suffix)"
                draft.item.attachments.append(
                    try store.saveSecretPhoto(data: data, fileName: name, contentType: contentType)
                )
            } catch {
                reportError(error.localizedDescription)
            }
        }
    }

    private func removeAttachment(_ attachment: FileAttachment) {
        draft.item.attachments.removeAll { $0.id == attachment.id }
        if !originalAttachmentIDs.contains(attachment.id) {
            store.deleteUncommittedAttachment(attachment)
        }
    }

    private func beginRename(_ attachment: FileAttachment) {
        renamingAttachment = attachment
        renameText = attachment.fileName
    }

    private func renameAttachment() {
        guard let attachment = renamingAttachment,
              let index = draft.item.attachments.firstIndex(where: { $0.id == attachment.id }) else {
            renamingAttachment = nil
            return
        }

        do {
            draft.item.attachments[index] = try store.renameAttachment(attachment, to: renameText)
            renamingAttachment = nil
        } catch {
            reportError(error.localizedDescription)
        }
    }

    private func cleanUpUncommittedAttachments() {
        guard !didSave else { return }
        for attachment in draft.item.attachments
        where !originalAttachmentIDs.contains(attachment.id) {
            store.deleteUncommittedAttachment(attachment)
        }
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private func requestSave() {
        commitPendingTextInput { save() }
    }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }

        didSave = true
        store.upsertSecret(draft.item)
        dismiss()
    }
}
