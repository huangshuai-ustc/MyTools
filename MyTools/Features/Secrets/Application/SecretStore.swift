#if MYTOOLS_FEATURE_SECRETS
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SecretStore: ObservableObject {
    @Published private(set) var secretItems: [SecretItem]
    @Published private(set) var fieldTemplates: [SecretFieldTemplate]
    @Published private(set) var knownTags: [String]

    private let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?
    private var isRestoringBackup = false

    init(
        secretItems: [SecretItem] = [],
        fieldTemplates: [SecretFieldTemplate] = SecretFieldTemplate.defaultTemplates,
        knownTags: [String] = [],
        attachmentStore: AttachmentStore
    ) {
        let normalizedItems = secretItems.map(Self.normalizedTags(in:))
        self.secretItems = normalizedItems
        self.fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        self.knownTags = AppTagSupport.merged(
            knownTags,
            with: normalizedItems.flatMap { AppTagSupport.parse($0.tags) }
        )
        self.attachmentStore = attachmentStore
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(
        secretItems: [SecretItem],
        fieldTemplates: [SecretFieldTemplate]? = nil,
        knownTags: [String]? = nil
    ) {
        let normalizedItems = secretItems.map(Self.normalizedTags(in:))
        self.secretItems = normalizedItems
        if let fieldTemplates {
            self.fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        }
        self.knownTags = AppTagSupport.merged(
            knownTags ?? self.knownTags,
            with: normalizedItems.flatMap { AppTagSupport.parse($0.tags) }
        )
    }

    func fieldTemplate(for category: SecretCategory) -> SecretFieldTemplate {
        fieldTemplates.first(where: { $0.category == category })
            ?? SecretFieldTemplate(category: category, fields: category.defaultFields)
    }

    func makeFields(for category: SecretCategory) -> [SecretField] {
        fieldTemplate(for: category).makeFields()
    }

    func effectiveFields(for item: SecretItem) -> [SecretField] {
        let template = fieldTemplate(for: item.category)
        return item.fields.map { field in
            guard let templateField = matchingTemplateField(for: field, in: template) else {
                return field
            }
            var effectiveField = field
            effectiveField.isSensitive = templateField.isSensitive
            return effectiveField
        }
    }

    func upsertFieldTemplate(_ template: SecretFieldTemplate) {
        guard !isRestoringBackup else { return }
        let normalized = template.normalized()
        if let index = fieldTemplates.firstIndex(where: { $0.category == normalized.category }) {
            fieldTemplates[index] = normalized
        } else {
            fieldTemplates.append(normalized)
        }
        fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        let changedAt = Date()
        secretItems = secretItems.map { item in
            guard item.category == normalized.category else { return item }
            var updatedItem = item
            var didUpdate = false
            updatedItem.fields = item.fields.map { field in
                guard let templateField = matchingTemplateField(for: field, in: normalized),
                      field.isSensitive != templateField.isSensitive else {
                    return field
                }
                var updatedField = field
                updatedField.isSensitive = templateField.isSensitive
                didUpdate = true
                return updatedField
            }
            if didUpdate {
                updatedItem.updatedAt = changedAt
            }
            return updatedItem
        }
        didMutate()
    }

    func setBackupRestoreInProgress(_ isRestoring: Bool) {
        isRestoringBackup = isRestoring
    }

    func upsertSecret(_ item: SecretItem) {
        guard !isRestoringBackup else { return }
        var storedItem = item
        storedItem.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = AppTagSupport.parse(item.tags)
        storedItem.tags = AppTagSupport.joined(tags)
        knownTags = AppTagSupport.merged(knownTags, with: tags)
        storedItem.updatedAt = Date()
        if let index = secretItems.firstIndex(where: { $0.id == storedItem.id }) {
            let retainedAttachmentIDs = Set(storedItem.attachments.map(\.id))
            for attachment in secretItems[index].attachments
            where !retainedAttachmentIDs.contains(attachment.id) {
                attachmentStore.delete(attachment)
            }
            storedItem.createdAt = secretItems[index].createdAt
            secretItems[index] = storedItem
        } else {
            secretItems.append(storedItem)
        }
        didMutate()
    }

    func deleteSecrets(ids: Set<UUID>) {
        guard !ids.isEmpty, !isRestoringBackup else { return }
        for item in secretItems where ids.contains(item.id) {
            item.attachments.forEach(attachmentStore.delete)
        }
        secretItems.removeAll { ids.contains($0.id) }
        didMutate()
    }

    func importSecrets(_ items: [SecretItem]) -> (inserted: Int, skipped: Int) {
        guard !items.isEmpty, !isRestoringBackup else { return (0, items.count) }
        var signatures = Set(secretItems.map(Self.importSignature))
        var inserted = 0
        var skipped = 0
        for item in items {
            let signature = Self.importSignature(item)
            guard signatures.insert(signature).inserted else {
                skipped += 1
                continue
            }
            var storedItem = item
            let tags = AppTagSupport.parse(item.tags)
            storedItem.tags = AppTagSupport.joined(tags)
            knownTags = AppTagSupport.merged(knownTags, with: tags)
            secretItems.append(storedItem)
            inserted += 1
        }
        if inserted > 0 { didMutate() }
        return (inserted, skipped)
    }

    func importSecretAttachment(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .image)
                || attachment.contentType.conforms(to: .pdf) else {
            attachmentStore.delete(attachment)
            throw AttachmentStoreError.invalidFile
        }
        return attachment
    }

    func saveSecretPhoto(
        data: Data,
        fileName: String,
        contentType: UTType
    ) throws -> FileAttachment {
        guard contentType.conforms(to: .image) else {
            throw AttachmentStoreError.invalidFile
        }
        return try attachmentStore.save(
            data: data,
            originalFileName: fileName,
            contentType: contentType
        )
    }

    func deleteUncommittedAttachment(_ attachment: FileAttachment) {
        attachmentStore.delete(attachment)
    }

    func renameAttachment(
        _ attachment: FileAttachment,
        to fileName: String
    ) throws -> FileAttachment {
        try attachmentStore.rename(attachment, to: fileName)
    }

    func attachmentURL(for attachment: FileAttachment) -> URL {
        attachmentStore.url(for: attachment)
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
    }

    private static func normalizedTags(in item: SecretItem) -> SecretItem {
        var result = item
        result.tags = AppTagSupport.joined(AppTagSupport.parse(item.tags))
        return result
    }

    private static func normalizedTemplates(_ templates: [SecretFieldTemplate]) -> [SecretFieldTemplate] {
        var byCategory = Dictionary(uniqueKeysWithValues: templates.map { ($0.category, $0.normalized()) })
        for fallback in SecretFieldTemplate.defaultTemplates where byCategory[fallback.category] == nil {
            byCategory[fallback.category] = fallback
        }
        return SecretCategory.allCases.compactMap { byCategory[$0] }
    }

    private func matchingTemplateField(
        for field: SecretField,
        in template: SecretFieldTemplate
    ) -> SecretField? {
        if let exactMatch = template.fields.first(where: {
            $0.label == field.label && $0.inputType == field.inputType
        }) {
            return exactMatch
        }

        let kindMatches = template.fields.filter {
            $0.kind == field.kind && $0.inputType == field.inputType
        }
        return kindMatches.count == 1 ? kindMatches.first : nil
    }

    private static func importSignature(_ item: SecretItem) -> String {
        let fieldValues = item.fields.map {
            "\($0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())=\($0.value)"
        }.joined(separator: "\u{1f}")
        return [
            item.category.rawValue,
            item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fieldValues
        ].joined(separator: "\u{1e}")
    }
}

#endif
