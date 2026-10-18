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
            return "此备份版本不是当前支持的 1.0 或 2.0，无法导入。"
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

    init(
        vault: VaultData,
        secrets: [SecretVaultValue] = [],
        includedModules: Set<ToolModule> = ToolModuleCatalog.backupModules
    ) {
        self.vault = vault
        self.secrets = secrets
        self.includedModules = includedModules
    }
}

enum VaultBackupCrypto {
    private static let format = "mytools-vault"
    /// 2.0 records the PBKDF2 rounds in the envelope and binds the header as AES-GCM AAD.
    /// 1.0 backups (fixed 210,000 rounds, no AAD) remain importable.
    static let version = "2.0"
    private static let legacyVersion = "1.0"
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
        password: String
    ) throws -> Data {
        guard password.count >= 8 else { throw VaultBackupError.invalidPassword }

        let salt = randomBytes(count: saltLength)
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let payload = try JSONEncoder().encode(
            VaultBackupPayload(vault: vault, secrets: secrets, includedModules: includedModules)
        )
        let sealed = try AES.GCM.seal(
            payload, using: key, authenticating: authenticatedData(version: version, rounds: rounds)
        )
        guard let combined = sealed.combined else { throw VaultBackupError.invalidFile }

        let envelope = Envelope(
            format: format, version: version, rounds: rounds, salt: salt, combined: combined
        )
        return try JSONEncoder().encode(envelope)
    }

    static func restorePayload(from data: Data, password: String) throws -> VaultBackupPayload {
        guard password.count >= 8 else { throw VaultBackupError.invalidPassword }

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
        case version:
            guard let stored = envelope.rounds, acceptedRounds.contains(stored) else {
                throw VaultBackupError.invalidFile
            }
            rounds = stored
            aad = authenticatedData(version: version, rounds: stored)
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
