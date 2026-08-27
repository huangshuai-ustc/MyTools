#if MYTOOLS_FEATURE_SECRETS
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

private enum SecretSortOrder: String {
    case nameAscending
    case nameDescending

    var direction: SortDirection {
        switch self {
        case .nameAscending: return .ascending
        case .nameDescending: return .descending
        }
    }

    func sorted(_ items: [SecretItem]) -> [SecretItem] {
        items.sorted { lhs, rhs in
            let comparison = displayName(lhs).localizedStandardCompare(displayName(rhs))
            if comparison == .orderedSame {
                return direction == .ascending
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.id.uuidString > rhs.id.uuidString
            }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private func displayName(_ item: SecretItem) -> String {
        item.title.isEmpty ? "未命名条目" : item.title
    }
}

private struct SecretSortMenu: View {
    @Binding var selection: String

    private var selectedOrder: SecretSortOrder {
        SecretSortOrder(rawValue: selection) ?? .nameAscending
    }

    var body: some View {
        Menu {
            Button {
                selection = selectedOrder == .nameAscending
                    ? SecretSortOrder.nameDescending.rawValue
                    : SecretSortOrder.nameAscending.rawValue
            } label: {
                Text("名称  \(selectedOrder.direction.indicator)")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("保密资料排序：名称，\(selectedOrder.direction.title)")
        .help("保密资料排序：名称，\(selectedOrder.direction.title)")
    }
}

private final class SecretEditorDraft: ObservableObject {
    @Published var item: SecretItem

    init(item: SecretItem) {
        self.item = item
    }
}

struct SecretVaultView: View {
    @EnvironmentObject private var store: SecretStore
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var preferenceChangeBus: AppPreferenceChangeBus
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appFontScale) private var fontScale
    @State private var query = ""
    @State private var categoryFilter: SecretCategoryFilter = .all
    @State private var selectedTag = ""
    @State private var isUnlocked = false
    @State private var showingSensitiveAccess = false
    @State private var editingItem: SecretItem?
    @State private var isCreating = false
    @State private var showingPasswordImportPage = false
    @State private var importResult: String?
    @State private var showingImportResult = false
    @AppStorage(AppStorageKey.secretSortOrder) private var sortOrderRawValue = SecretSortOrder.nameAscending.rawValue

    private var selectedSortOrder: SecretSortOrder {
        SecretSortOrder(rawValue: sortOrderRawValue) ?? .nameAscending
    }

    private var canAccess: Bool {
        auth.isAdmin || isUnlocked
    }

    private var visibleItems: [SecretItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredItems = store.secretItems
            .filter(categoryFilter.includes)
            .filter { selectedTag.isEmpty || AppTagSupport.parse($0.tags).contains(selectedTag) }
            .filter { item in
                term.isEmpty
                    || item.title.localizedCaseInsensitiveContains(term)
                    || item.category.title.localizedCaseInsensitiveContains(term)
                    || item.tags.localizedCaseInsensitiveContains(term)
                    || item.fields.contains { $0.label.localizedCaseInsensitiveContains(term) }
            }
        return selectedSortOrder.sorted(filteredItems)
    }

    private var availableTags: [String] {
        AppTagSupport.normalize(store.secretItems.flatMap { AppTagSupport.parse($0.tags) })
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
                if !availableTags.isEmpty {
                    AppTagFilterCapsules(tags: availableTags, selectedTag: $selectedTag)
                }
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
                    .appDeleteSwipeAction(isEnabled: auth.isAdmin) {
                        store.deleteSecrets(ids: [item.id])
                    }
                }
            }
        }
        .appNavigationTitle(ToolModule.secrets.title)
        .onChange(of: sortOrderRawValue) { _, _ in
            preferenceChangeBus.notifyChanged()
        }
        .iOSLabeledBackButton("工具")
        .searchable(text: $query, prompt: "搜索名称、分类或字段名称")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SecretSortMenu(selection: $sortOrderRawValue)
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
                        editingItem = SecretItem(fields: store.makeFields(for: .login))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加保密条目")
                    .contextMenu {
                        Menu {
                            Button {
                                showingPasswordImportPage = true
                            } label: {
                                Label("Apple 密码 CSV", systemImage: "key.fill")
                            }
                        } label: {
                            Label("从文件导入", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
        }
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
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
        .sheet(isPresented: $showingPasswordImportPage) {
            SecretPasswordImportView { items in
                let result = store.importSecrets(items)
                importResult = "已导入 \(result.inserted) 条，跳过重复记录 \(result.skipped) 条。"
                showingImportResult = true
            }
            .iOSLargeSheet()
        }
        .alert("密码导入结果", isPresented: $showingImportResult) {
            Button("确定", role: .cancel) { showingImportResult = false }
        } message: {
            Text(importResult ?? "")
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
        .onChange(of: availableTags) { _, tags in
            if !selectedTag.isEmpty, !tags.contains(selectedTag) {
                selectedTag = ""
            }
        }
    }

}

private struct SecretItemRow: View {
    @Environment(\.appFontScale) private var fontScale
    let item: SecretItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.systemImage)
                .appFont(.title3)
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
                Text(item.title.isEmpty ? "未命名条目" : item.title)
                    .appFont(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.category.title)
                        .appFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    SecretPurposeTag(purpose: item.purpose)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "lock.fill")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SecretPurposeTag: View {
    let purpose: SecretPurpose

    var body: some View {
        Text(purpose.title)
            .appFont(.caption2.weight(.semibold))
            .foregroundStyle(purpose == .work ? .indigo : .green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (purpose == .work ? Color.indigo : Color.green).opacity(0.14),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }
}

private struct SecretPasswordImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingFileImporter = false
    @State private var preview: ApplePasswordImportPreview?
    @State private var errorMessage: String?
    let onImport: ([SecretItem]) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("密码文件") {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("选择 Apple 密码 CSV", systemImage: "doc.badge.plus")
                    }
                    if let preview {
                        LabeledContent("文件名", value: preview.fileName)
                        LabeledContent("待导入", value: "\(preview.items.count) 条")
                    }
                }
                if let preview {
                    Section("导入预览") {
                        ForEach(preview.items.prefix(20)) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).appFont(.body.weight(.medium))
                                Text(item.fields.first(where: { $0.label == "用户名" })?.value ?? "")
                                    .appFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.fields.first(where: { $0.label == "URL" })?.value ?? "")
                                    .appFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if preview.items.count > 20 {
                            Text("另有 \(preview.items.count - 20) 条将在确认后导入")
                                .appFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .appNavigationTitle("导入 Apple 密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        guard let preview else { return }
                        onImport(preview.items)
                        dismiss()
                    }
                    .disabled(preview == nil)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false,
                onCompletion: loadFile
            )
            .alert("无法读取密码文件", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func loadFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            preview = try ApplePasswordImporter.decode(
                data: Data(contentsOf: url),
                fileName: url.lastPathComponent
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct SecretFieldTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var fontScale
    let category: SecretCategory
    @State private var fields: [SecretField]
    @State private var showingNewField = false
    @State private var newFieldName = ""
    @State private var draggedFieldID: UUID?
    @State private var editingFieldID: UUID?
    @State private var fieldNameDraft = ""
    let onSave: (SecretFieldTemplate) -> Void

    init(category: SecretCategory, template: SecretFieldTemplate, onSave: @escaping (SecretFieldTemplate) -> Void) {
        self.category = category
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
                                ForEach(SecretFieldInputType.allCases) { inputType in
                                    Text(inputType.title).tag(inputType)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale), alignment: .center)
                        .padding(.vertical, 4)
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
                } header: {
                    Text("字段模板 · \(category.title)")
                } footer: {
                    Text("模板只保存字段定义；右滑可显示/隐藏内容或编辑名称，左滑可删除，长按可拖动调整顺序；新建条目时会生成空白字段。")
                }

                Section {
                    Button {
                        newFieldName = ""
                        showingNewField = true
                    } label: {
                        Label("添加模板字段", systemImage: "plus.circle")
                    }
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
                            SecretField(
                                label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                kind: $0.kind,
                                inputType: $0.inputType,
                                isSensitive: $0.isSensitive
                            )
                        }
                        onSave(SecretFieldTemplate(category: category, fields: cleaned))
                        dismiss()
                    }
                    .disabled(fields.allSatisfy { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
            .alert("添加模板字段", isPresented: $showingNewField) {
                TextField("字段名称", text: $newFieldName)
                Button("取消", role: .cancel) {}
                Button("添加") {
                    let label = newFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return }
                    fields.append(SecretField(label: label, kind: .text, isSensitive: true))
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
              let sourceIndex = fields.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = fields.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        let movedField = fields.remove(at: sourceIndex)
        let insertionIndex = fields.firstIndex(where: { $0.id == targetID }) ?? targetIndex
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
                .appFont(.title3)
                .foregroundStyle(.pink)
                .frame(width: 40, height: 40)
                .background(.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.fileName)
                    .appFont(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(attachment.contentType.conforms(to: .pdf) ? "PDF" : "图片") · \(attachment.displaySize)")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsDisclosure {
                Spacer()
                Image(systemName: "chevron.right")
                    .appFont(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

struct SecretDetailView: View {
    @EnvironmentObject private var store: SecretStore
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
                        LabeledContent("用途", value: item.purpose.title)
                        if !item.tags.isEmpty {
                            LabeledContent("标签") {
                                if canRevealSensitiveFields {
                                    AppTagCapsules(tags: AppTagSupport.parse(item.tags))
                                } else {
                                    Text("••••••")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("保密字段") {
                        ForEach(store.effectiveFields(for: item)) { field in
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
                .appNavigationTitle(item.title.isEmpty ? "保密资料" : item.title)
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
                                Image(systemName: "square.and.pencil")
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
            AttachmentPreviewSheet(
                attachment: attachment,
                url: store.attachmentURL(for: attachment),
                onDismiss: { previewAttachment = nil }
            )
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
        let url = store.attachmentURL(for: attachment)
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
        guard field.isSensitive else { return true }
        return canRevealSensitiveFields && !hiddenFieldIDs.contains(field.id)
    }

    private var displayValue: String {
        guard !field.value.isEmpty else { return "未填写" }
        return isRevealed ? field.value : "••••••"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label.isEmpty ? "未命名字段" : field.label)
                    .appFont(.subheadline.weight(.medium))
                Spacer()
                if field.isSensitive, !field.value.isEmpty, canRevealSensitiveFields {
                    Button {
                        toggleReveal()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isRevealed ? "隐藏内容" : "显示内容")
                }
            }
            if isRevealed,
               field.inputType == .url,
               !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = URL(string: field.value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Link(destination: url) {
                    Text(displayValue)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.blue)
                        .underline()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                .copyableText(field.value)
            } else {
                Text(displayValue)
                    .fontDesign(isRevealed ? .monospaced : .default)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(field.kind.isMultiline ? 8 : 2)
                    .copyableText(isRevealed ? field.value : nil)
            }
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
    @EnvironmentObject private var store: SecretStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var fontScale
    @StateObject private var draft: SecretEditorDraft
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var showingAuthentication = false
    @State private var showingFieldNameEditor = false
    @State private var showingNewFieldNameEditor = false
    @State private var showingTemplateEditor = false
    @State private var editingFieldID: UUID?
    @State private var fieldNameDraft = ""
    @State private var newFieldNameDraft = ""
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
                    FieldEditorRow(title: "名称", prompt: "例如 Cloudflare", text: $draft.item.title)
                    PickerFieldRow(title: "分类", selection: $draft.item.category) {
                        ForEach(SecretCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(category)
                        }
                    }
                    .onChange(of: draft.item.category) { oldCategory, newCategory in
                        guard isNew, oldCategory != newCategory else {
                            return
                        }
                        draft.item.fields = store.makeFields(for: newCategory)
                    }
                    PickerFieldRow(title: "用途", selection: $draft.item.purpose) {
                        ForEach(SecretPurpose.allCases) { purpose in
                            Text(purpose.title).tag(purpose)
                        }
                    }
                }

                Section("标签") {
                    AppTagEditor(text: $draft.item.tags, suggestions: store.knownTags)
                }

                Section {
                    ForEach(draft.item.fields) { field in
                        let fieldBinding = binding(for: field.id, fallback: field)
                        fieldEditorRow(field: fieldBinding)
                            .padding(.vertical, 4)
                            .modifier(SecretFieldSwipeActionsModifier(
                                field: fieldBinding,
                                onRename: { beginFieldNameEdit(field) }
                            ))
                            .appDeleteSwipeAction {
                                draft.item.fields.removeAll { $0.id == field.id }
                            }
                    }
                    .onMove { source, destination in
                        draft.item.fields.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    HStack {
                        Text("字段")
                        Spacer()
                        Button("字段模板") {
                            showingTemplateEditor = true
                        }
                        .appFont(.subheadline)
                        .foregroundStyle(.blue)
                        .underline()
                    }
                }
                Section {
                    Button {
                        newFieldNameDraft = ""
                        showingNewFieldNameEditor = true
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
            .appNavigationTitle(isNew ? "新增保密资料" : "编辑保密资料")
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
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSAuthenticationSheet()
            }
            .alert("编辑字段名称", isPresented: $showingFieldNameEditor) {
                TextField("字段名称", text: $fieldNameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") { saveFieldName() }
            } message: {
                Text("固定字段名称不会直接修改；保存后只更新显示名称。")
            }
            .alert("添加字段", isPresented: $showingNewFieldNameEditor) {
                TextField("字段名称", text: $newFieldNameDraft)
                Button("取消", role: .cancel) {}
                Button("添加") { addNewField() }
            } message: {
                Text("请输入新字段的显示名称。")
            }
            .sheet(isPresented: $showingTemplateEditor) {
                SecretFieldTemplateEditorView(
                    category: draft.item.category,
                    template: store.fieldTemplate(for: draft.item.category)
                ) { template in
                    let previousTemplate = store.fieldTemplate(for: draft.item.category)
                    let shouldRefreshDraft = isNew
                        && fieldsMatchTemplate(draft.item.fields, template: previousTemplate)
                    store.upsertFieldTemplate(template)
                    if shouldRefreshDraft {
                        draft.item.fields = template.makeFields()
                    } else {
                        draft.item.fields = applyTemplateSensitivity(
                            to: draft.item.fields,
                            matching: template
                        )
                    }
                }
                .iOSLargeSheet()
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

    @ViewBuilder
    private func fieldEditorRow(field: Binding<SecretField>) -> some View {
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
                IMESafeMultilineTextField(
                    prompt: "请在此处键入\(field.wrappedValue.label)",
                    text: field.value,
                    minHeight: 34,
                    maxHeight: 180
                )
            }
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale), alignment: .center)
        .onChange(of: field.wrappedValue.value) { _, value in
            if field.wrappedValue.inputType == .text,
               value.contains(where: { $0.isNewline }) {
                field.wrappedValue.kind = .multiline
            } else if field.wrappedValue.inputType == .text,
                      field.wrappedValue.kind == .multiline {
                field.wrappedValue.kind = .text
            }
        }
    }

    private func dateBinding(for field: Binding<SecretField>) -> Binding<Date> {
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

    private func beginFieldNameEdit(_ field: SecretField) {
        editingFieldID = field.id
        fieldNameDraft = field.label
        showingFieldNameEditor = true
    }

    private func saveFieldName() {
        guard let editingFieldID else { return }
        let label = fieldNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, let index = draft.item.fields.firstIndex(where: { $0.id == editingFieldID }) else { return }
        draft.item.fields[index].label = label
        self.editingFieldID = nil
    }

    private func addNewField() {
        let label = newFieldNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        draft.item.fields.append(SecretField(label: label, kind: .text, inputType: .text, isSensitive: true))
    }

    private func fieldsMatchTemplate(_ fields: [SecretField], template: SecretFieldTemplate) -> Bool {
        let normalizedFields = fields
            .filter { $0.value.isEmpty }
            .map { "\($0.label)|\($0.kind.rawValue)|\($0.inputType.rawValue)|\($0.isSensitive)" }
            .sorted()
        let normalizedTemplate = template.fields
            .map { "\($0.label)|\($0.kind.rawValue)|\($0.inputType.rawValue)|\($0.isSensitive)" }
            .sorted()
        return fields.count == template.fields.count && normalizedFields == normalizedTemplate
    }

    private func applyTemplateSensitivity(
        to fields: [SecretField],
        matching template: SecretFieldTemplate
    ) -> [SecretField] {
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

    private var attachmentSection: some View {
        Section {
            if draft.item.attachments.isEmpty {
                Text("暂无附件")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.item.attachments) { attachment in
                SecretAttachmentRow(attachment: attachment)
                    .appSwipeActions(edge: .trailing, style: AppSwipeActions.secondary) {
                        Button {
                            beginRename(attachment)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(AppSwipeActions.rename.tint)
                        Button(role: .destructive) {
                            removeAttachment(attachment)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .tint(AppSwipeActions.delete.tint)
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

private struct SecretFieldSwipeActionsModifier: ViewModifier {
    let field: Binding<SecretField>
    let onRename: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        content.appSwipeActions(edge: .leading, style: AppSwipeActions.secondary) {
            Button {
                field.wrappedValue.isSensitive.toggle()
            } label: {
                visibilityLabel(isSensitive: field.wrappedValue.isSensitive)
            }
            .tint(AppSwipeActions.visibility.tint)
            Button(action: onRename) {
                Label("编辑名称", systemImage: "pencil")
            }
            .tint(AppSwipeActions.edit.tint)
        }
    }

    private func visibilityLabel(isSensitive: Bool) -> some View {
        Label(
            isSensitive ? "显示内容" : "隐藏内容",
            systemImage: isSensitive ? "eye" : "eye.slash"
        )
    }
}

#endif
