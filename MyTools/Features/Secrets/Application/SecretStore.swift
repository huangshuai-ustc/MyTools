#if MYTOOLS_FEATURE_SECRETS
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SecretStore: ObservableObject, BackupRestoreParticipant, AttachmentManaging {
    @Published private(set) var secretItems: [SecretItem]
    @Published private(set) var fieldTemplates: [SecretFieldTemplate]
    @Published private(set) var knownTags: [String]

    let attachmentStore: AttachmentStore
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
        DiagnosticLogger.shared.log(.data, "密码数据替换 count=\(normalizedItems.count)")
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

    // MARK: - BackupRestoreParticipant

    func backupRestoreStateChanged(isRestoring: Bool) {
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
        let isUpdate: Bool
        var removedAttachments: [FileAttachment] = []
        if let index = secretItems.firstIndex(where: { $0.id == storedItem.id }) {
            let retainedAttachmentIDs = Set(storedItem.attachments.map(\.id))
            removedAttachments = secretItems[index].attachments
                .filter { !retainedAttachmentIDs.contains($0.id) }
            storedItem.createdAt = secretItems[index].createdAt
            secretItems[index] = storedItem
            isUpdate = true
        } else {
            secretItems.append(storedItem)
            isUpdate = false
        }
        DiagnosticLogger.shared.log(.data, "密码\(isUpdate ? "更新" : "新增") id=\(storedItem.id)")
        didMutate(removing: removedAttachments)
    }

    func deleteSecrets(ids: Set<UUID>) {
        guard !ids.isEmpty, !isRestoringBackup else { return }
        let removedAttachments = secretItems
            .filter { ids.contains($0.id) }
            .flatMap(\.attachments)
        secretItems.removeAll { ids.contains($0.id) }
        DiagnosticLogger.shared.log(.data, "密码删除 count=\(ids.count)")
        didMutate(removing: removedAttachments)
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
        DiagnosticLogger.shared.log(.data, "密码导入完成 inserted=\(inserted) skipped=\(skipped)")
        if inserted > 0 { didMutate() }
        return (inserted, skipped)
    }

    func importSecretAttachment(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .image)
                || attachment.contentType.conforms(to: .pdf) else {
            attachmentStore.delete(attachment)
            DiagnosticLogger.shared.log(.attachment, "密码附件导入被拒绝（不支持的文件类型） name=\(url.lastPathComponent)", level: .warning)
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

    // deleteUncommittedAttachment, renameAttachment, attachmentURL
    // are provided by the AttachmentManaging protocol extension.

    private func didMutate(removing attachments: [FileAttachment] = []) {
        mutationNotifier?.moduleStoreDidMutate()
        // Files go only after the Vault no longer referencing them is on disk
        // (AUDIT-017). A store without a Vault behind it deletes immediately.
        if let mutationNotifier {
            mutationNotifier.scheduleAttachmentRemovalAfterPersistence(attachments)
        } else {
            attachments.forEach(attachmentStore.delete)
        }
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
        FieldTemplateMatching.matchingField(for: field, in: template.fields)
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
