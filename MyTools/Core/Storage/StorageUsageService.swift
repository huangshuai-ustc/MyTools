import Foundation

struct StorageUsageSnapshot: Sendable, Equatable {
    let localVaultBytes: Int64
    let attachmentsBytes: Int64
    let attachmentCount: Int
    let cloudSyncStateBytes: Int64
    let localCacheBytes: Int64
    let systemCloudKitCacheBytes: Int64
    let diagnosticsBytes: Int64
    let otherBytes: Int64

    /// Bytes owned by the app and eligible for the app's cleanup controls.
    /// The system CloudKit cache is intentionally excluded because Apple
    /// owns its lifecycle and the app cannot safely delete it.
    var managedBytes: Int64 {
        totalBytes - systemCloudKitCacheBytes
    }

    var totalBytes: Int64 {
        localVaultBytes
            + attachmentsBytes
            + cloudSyncStateBytes
            + localCacheBytes
            + systemCloudKitCacheBytes
            + diagnosticsBytes
            + otherBytes
    }
}

struct OrphanAttachmentInfo: Identifiable, Sendable, Equatable {
    let storedFileName: String
    let byteCount: Int64

    var id: String { storedFileName }
}

struct MissingAttachmentInfo: Identifiable, Sendable, Equatable {
    let storedFileName: String

    var id: String { storedFileName }
}

struct StorageScanResult: Sendable, Equatable {
    let usage: StorageUsageSnapshot
    let orphanAttachments: [OrphanAttachmentInfo]
    let missingAttachments: [MissingAttachmentInfo]
}

final class StorageUsageService: @unchecked Sendable {
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private let cachesDirectory: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        cachesDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.cachesDirectory = cachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    private var appDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("MyTools", isDirectory: true)
    }

    private var localVaultURL: URL {
        appDirectory.appendingPathComponent("local-vault.json", isDirectory: false)
    }

    private var attachmentsDirectory: URL {
        appDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    private var diagnosticsDirectory: URL {
        appDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var diagnosticsURL: URL {
        diagnosticsDirectory.appendingPathComponent("MyTools-Diagnostics.log", isDirectory: false)
    }

    private var cloudSyncStateURL: URL {
        appDirectory.appendingPathComponent("cloud-sync-state.json", isDirectory: false)
    }

    private var stockChartsDirectory: URL {
        appDirectory.appendingPathComponent("StockCharts", isDirectory: true)
    }

    private var sportsLotteryCacheURL: URL {
        appDirectory.appendingPathComponent("sports-lottery-cache-v1.json", isDirectory: false)
    }

    private var appCachesDirectory: URL {
        cachesDirectory.appendingPathComponent("MyTools", isDirectory: true)
    }

    private var cloudKitCachesDirectory: URL {
        cachesDirectory.appendingPathComponent("CloudKit", isDirectory: true)
    }

    func scan(referencedStoredFileNames: Set<String>) throws -> StorageScanResult {
        let attachmentFiles = try regularFiles(in: attachmentsDirectory)
        let storedFileNames = Set(attachmentFiles.map(\.lastPathComponent))
        let orphanAttachments = attachmentFiles
            .filter { !referencedStoredFileNames.contains($0.lastPathComponent) }
            .compactMap { fileURL -> OrphanAttachmentInfo? in
                guard let byteCount = fileSize(at: fileURL) else { return nil }
                return OrphanAttachmentInfo(
                    storedFileName: fileURL.lastPathComponent,
                    byteCount: byteCount
                )
            }
            .sorted { $0.storedFileName < $1.storedFileName }
        let missingAttachments = referencedStoredFileNames
            .filter { !storedFileNames.contains($0) }
            .sorted()
            .map(MissingAttachmentInfo.init(storedFileName:))

        let attachmentsBytes = attachmentFiles.reduce(Int64.zero) { total, fileURL in
            total + (fileSize(at: fileURL) ?? 0)
        }
        let localCacheBytes = (try directorySize(at: stockChartsDirectory))
            + (try directorySize(at: appCachesDirectory))
            + (fileSize(at: sportsLotteryCacheURL) ?? 0)
        let otherBytes = try otherApplicationSupportBytes()
        let usage = StorageUsageSnapshot(
            localVaultBytes: fileSize(at: localVaultURL) ?? 0,
            attachmentsBytes: attachmentsBytes,
            attachmentCount: attachmentFiles.count,
            cloudSyncStateBytes: fileSize(at: cloudSyncStateURL) ?? 0,
            localCacheBytes: localCacheBytes,
            systemCloudKitCacheBytes: try directorySize(at: cloudKitCachesDirectory),
            diagnosticsBytes: fileSize(at: diagnosticsURL) ?? 0,
            otherBytes: otherBytes
        )
        return StorageScanResult(
            usage: usage,
            orphanAttachments: orphanAttachments,
            missingAttachments: missingAttachments
        )
    }

    @discardableResult
    func deleteOrphans(_ orphans: [OrphanAttachmentInfo]) throws -> Int64 {
        guard !orphans.isEmpty else { return 0 }
        let names = Set(orphans.map(\.storedFileName))
        var removedBytes: Int64 = 0
        for fileURL in try regularFiles(in: attachmentsDirectory)
        where names.contains(fileURL.lastPathComponent) {
            removedBytes += fileSize(at: fileURL) ?? 0
            try fileManager.removeItem(at: fileURL)
        }
        return removedBytes
    }

    private func regularFiles(in directoryURL: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isRegularFile == true
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else { return nil }
        return Int64(fileSize)
    }

    private func otherApplicationSupportBytes() throws -> Int64 {
        guard fileManager.fileExists(atPath: appDirectory.path) else { return 0 }
        let excludedNames = Set([
            localVaultURL.lastPathComponent,
            attachmentsDirectory.lastPathComponent,
            diagnosticsDirectory.lastPathComponent,
            cloudSyncStateURL.lastPathComponent,
            stockChartsDirectory.lastPathComponent,
            sportsLotteryCacheURL.lastPathComponent
        ])
        return try fileManager.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { !excludedNames.contains($0.lastPathComponent) }
            .reduce(Int64.zero) { total, url in
                total + (isDirectory(url) ? (try? directorySize(at: url)) ?? 0 : fileSize(at: url) ?? 0)
            }
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
        return values.isDirectory == true
    }

    private func directorySize(at directoryURL: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
