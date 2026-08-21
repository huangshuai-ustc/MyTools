import CloudKit
import Compression
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

    /// CloudKit system fields are only needed while a record is being retried.
    /// Stable record IDs and the explicit payload fields are enough to rebuild
    /// a record after a successful send, so retaining them for every entity
    /// needlessly turns this local coordination file into a second database.
    mutating func discardSystemFields(excluding pendingKeys: Set<String>) -> Bool {
        var didChange = false
        for key in entries.keys where !pendingKeys.contains(key) {
            guard entries[key]?.systemFields != nil else { continue }
            entries[key]?.systemFields = nil
            didChange = true
        }
        return didChange
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
            let storedData = try Data(contentsOf: fileURL)
            guard let data = CloudSyncStateFileCodec.decode(storedData) else {
                cloudSyncLogger.error("Unable to decompress cloud sync state")
                return CloudSyncStoredDocument()
            }
            return try JSONDecoder().decode(
                CloudSyncStoredDocument.self,
                from: data
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
        let encodedDocument = try JSONEncoder().encode(document)
        let data = CloudSyncStateFileCodec.encode(encodedDocument) ?? encodedDocument
        try data.write(to: fileURL, options: .atomic)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var persistedURL = fileURL
        try? persistedURL.setResourceValues(resourceValues)
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#endif
    }
}

/// The engine state repeats record metadata for every synchronized entity. Keep
/// it local and compressed; it is neither user data nor a CloudKit payload.
private enum CloudSyncStateFileCodec {
    private static let marker = Data([0x4D, 0x54, 0x53, 0x43, 0x01]) // MTSC + version
    private static let outputChunkSize = 64 * 1_024
    private static let maximumDecodedBytes = 512 * 1_024 * 1_024

    static func encode(_ data: Data) -> Data? {
        guard let compressed = transform(data, operation: COMPRESSION_STREAM_ENCODE),
              compressed.count < data.count else {
            return nil
        }
        return marker + compressed
    }

    static func decode(_ data: Data) -> Data? {
        guard data.starts(with: marker) else { return data }
        return transform(Data(data.dropFirst(marker.count)), operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transform(
        _ data: Data,
        operation: compression_stream_operation
    ) -> Data? {
        let bootstrapDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let bootstrapSource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            bootstrapDestination.deallocate()
            bootstrapSource.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: bootstrapDestination,
            dst_size: 0,
            src_ptr: UnsafePointer(bootstrapSource),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, operation, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        return data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return operation == COMPRESSION_STREAM_ENCODE ? Data() : nil
            }
            stream.src_ptr = source
            stream.src_size = data.count
            var result = Data()
            var output = [UInt8](repeating: 0, count: outputChunkSize)

            while true {
                let status: compression_status = output.withUnsafeMutableBufferPointer { buffer in
                    guard let destination = buffer.baseAddress else { return COMPRESSION_STATUS_ERROR }
                    stream.dst_ptr = destination
                    stream.dst_size = buffer.count
                    let flags = stream.src_size == 0
                        ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                        : 0
                    return compression_stream_process(&stream, flags)
                }
                let byteCount = output.count - stream.dst_size
                guard result.count <= maximumDecodedBytes - byteCount else { return nil }
                if byteCount > 0 {
                    result.append(contentsOf: output.prefix(byteCount))
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return result
                default:
                    return nil
                }
            }
        }
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
