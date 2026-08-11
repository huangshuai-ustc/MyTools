#if MYTOOLS_FEATURE_SECRETS
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SecretStore: ObservableObject {
    @Published private(set) var secretItems: [SecretItem]

    private let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?
    private var isRestoringBackup = false

    init(
        secretItems: [SecretItem] = [],
        attachmentStore: AttachmentStore
    ) {
        self.secretItems = secretItems
        self.attachmentStore = attachmentStore
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(secretItems: [SecretItem]) {
        self.secretItems = secretItems
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
}

#endif
