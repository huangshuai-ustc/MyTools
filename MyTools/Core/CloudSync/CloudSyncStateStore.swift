import CloudKit
import Foundation
import OSLog

struct CloudSyncStoredEntry: Codable, Sendable {
    let kind: CloudSyncEntityKind
    let id: UUID
    var module: ToolModule? = nil
    var digest: Data?
    var modifiedAt: Date
    var deviceID: String
    var isDeleted: Bool
    var payload: Data?
    var systemFields: Data?
}

struct CloudSyncStoredDocument: Codable, Sendable {
    static let currentReconciliationVersion = 3

    var engineState: CKSyncEngine.State.Serialization?
    var entries: [String: CloudSyncStoredEntry]
    var deviceID: String
    var accountRecordName: String?
    var reconciliationVersion: Int?

    init(
        engineState: CKSyncEngine.State.Serialization? = nil,
        entries: [String: CloudSyncStoredEntry] = [:],
        deviceID: String = UUID().uuidString.lowercased(),
        accountRecordName: String? = nil,
        reconciliationVersion: Int? = Self.currentReconciliationVersion
    ) {
        self.engineState = engineState
        self.entries = entries
        self.deviceID = deviceID
        self.accountRecordName = accountRecordName
        self.reconciliationVersion = reconciliationVersion
    }

    mutating func prepareForCurrentReconciliationVersion() -> Bool {
        guard reconciliationVersion != Self.currentReconciliationVersion else {
            return false
        }
        engineState = nil
        entries = [:]
        reconciliationVersion = Self.currentReconciliationVersion
        return true
    }
}

final class CloudSyncStateStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let baseURL = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        fileURL = baseURL
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("cloud-sync-state.json", isDirectory: false)
    }

    func load() -> CloudSyncStoredDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CloudSyncStoredDocument()
        }
        do {
            return try JSONDecoder().decode(
                CloudSyncStoredDocument.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            cloudSyncLogger.error(
                "Unable to decode cloud sync state: \(DiagnosticLogger.errorCode(error), privacy: .public)"
            )
            return CloudSyncStoredDocument()
        }
    }

    func save(_ document: CloudSyncStoredDocument) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(document)
        try data.write(to: fileURL, options: .atomic)
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#endif
    }
}

extension CKRecord {
    func cloudSyncSystemFields() -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func cloudSyncRecord(from data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}

let cloudSyncLogger = Logger(
    subsystem: AppMetadata.bundleIdentifier,
    category: "CloudSync"
)
