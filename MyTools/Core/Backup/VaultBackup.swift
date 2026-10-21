import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

enum VaultBackupError: LocalizedError, Equatable {
    case invalidPassword
    case missingPassword
    case invalidFile
    case unsupportedVersion
    case wrongPassword
    case moduleUnavailable
    case localVaultUnavailable
    case invalidStockHoldings(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "备份密码至少需要 8 位。"
        case .missingPassword:
            return "请输入备份密码。"
        case .invalidFile:
            return "文件不是有效的“\(AppMetadata.appName)”备份。"
        case .unsupportedVersion:
            return "此备份版本不是当前支持的 1.0、2.0 或 3.0，无法导入。"
        case .wrongPassword:
            return "备份密码错误，无法解密文件。"
        case .moduleUnavailable:
            return "所选模块有未能读取的数据，不能将其导出为空备份。原始资料已保留。"
        case .localVaultUnavailable:
            return "本地档案尚未成功读取，暂不能导入备份，以免覆盖原文件。请先重试读取本地档案。"
        case .invalidStockHoldings(let count):
            return "备份中有 \(count) 只股票的交易顺序会导致负持仓，已取消导入，本地数据未改动。"
        }
    }
}

struct VaultBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.myToolsBackup] }
    static var writableContentTypes: [UTType] { [.myToolsBackup] }

    let data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw VaultBackupError.invalidFile
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static var myToolsBackup: UTType {
        UTType(exportedAs: AppMetadata.backupTypeIdentifier, conformingTo: .data)
    }
}

struct VaultBackupPayload: Codable, @unchecked Sendable {
    var vault: VaultData
    var secrets: [SecretVaultValue]
    var includedModules: Set<ToolModule>
    /// Attachment bytes by attachment id. Since 3.0 they are stored as raw
    /// blobs after the JSON payload instead of base64 `backupData` inside it.
    var attachmentData: [UUID: Data] = [:]

    private enum CodingKeys: String, CodingKey {
        case vault, secrets, includedModules
    }

    init(
        vault: VaultData,
        secrets: [SecretVaultValue] = [],
        includedModules: Set<ToolModule> = ToolModuleCatalog.backupModules,
        attachmentData: [UUID: Data] = [:]
    ) {
        self.vault = vault
        self.secrets = secrets
        self.includedModules = includedModules
        self.attachmentData = attachmentData
    }
}

enum VaultBackupCrypto {
    private static let format = "mytools-vault"
    /// 3.0 is binary, so neither the ciphertext nor the attachments are base64
    /// encoded: a header (magic, version, PBKDF2 rounds, salt) bound as AES-GCM
    /// AAD, followed by the combined box. Its plaintext is the JSON payload
    /// followed by raw attachment blobs.
    /// 2.0 (JSON envelope, rounds bound as AAD) and 1.0 (fixed 210,000 rounds,
    /// no AAD) backups remain importable.
    static let version = "3.0"
    private static let jsonVersion = "2.0"
    private static let legacyVersion = "1.0"
    private static let magic = Data("MTVB".utf8)
    private static let binaryVersion: UInt8 = 3
    private static let saltLength = 16
    private static let keyLength = 32
    static let rounds: UInt32 = 600_000
    private static let legacyRounds: UInt32 = 210_000
    /// Bounds for rounds read from a file, so a crafted backup cannot stall the import.
    private static let acceptedRounds: ClosedRange<UInt32> = 100_000...10_000_000

    private struct Envelope: Codable {
        let format: String
        let version: String
        let rounds: UInt32?
        let salt: Data
        let combined: Data
    }

    private static func authenticatedData(version: String, rounds: UInt32) -> Data {
        Data("\(format)|\(version)|\(rounds)".utf8)
    }

    static func makeBackup(
        from vault: VaultData,
        secrets: [SecretVaultValue] = [],
        includedModules: Set<ToolModule> = ToolModuleCatalog.backupModules,
        attachmentData: [UUID: Data] = [:],
        password: String
    ) throws -> Data {
        guard password.count >= 8 else { throw VaultBackupError.invalidPassword }

        let salt = randomBytes(count: saltLength)
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let payload = try JSONEncoder().encode(
            VaultBackupPayload(vault: vault, secrets: secrets, includedModules: includedModules)
        )
        var plaintext = Data()
        plaintext.appendBigEndian(UInt64(payload.count))
        plaintext.append(payload)
        plaintext.appendBigEndian(UInt32(attachmentData.count))
        for (id, data) in attachmentData.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            plaintext.append(withUnsafeBytes(of: id.uuid) { Data($0) })
            plaintext.appendBigEndian(UInt64(data.count))
            plaintext.append(data)
        }

        var header = magic
        header.append(binaryVersion)
        header.appendBigEndian(rounds)
        header.append(salt)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw VaultBackupError.invalidFile }
        return header + combined
    }

    static func restorePayload(from data: Data, password: String) throws -> VaultBackupPayload {
        guard password.count >= 8 else { throw VaultBackupError.invalidPassword }
        if data.starts(with: magic) {
            return try restoreBinaryPayload(from: data, password: password)
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw VaultBackupError.invalidFile
        }
        guard envelope.format == format else { throw VaultBackupError.invalidFile }
        let rounds: UInt32
        let aad: Data?
        switch envelope.version {
        case legacyVersion:
            rounds = legacyRounds
            aad = nil
        case jsonVersion:
            guard let stored = envelope.rounds, acceptedRounds.contains(stored) else {
                throw VaultBackupError.invalidFile
            }
            rounds = stored
            aad = authenticatedData(version: jsonVersion, rounds: stored)
        default:
            throw VaultBackupError.unsupportedVersion
        }

        let key = try deriveKey(password: password, salt: envelope.salt, rounds: rounds)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: envelope.combined)
        } catch {
            throw VaultBackupError.invalidFile
        }

        let payload: Data
        do {
            payload = try aad.map { try AES.GCM.open(sealed, using: key, authenticating: $0) }
                ?? AES.GCM.open(sealed, using: key)
        } catch {
            throw VaultBackupError.wrongPassword
        }

        do {
            return try JSONDecoder().decode(VaultBackupPayload.self, from: payload)
        } catch {
            throw VaultBackupError.invalidFile
        }
    }

    private static func restoreBinaryPayload(from data: Data, password: String) throws -> VaultBackupPayload {
        var reader = BackupBinaryReader(data: data)
        guard reader.read(count: magic.count) != nil, let fileVersion = reader.readByte() else {
            throw VaultBackupError.invalidFile
        }
        guard fileVersion == binaryVersion else { throw VaultBackupError.unsupportedVersion }
        guard let rounds = reader.readUInt32(), acceptedRounds.contains(rounds),
              let salt = reader.read(count: saltLength) else {
            throw VaultBackupError.invalidFile
        }
        let header = data.prefix(reader.offset)
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: reader.remaining())
        } catch {
            throw VaultBackupError.invalidFile
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: key, authenticating: header)
        } catch {
            throw VaultBackupError.wrongPassword
        }

        var content = BackupBinaryReader(data: plaintext)
        guard let payloadLength = content.readUInt64(),
              let payloadData = content.read(count: payloadLength),
              let blobCount = content.readUInt32() else {
            throw VaultBackupError.invalidFile
        }
        var attachmentData: [UUID: Data] = [:]
        for _ in 0..<blobCount {
            guard let idBytes = content.read(count: 16),
                  let length = content.readUInt64(),
                  let blob = content.read(count: length) else {
                throw VaultBackupError.invalidFile
            }
            let id = idBytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            attachmentData[id] = blob
        }
        guard content.isAtEnd else { throw VaultBackupError.invalidFile }
        do {
            var payload = try JSONDecoder().decode(VaultBackupPayload.self, from: payloadData)
            payload.attachmentData = attachmentData
            return payload
        } catch {
            throw VaultBackupError.invalidFile
        }
    }

    private static func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func deriveKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        do {
            let derived = try VaultCrypto.pbkdf2SHA256(
                password: Data(password.utf8),
                salt: salt,
                rounds: rounds,
                keyLength: keyLength
            )
            return SymmetricKey(data: derived)
        } catch {
            throw VaultBackupError.invalidFile
        }
    }
}

private extension Data {
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// Bounds-checked reader for the 3.0 binary layout; every read returns nil
/// instead of trapping when a crafted file declares more bytes than it has.
private struct BackupBinaryReader {
    let data: Data
    private(set) var offset = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func read<Length: FixedWidthInteger>(count: Length) -> Data? {
        guard count >= 0, UInt64(count) <= UInt64(data.count - offset) else { return nil }
        let start = data.startIndex + offset
        offset += Int(count)
        return Data(data[start..<(start + Int(count))])
    }

    mutating func readByte() -> UInt8? {
        read(count: 1)?.first
    }

    mutating func readUInt32() -> UInt32? {
        readInteger()
    }

    mutating func readUInt64() -> UInt64? {
        readInteger()
    }

    mutating func remaining() -> Data {
        read(count: data.count - offset) ?? Data()
    }

    private mutating func readInteger<Value: FixedWidthInteger>() -> Value? {
        guard let bytes = read(count: MemoryLayout<Value>.size) else { return nil }
        return bytes.reduce(Value.zero) { ($0 << 8) | Value($1) }
    }
}
