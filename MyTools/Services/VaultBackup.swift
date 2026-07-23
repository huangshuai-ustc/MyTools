import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import CommonCrypto

enum VaultBackupError: LocalizedError {
    case invalidPassword
    case invalidFile
    case unsupportedVersion
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "备份密码至少需要 8 位。"
        case .invalidFile:
            return "文件不是有效的“我的工具箱”备份。"
        case .unsupportedVersion:
            return "此备份来自更新版本，当前版本无法导入。"
        case .wrongPassword:
            return "备份密码错误，无法解密文件。"
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
        UTType(exportedAs: "com.fjwyz.mytools.backup", conformingTo: .data)
    }
}

enum VaultBackupCrypto {
    private static let format = "mytools-vault"
    private static let version = 2
    private static let saltLength = 16
    private static let keyLength = 32
    private static let rounds: UInt32 = 210_000

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let salt: Data
        let combined: Data
    }

    static func makeBackup(from vault: VaultData, password: String) throws -> Data {
        guard password.count >= 8 else { throw VaultBackupError.invalidPassword }

        let salt = randomBytes(count: saltLength)
        let key = try deriveKey(password: password, salt: salt)
        let payload = try JSONEncoder().encode(vault)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw VaultBackupError.invalidFile }

        let envelope = Envelope(format: format, version: version, salt: salt, combined: combined)
        return try JSONEncoder().encode(envelope)
    }

    static func restoreVault(from data: Data, password: String) throws -> VaultData {
        guard password.count >= 8 else { throw VaultBackupError.invalidPassword }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw VaultBackupError.invalidFile
        }
        guard envelope.format == format else { throw VaultBackupError.invalidFile }
        guard (1...version).contains(envelope.version) else { throw VaultBackupError.unsupportedVersion }

        let key = try deriveKey(password: password, salt: envelope.salt)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: envelope.combined)
        } catch {
            throw VaultBackupError.invalidFile
        }

        let payload: Data
        do {
            payload = try AES.GCM.open(sealed, using: key)
        } catch {
            throw VaultBackupError.wrongPassword
        }

        do {
            return try JSONDecoder().decode(VaultData.self, from: payload)
        } catch {
            throw VaultBackupError.invalidFile
        }
    }

    private static func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(repeating: 0, count: keyLength)
        let derivedLength = derived.count
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: UInt8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultBackupError.invalidFile }
        return SymmetricKey(data: derived)
    }
}
