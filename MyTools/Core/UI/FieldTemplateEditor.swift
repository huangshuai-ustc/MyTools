import SwiftUI
import Foundation

/// Input types offered by a field template editor (text, URL, date, ...).
protocol TemplateFieldInputKind: CaseIterable, Identifiable, Hashable, RawRepresentable
where AllCases == [Self], RawValue == String {
    var title: String { get }
}

/// A field that can be edited in `FieldTemplateEditorView`. Each module keeps
/// its own persisted field model; this protocol only exposes what templates
/// share, so Documents and Secrets use one editor and one matching rule.
protocol TemplateEditableField: Identifiable where ID == UUID {
    associatedtype InputKind: TemplateFieldInputKind

    var label: String { get set }
    var value: String { get }
    var inputType: InputKind { get set }
    var isSensitive: Bool { get set }
    /// Module-specific layout part of the template signature.
    var templateLayoutKey: String { get }

    static func newTemplateField(label: String) -> Self
    /// A blank copy with a fresh id and the given label, keeping layout and visibility.
    func templateCopy(label: String) -> Self
}

enum FieldTemplateMatching {
    /// Only same-named fields follow the template; a kind-only fallback
    /// would expose unrelated custom fields (AUDIT-018).
    static func matchingField<Field: TemplateEditableField>(
        for field: Field,
        in templateFields: [Field]
    ) -> Field? {
        templateFields.first {
            $0.label == field.label && $0.inputType == field.inputType
        }
    }

    static func applyingSensitivity<Field: TemplateEditableField>(
        to fields: [Field],
        matching templateFields: [Field]
    ) -> [Field] {
        fields.map { field in
            guard let templateField = matchingField(for: field, in: templateFields) else {
                return field
            }
            var updated = field
            updated.isSensitive = templateField.isSensitive
            return updated
        }
    }

    /// True when the fields are still the untouched blank fields of the template.
    static func fieldsMatchTemplate<Field: TemplateEditableField>(
        _ fields: [Field],
        templateFields: [Field]
    ) -> Bool {
        let normalizedFields = fields
            .filter { $0.value.isEmpty }
            .map { $0.templateSignature }
            .sorted()
        let normalizedTemplate = templateFields.map { $0.templateSignature }.sorted()
        return fields.count == templateFields.count && normalizedFields == normalizedTemplate
    }
}

private extension TemplateEditableField {
    var templateSignature: String {
        "\(label)|\(templateLayoutKey)|\(inputType.rawValue)|\(isSensitive)"
    }
}

struct FieldTemplateEditorView<Field: TemplateEditableField>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var fontScale
    let title: String
    let recordNoun: String
    @State private var fields: [Field]
    @State private var showingNewField = false
    @State private var newFieldName = ""
    @State private var draggedFieldID: UUID?
    @State private var editingFieldID: UUID?
    @State private var fieldNameDraft = ""
    let onSave: ([Field]) -> Void

    /// - Parameters:
    ///   - title: Shown after “字段模板 · ”.
    ///   - recordNoun: What a new record is called in the footer, e.g. “证照”.
    init(
        title: String,
        recordNoun: String,
        fields: [Field],
        onSave: @escaping ([Field]) -> Void
    ) {
        self.title = title
        self.recordNoun = recordNoun
        _fields = State(initialValue: fields)
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
                                ForEach(Field.InputKind.allCases) { inputType in
                                    Text(inputType.title).tag(inputType)
                                }
                            }
                            .pickerStyle(.menu)
                            .foregroundStyle(.secondary)
                            .tint(.blue)
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
                    Text("字段模板 · \(title)")
                } footer: {
                    Text("模板只保存字段定义；右滑可显示/隐藏内容或编辑名称，左滑可删除，长按可拖动调整顺序；新建\(recordNoun)时会生成空白字段。")
                }
            }
            .appNavigationTitle("字段模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(Self.cleaned(fields))
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
                    fields.append(Field.newTemplateField(label: label))
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

    /// Drops unnamed fields and trims labels; values are never part of a template.
    static func cleaned(_ fields: [Field]) -> [Field] {
        fields.compactMap { field in
            let label = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? nil : field.templateCopy(label: label)
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
