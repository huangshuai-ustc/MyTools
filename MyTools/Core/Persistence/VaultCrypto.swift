import Foundation
import CryptoKit
import Security
import CommonCrypto

enum VaultCryptoError: LocalizedError {
    case invalidFormat
    case unsupportedVersion
    case authenticationFailed
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "本地存档不是有效的加密格式。"
        case .unsupportedVersion:
            return "本地存档使用了当前版本不支持的加密格式。"
        case .authenticationFailed:
            return "本地存档解密失败（密钥不匹配或内容被篡改）。"
        case .keyDerivationFailed:
            return "加密密钥派生或随机数生成失败。"
        }
    }
}

/// 本地 Vault 静态加密信封与基础密码学原语。
///
/// 信封格式：`{format: "mytools-vault", version: "2.0", combined: <AES-GCM sealed>}`。
/// `combined` 已包含 nonce、密文和认证标签，不需要单独保存 nonce。
/// PBKDF2-HMAC-SHA256 派生同时供加密备份（`VaultBackupCrypto`）和管理员密码
/// 摘要（`AdminPasswordHash`）复用，避免维护第二套派生实现。
enum VaultCrypto {
    static let envelopeFormat = "mytools-vault"
    static let encryptedVersion = "2.0"

    private struct Envelope: Codable {
        let format: String
        let version: String
        let combined: Data
    }

    static func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw VaultCryptoError.invalidFormat }
        return try JSONEncoder().encode(
            Envelope(format: envelopeFormat, version: encryptedVersion, combined: combined)
        )
    }

    static func decrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw VaultCryptoError.invalidFormat
        }
        guard envelope.format == envelopeFormat else { throw VaultCryptoError.invalidFormat }
        guard envelope.version == encryptedVersion else { throw VaultCryptoError.unsupportedVersion }
        guard let sealed = try? AES.GCM.SealedBox(combined: envelope.combined) else {
            throw VaultCryptoError.invalidFormat
        }
        do {
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    /// 判断内容是否为当前格式的加密信封；用于区分旧版明文档案与加密档案。
    static func isEncryptedEnvelope(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return false
        }
        return envelope.format == envelopeFormat
    }

    /// PBKDF2-HMAC-SHA256 密钥派生。
    static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        rounds: UInt32,
        keyLength: Int
    ) throws -> Data {
        var derived = Data(repeating: 0, count: keyLength)
        let derivedLength = derived.count
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: UInt8.self).baseAddress,
                        password.count,
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
        guard status == kCCSuccess else { throw VaultCryptoError.keyDerivationFailed }
        return derived
    }

    /// 使用系统安全随机源生成随机字节。
    static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            SecRandomCopyBytes(kSecRandomDefault, rawBuffer.count, rawBuffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw VaultCryptoError.keyDerivationFailed }
        return bytes
    }
}
