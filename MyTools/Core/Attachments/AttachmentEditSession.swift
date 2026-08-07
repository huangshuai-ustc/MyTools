import Foundation

struct AttachmentEditSession {
    private let originalAttachments: [UUID: FileAttachment]
    private var latestOriginalAttachments: [UUID: FileAttachment]
    private var isFinished = false

    init(originalAttachments: [FileAttachment]) {
        let originals = Dictionary(uniqueKeysWithValues: originalAttachments.map { ($0.id, $0) })
        self.originalAttachments = originals
        latestOriginalAttachments = originals
    }

    func isOriginal(_ attachment: FileAttachment) -> Bool {
        originalAttachments[attachment.id] != nil
    }

    mutating func trackRename(_ attachment: FileAttachment) {
        guard originalAttachments[attachment.id] != nil else { return }
        latestOriginalAttachments[attachment.id] = attachment
    }

    mutating func commit() {
        isFinished = true
    }

    mutating func rollback(
        currentAttachments: [FileAttachment],
        delete: (FileAttachment) -> Void,
        restoreLocation: (FileAttachment, FileAttachment) throws -> Void
    ) -> [String] {
        guard !isFinished else { return [] }
        isFinished = true

        currentAttachments
            .filter { originalAttachments[$0.id] == nil }
            .forEach(delete)

        var failures: [String] = []
        for (id, original) in originalAttachments {
            guard let latest = latestOriginalAttachments[id],
                  latest.storedFileName != original.storedFileName else { continue }
            do {
                try restoreLocation(latest, original)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return failures
    }
}
