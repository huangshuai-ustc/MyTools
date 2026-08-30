import Foundation
import UniformTypeIdentifiers

enum AttachmentStoreError: LocalizedError {
    case invalidFile
    case invalidFileName
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "无法读取这个附件。"
        case .invalidFileName: return "文件名不能为空，也不能包含路径分隔符。"
        case .fileMissing(let name): return "附件“\(name)”已不在本机，请重新添加。"
        }
    }
}

final class AttachmentStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = directoryURL ?? baseURL
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    func importFile(from sourceURL: URL) throws -> FileAttachment {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let contentType = try? sourceURL.resourceValues(forKeys: [.contentTypeKey]).contentType
        return try save(
            data: data,
            originalFileName: sourceURL.lastPathComponent,
            contentType: contentType ?? UTType(filenameExtension: sourceURL.pathExtension) ?? .data
        )
    }

    func save(data: Data, originalFileName: String, contentType: UTType) throws -> FileAttachment {
        guard !data.isEmpty else { throw AttachmentStoreError.invalidFile }
        try ensureDirectory()

        let id = UUID()
        let fileExtension = contentType.preferredFilenameExtension
            ?? URL(fileURLWithPath: originalFileName).pathExtension
        let storedFileName = fileExtension.isEmpty
            ? id.uuidString.lowercased()
            : "\(id.uuidString.lowercased()).\(fileExtension)"
        let destinationURL = directoryURL.appendingPathComponent(storedFileName, isDirectory: false)
        try data.write(to: destinationURL, options: Self.writingOptions)

        return FileAttachment(
            id: id,
            fileName: originalFileName,
            storedFileName: storedFileName,
            contentTypeIdentifier: contentType.identifier,
            kind: inferredKind(for: contentType),
            createdAt: Date(),
            fileSize: Int64(data.count),
            backupData: nil
        )
    }

    func url(for attachment: FileAttachment) -> URL {
        directoryURL.appendingPathComponent(attachment.storedFileName, isDirectory: false)
    }

    func data(for attachment: FileAttachment) throws -> Data {
        let fileURL = url(for: attachment)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AttachmentStoreError.fileMissing(attachment.fileName)
        }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    func write(_ data: Data, to attachment: FileAttachment) throws {
        try ensureDirectory()
        try data.write(
            to: url(for: attachment),
            options: Self.writingOptions
        )
    }

    func write(
        _ data: Data,
        to attachment: FileAttachment,
        replacing previous: FileAttachment?
    ) throws {
        try write(data, to: attachment)
        guard let previous,
              previous.storedFileName != attachment.storedFileName else { return }
        delete(previous)
    }

    func copyFile(
        from sourceURL: URL,
        to attachment: FileAttachment,
        replacing previous: FileAttachment?
    ) throws {
        try ensureDirectory()
        let destinationURL = url(for: attachment)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".icloud-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)

        guard let previous,
              previous.storedFileName != attachment.storedFileName else { return }
        delete(previous)
    }

    func delete(_ attachment: FileAttachment) {
        let fileURL = url(for: attachment)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    func rename(_ attachment: FileAttachment, to requestedFileName: String) throws -> FileAttachment {
        let trimmedName = requestedFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != ".",
              trimmedName != "..",
              URL(fileURLWithPath: trimmedName).lastPathComponent == trimmedName else {
            throw AttachmentStoreError.invalidFileName
        }

        let sourceURL = url(for: attachment)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AttachmentStoreError.fileMissing(attachment.fileName)
        }

        // Display names are metadata and may intentionally repeat. The file
        // on disk keeps its opaque UUID-backed stored name, so renaming one
        // attachment never collides with another or moves its contents.
        var renamed = attachment
        renamed.fileName = trimmedName
        return renamed
    }

    func restoreLocation(
        of attachment: FileAttachment,
        to original: FileAttachment
    ) throws {
        guard attachment.id == original.id else {
            throw AttachmentStoreError.invalidFile
        }
        let sourceURL = url(for: attachment)
        let destinationURL = url(for: original)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AttachmentStoreError.fileMissing(attachment.fileName)
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw AttachmentStoreError.invalidFile
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static var writingOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }

    private func inferredKind(for contentType: UTType) -> AttachmentKind {
        contentType.conforms(to: .pdf) ? .scan : .other
    }
}

// MARK: - AttachmentManaging

/// A protocol that module Stores can adopt to get standard attachment
/// delegation methods via a default-implementation extension, instead of
/// each Store hand-writing the same one-line pass-throughs to `AttachmentStore`.
///
/// Conforming types must expose `attachmentStore: AttachmentStore`.
/// Methods that require domain-specific content-type validation (e.g.
/// `importCreditCardStatement`, `importPhoto`) remain on the concrete Store
/// because those rules belong to the module.  The protocol provides only the
/// universal, content-agnostic operations.
@MainActor
protocol AttachmentManaging: AnyObject {
    var attachmentStore: AttachmentStore { get }
}

@MainActor
extension AttachmentManaging {
    /// Deletes an attachment that was added during the current edit session but
    /// the user cancelled — the attachment was never associated with a record.
    func deleteUncommittedAttachment(_ attachment: FileAttachment) {
        attachmentStore.delete(attachment)
    }

    /// Renames the display name of an attachment without moving the file on disk.
    func renameAttachment(
        _ attachment: FileAttachment,
        to fileName: String
    ) throws -> FileAttachment {
        try attachmentStore.rename(attachment, to: fileName)
    }

    /// Returns the on-disk URL for an attachment (read-only access or Quick Look).
    func attachmentURL(for attachment: FileAttachment) -> URL {
        attachmentStore.url(for: attachment)
    }

    /// Restores the on-disk location of an attachment to its original path
    /// after a rollback (used by `AttachmentEditSession`).
    func restoreAttachmentLocation(
        _ attachment: FileAttachment,
        to original: FileAttachment
    ) throws {
        try attachmentStore.restoreLocation(of: attachment, to: original)
    }
}
