import Foundation
import UniformTypeIdentifiers

enum AttachmentStoreError: LocalizedError {
    case invalidFile
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "无法读取这个附件。"
        case .fileMissing(let name): return "附件“\(name)”已不在本机，请重新添加。"
        }
    }
}

final class AttachmentStore {
    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL
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
        try data.write(to: destinationURL, options: [.atomic, .completeFileProtection])

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

    func delete(_ attachment: FileAttachment) {
        let fileURL = url(for: attachment)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    func recordsForBackup(_ records: [MedicalRecord]) throws -> [MedicalRecord] {
        try records.map { record in
            var copy = record
            for index in copy.attachments.indices {
                copy.attachments[index].backupData = try data(for: copy.attachments[index])
            }
            return copy
        }
    }

    func restoreAttachments(in records: [MedicalRecord]) throws -> [MedicalRecord] {
        try ensureDirectory()
        return try records.map { record in
            var copy = record
            for index in copy.attachments.indices {
                guard let payload = copy.attachments[index].backupData else { continue }
                let fileURL = url(for: copy.attachments[index])
                try payload.write(to: fileURL, options: [.atomic, .completeFileProtection])
                copy.attachments[index].fileSize = Int64(payload.count)
                copy.attachments[index].backupData = nil
            }
            return copy
        }
    }

    func cardsForBackup(_ cards: [BankCard]) throws -> [BankCard] {
        try cards.map { card in
            var copy = card
            for index in copy.statements.indices {
                guard var attachment = copy.statements[index].attachment else { continue }
                attachment.backupData = try data(for: attachment)
                copy.statements[index].attachment = attachment
            }
            return copy
        }
    }

    func restoreAttachments(in cards: [BankCard]) throws -> [BankCard] {
        try ensureDirectory()
        return try cards.map { card in
            var copy = card
            for index in copy.statements.indices {
                guard var attachment = copy.statements[index].attachment,
                      let payload = attachment.backupData else { continue }
                try payload.write(
                    to: url(for: attachment),
                    options: [.atomic, .completeFileProtection]
                )
                attachment.fileSize = Int64(payload.count)
                attachment.backupData = nil
                copy.statements[index].attachment = attachment
            }
            return copy
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func inferredKind(for contentType: UTType) -> AttachmentKind {
        contentType.conforms(to: .pdf) ? .scan : .other
    }
}
