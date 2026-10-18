import CloudKit
import Compression
import CryptoKit
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
    /// Set when the last upload attempt for this record failed for a reason
    /// that `CloudKitSyncWorker` does not already retry automatically
    /// (`.serverRecordChanged`/`.unknownItem`/`.zoneNotFound` re-queue
    /// themselves; every other error only used to log and stop). Reconcile
    /// re-queues any entry carrying this flag even when its digest matches
    /// the last attempt, since an unchanged digest only means "the content
    /// didn't change" — not "the previous upload succeeded".
    var needsRetry: Bool = false
    /// Set when a fetched remote change was accepted here but could not be
    /// applied to the local vault. Such an entry is absent from local
    /// snapshots for a reason other than a user deletion, so reconciliation
    /// must neither delete nor overwrite it until it applies successfully.
    var pendingLocalApply: Bool = false
    /// Record schema written by the sending client; nil means version 1.
    var schemaVersion: Int64? = nil

    /// Highest record schema this build can decode.
    static let supportedSchemaVersion: Int64 = 1

    /// LWW 时间：优先用实体编辑时间（不晚于现在），但不早于上次记录的时间，
    /// 避免未更新编辑时间的改动倒退（AUDIT-086(4)）。
    static func modifiedAt(editedAt: Date?, previous: CloudSyncStoredEntry?, now: Date) -> Date {
        guard let editedAt else { return now }
        let edited = min(editedAt, now)
        guard let previous, !previous.isDeleted else { return edited }
        return max(edited, previous.modifiedAt)
    }

    /// A record from a newer client is kept verbatim (payload plus
    /// `pendingLocalApply`) and never re-uploaded or deleted from here, so an
    /// older build cannot strip fields it does not know (AUDIT-030). After an
    /// upgrade the stored payload is applied by the normal pending-apply retry.
    var requiresNewerClient: Bool {
        (schemaVersion ?? 1) > Self.supportedSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, module, digest, modifiedAt, deviceID, isDeleted, payload
        case systemFields, needsRetry, pendingLocalApply, schemaVersion
    }

    init(
        kind: CloudSyncEntityKind,
        id: UUID,
        module: ToolModule? = nil,
        digest: Data? = nil,
        modifiedAt: Date,
        deviceID: String,
        isDeleted: Bool,
        payload: Data? = nil,
        systemFields: Data? = nil,
        needsRetry: Bool = false,
        pendingLocalApply: Bool = false,
        schemaVersion: Int64? = nil
    ) {
        self.kind = kind
        self.id = id
        self.module = module
        self.digest = digest
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.isDeleted = isDeleted
        self.payload = payload
        self.systemFields = systemFields
        self.needsRetry = needsRetry
        self.pendingLocalApply = pendingLocalApply
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(CloudSyncEntityKind.self, forKey: .kind)
        id = try container.decode(UUID.self, forKey: .id)
        module = try container.decodeIfPresent(ToolModule.self, forKey: .module)
        digest = try container.decodeIfPresent(Data.self, forKey: .digest)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        payload = try container.decodeIfPresent(Data.self, forKey: .payload)
        systemFields = try container.decodeIfPresent(Data.self, forKey: .systemFields)
        needsRetry = try container.decodeIfPresent(Bool.self, forKey: .needsRetry) ?? false
        pendingLocalApply = try container.decodeIfPresent(Bool.self, forKey: .pendingLocalApply) ?? false
        schemaVersion = try container.decodeIfPresent(Int64.self, forKey: .schemaVersion)
    }
}

/// Decides which CloudKit deletions a reconcile may send.
///
/// A record is only deleted when it was present locally before (never while a
/// remote change is still waiting to be applied). A sudden bulk deletion that
/// the user has not confirmed pauses all new deletions instead of propagating
/// what may be a failed local load or merge to every other device.
enum CloudSyncDeletionPlanner {
    static let minimumGuardedDeletions = 20
    static let maximumUnconfirmedFraction = 0.25

    struct Plan: Equatable {
        var keys: [String]
        /// Number of new deletions held back by the circuit breaker; zero when not paused.
        var pausedCount: Int
    }

    static func plan(
        entries: [String: CloudSyncStoredEntry],
        currentKeys: Set<String>,
        authorizedModules: Set<ToolModule>,
        allowsBulkDeletion: Bool,
        isActive: (String, CloudSyncStoredEntry) -> Bool
    ) -> Plan {
        let candidates = entries.filter { key, entry in
            isActive(key, entry)
                && !entry.pendingLocalApply
                && (!entry.isDeleted || entry.systemFields != nil)
                && !currentKeys.contains(key)
        }
        // Deletions already committed locally, attachments (owned by records)
        // and modules the user explicitly cleared never need confirmation.
        let unconfirmed = Set(candidates.filter { _, entry in
            guard !entry.isDeleted, entry.kind != .attachment else { return false }
            guard let module = entry.module ?? entry.kind.module else { return true }
            return !authorizedModules.contains(module)
        }.keys)
        let liveRecords = entries.filter { key, entry in
            !entry.isDeleted && entry.kind != .attachment && isActive(key, entry)
        }.count
        let tripped = !allowsBulkDeletion
            && unconfirmed.count >= minimumGuardedDeletions
            && Double(unconfirmed.count) > maximumUnconfirmedFraction * Double(liveRecords)
        guard tripped else {
            return Plan(keys: candidates.keys.sorted(), pausedCount: 0)
        }
        return Plan(
            keys: candidates.keys.filter { !unconfirmed.contains($0) }.sorted(),
            pausedCount: unconfirmed.count
        )
    }
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

    mutating func resetForAccountChange(accountRecordName: String?) {
        engineState = nil
        entries = [:]
        self.accountRecordName = accountRecordName
        reconciliationVersion = Self.currentReconciliationVersion
    }

    /// Rebuilds entries after the server zone was deleted (AUDIT-029).
    ///
    /// Uploaded entries drop their payload to save space, so re-queuing the
    /// cached keys alone would send nothing for them. Every local item gets
    /// its full payload back; cached payloads (inactive modules, remote changes
    /// still waiting to apply) are re-sent as they are. Records from a newer
    /// client are left for that client to restore.
    ///
    /// - Returns: The keys to save into the recreated zone.
    mutating func prepareForRecreatedZone(localItems: [CloudSyncItem], now: Date) -> [String] {
        var rebuilt = Set<String>()
        for item in localItems {
            let previous = entries[item.key]
            if previous?.pendingLocalApply == true || previous?.requiresNewerClient == true { continue }
            let digest = Data(SHA256.hash(data: item.payload))
            let unchanged = previous.map { !$0.isDeleted && $0.digest == digest } ?? false
            entries[item.key] = CloudSyncStoredEntry(
                kind: item.kind,
                id: item.id,
                module: item.module ?? previous?.module,
                digest: digest,
                modifiedAt: unchanged ? previous?.modifiedAt ?? now : now,
                deviceID: unchanged ? previous?.deviceID ?? deviceID : deviceID,
                isDeleted: false,
                payload: item.payload
            )
            rebuilt.insert(item.key)
        }
        var keys = rebuilt
        for (key, entry) in entries where !rebuilt.contains(key) {
            // The zone is gone, so old change tags would only cause conflicts.
            entries[key]?.systemFields = nil
            if !entry.isDeleted, entry.payload != nil, !entry.requiresNewerClient {
                keys.insert(key)
            }
        }
        return keys.sorted()
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

    enum LoadError: Error {
        case undecodable
    }

    /// Only a missing file starts from an empty document. A file that exists but
    /// cannot be read throws: an empty document would forget local deletions and
    /// let them come back from iCloud (AUDIT-086(1)).
    func load() throws -> CloudSyncStoredDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CloudSyncStoredDocument()
        }
        do {
            let storedData = try Data(contentsOf: fileURL)
            guard let data = CloudSyncStateFileCodec.decode(storedData) else {
                cloudSyncLogger.error("Unable to decompress cloud sync state")
                throw LoadError.undecodable
            }
            return try JSONDecoder().decode(
                CloudSyncStoredDocument.self,
                from: data
            )
        } catch {
            cloudSyncLogger.error(
                "Unable to decode cloud sync state: \(DiagnosticLogger.errorCode(error), privacy: .public)"
            )
            throw error
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
