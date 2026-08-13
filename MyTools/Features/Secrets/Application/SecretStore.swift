#if MYTOOLS_FEATURE_SECRETS
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SecretStore: ObservableObject {
    @Published private(set) var secretItems: [SecretItem]
    @Published private(set) var fieldTemplates: [SecretFieldTemplate]

    private let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?
    private var isRestoringBackup = false

    init(
        secretItems: [SecretItem] = [],
        fieldTemplates: [SecretFieldTemplate] = SecretFieldTemplate.defaultTemplates,
        attachmentStore: AttachmentStore
    ) {
        self.secretItems = secretItems
        self.fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        self.attachmentStore = attachmentStore
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(
        secretItems: [SecretItem],
        fieldTemplates: [SecretFieldTemplate]? = nil
    ) {
        self.secretItems = secretItems
        if let fieldTemplates {
            self.fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        }
    }

    func fieldTemplate(for category: SecretCategory) -> SecretFieldTemplate {
        fieldTemplates.first(where: { $0.category == category })
            ?? SecretFieldTemplate(category: category, fields: category.defaultFields)
    }

    func makeFields(for category: SecretCategory) -> [SecretField] {
        fieldTemplate(for: category).makeFields()
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
        didMutate()
    }

    func setBackupRestoreInProgress(_ isRestoring: Bool) {
        isRestoringBackup = isRestoring
    }

    func upsertSecret(_ item: SecretItem) {
        guard !isRestoringBackup else { return }
        var storedItem = item
        storedItem.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        storedItem.tags = item.tags.trimmingCharacters(in: .whitespacesAndNewlines)
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
            secretItems.append(item)
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

    private static func normalizedTemplates(_ templates: [SecretFieldTemplate]) -> [SecretFieldTemplate] {
        var byCategory = Dictionary(uniqueKeysWithValues: templates.map { ($0.category, $0.normalized()) })
        for fallback in SecretFieldTemplate.defaultTemplates where byCategory[fallback.category] == nil {
            byCategory[fallback.category] = fallback
        }
        return SecretCategory.allCases.compactMap { byCategory[$0] }
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
