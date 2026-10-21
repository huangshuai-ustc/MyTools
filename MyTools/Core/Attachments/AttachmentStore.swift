import Foundation
import ImageIO
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

    /// Large photos are stored as a downscaled JPEG instead of the original;
    /// images with transparency are downscaled in their own format.
    func save(data: Data, originalFileName: String, contentType: UTType) throws -> FileAttachment {
        guard !data.isEmpty else { throw AttachmentStoreError.invalidFile }
        if let jpeg = AttachmentImageCompressor.compressed(data, contentType: contentType, as: .jpeg) {
            return try saveFile(
                data: jpeg,
                originalFileName: AttachmentImageCompressor.jpegFileName(for: originalFileName),
                contentType: .jpeg
            )
        }
        let stored = AttachmentImageCompressor.compressed(data, contentType: contentType, as: contentType) ?? data
        return try saveFile(data: stored, originalFileName: originalFileName, contentType: contentType)
    }

    /// Reads a stored image and re-encodes it smaller in its own format, so it
    /// can be written back under the same stored name and every copy of the
    /// metadata (open editor drafts, other devices) keeps pointing at it.
    /// - Returns: nil for a missing file; otherwise the current size on disk
    ///   and the smaller bytes, if re-encoding saves enough.
    func compressedStoredImage(_ attachment: FileAttachment) throws -> (data: Data?, storedSize: Int64)? {
        let original: Data
        do {
            original = try data(for: attachment)
        } catch AttachmentStoreError.fileMissing {
            return nil
        }
        let compressed = AttachmentImageCompressor.compressed(
            original,
            contentType: attachment.contentType,
            as: attachment.contentType
        )
        return (compressed, Int64(original.count))
    }

    private func saveFile(data: Data, originalFileName: String, contentType: UTType) throws -> FileAttachment {
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

    /// `storedFileName` arrives from backups and CloudKit, so it is untrusted.
    /// Only a single visible path component is accepted. Historical builds stored
    /// display-style names, so the rule cannot be narrowed to UUIDs without
    /// orphaning existing files.
    static func isSafeStoredFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.count <= 255
            && !name.hasPrefix(".")
            && !name.contains { $0 == "/" || $0 == "\\" || $0 == ":" || $0 == "\0" }
    }

    /// Resolves the on-disk location, refusing any name that could leave the
    /// attachment directory. Every read, write and delete goes through here.
    private func resolvedURL(for attachment: FileAttachment) throws -> URL {
        let name = attachment.storedFileName
        guard Self.isSafeStoredFileName(name) else { throw AttachmentStoreError.invalidFileName }
        let candidate = directoryURL.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == directoryURL.standardizedFileURL.path else {
            throw AttachmentStoreError.invalidFileName
        }
        return candidate
    }

    /// Read-only location for previews and uploads. An unsafe name maps to a
    /// hidden path inside the directory that never exists, so callers see a
    /// missing file instead of reaching outside the sandbox folder.
    func url(for attachment: FileAttachment) -> URL {
        (try? resolvedURL(for: attachment))
            ?? directoryURL.appendingPathComponent(".invalid-\(attachment.id.uuidString.lowercased())", isDirectory: false)
    }

    func data(for attachment: FileAttachment) throws -> Data {
        let fileURL = try resolvedURL(for: attachment)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AttachmentStoreError.fileMissing(attachment.fileName)
        }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    func write(_ data: Data, to attachment: FileAttachment) throws {
        let destinationURL = try resolvedURL(for: attachment)
        try ensureDirectory()
        try data.write(
            to: destinationURL,
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
        let destinationURL = try resolvedURL(for: attachment)
        try ensureDirectory()
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
        guard let fileURL = try? resolvedURL(for: attachment),
              fileManager.fileExists(atPath: fileURL.path) else { return }
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

        let sourceURL = try resolvedURL(for: attachment)
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
        let sourceURL = try resolvedURL(for: attachment)
        let destinationURL = try resolvedURL(for: original)
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

// MARK: - Image compression

/// Downscales photos so a single attachment is no longer a multi-megabyte
/// original. EXIF orientation is applied to the pixels and the metadata
/// (including location) is dropped.
enum AttachmentImageCompressor {
    static let maxPixelSize = 2560
    static let compressionQuality = 0.8
    /// Images whose longest side fits are only re-encoded above this size and
    /// above `bytesPerPixelThreshold`. A JPEG already written at
    /// `compressionQuality` stays below that density, so it is never
    /// re-encoded again and does not lose quality on every pass.
    static let byteThreshold = 1_000_000
    static let bytesPerPixelThreshold = 0.4

    /// - Returns: The re-encoded image, or nil when the input is not a still
    ///   image worth compressing or re-encoding would not save at least 10%.
    static func compressed(_ data: Data, contentType: UTType, as outputType: UTType) -> Data? {
        guard contentType.conforms(to: .image), !contentType.conforms(to: .gif),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        // JPEG has no alpha channel; transparent pixels would turn black.
        if outputType.conforms(to: .jpeg), properties[kCGImagePropertyHasAlpha] as? Bool == true {
            return nil
        }
        let longestSide = max(width, height)
        let bytesPerPixel = Double(data.count) / Double(max(width * height, 1))
        // Re-encoding a PNG at the same size cannot gain much, so only lossy
        // outputs are re-encoded purely for their byte density.
        let isLossyOutput = outputType.conforms(to: .jpeg) || outputType.conforms(to: .heic)
        guard longestSide > maxPixelSize
                || (isLossyOutput && data.count > byteThreshold && bytesPerPixel > bytesPerPixelThreshold) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longestSide, maxPixelSize)
        ]
        let output = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              let destination = CGImageDestinationCreateWithData(
                  output as CFMutableData, outputType.identifier as CFString, 1, nil
              ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length < data.count * 9 / 10 else {
            return nil
        }
        return output as Data
    }

    static func jpegFileName(for fileName: String) -> String {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        guard fileExtension != "jpg", fileExtension != "jpeg" else { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        return (base.isEmpty ? fileName : base) + ".jpg"
    }
}
