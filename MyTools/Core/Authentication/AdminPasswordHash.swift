import Foundation
import CryptoKit

/// 管理员密码加盐 PBKDF2 摘要。
///
/// 存储格式：`pbkdf2-sha256$<rounds>$<saltBase64>$<digestBase64>`。
/// 旧格式（无盐 SHA-256 十六进制，64 个字符）仍可验证：验证成功后由
/// `AuthManager` 立即迁移为加盐格式。摘要比较使用恒定时间比较，避免
/// 时序侧信道。
enum AdminPasswordHash {
    static let storedPrefix = "pbkdf2-sha256"
    private static let rounds: UInt32 = 210_000
    private static let saltLength = 16
    private static let keyLength = 32

    static func make(for password: String) -> String {
        let salt = (try? VaultCrypto.randomBytes(count: saltLength))
            ?? Data((0..<saltLength).map { _ in UInt8.random(in: 0...255) })
        let digest = derive(password: password, salt: salt)
        return [
            storedPrefix,
            String(rounds),
            salt.base64EncodedString(),
            digest.base64EncodedString(),
        ].joined(separator: "$")
    }

    static func verify(_ password: String, stored: String) -> Bool {
        if stored.hasPrefix("\(storedPrefix)$") {
            let components = stored.split(separator: "$", omittingEmptySubsequences: false)
            guard components.count == 4,
                  components[0] == storedPrefix,
                  components[1] == String(rounds),
                  let salt = Data(base64Encoded: String(components[2])),
                  let expected = Data(base64Encoded: String(components[3])) else {
                return false
            }
            let actual = derive(password: password, salt: salt)
            return constantTimeEqual(actual, expected)
        }

        // 旧格式：无盐 SHA-256 十六进制。
        let legacyDigest = SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return legacyDigest == stored
    }

    static func isLegacy(_ stored: String) -> Bool {
        !stored.hasPrefix("\(storedPrefix)$")
    }

    private static func derive(password: String, salt: Data) -> Data {
        // PBKDF2 在正常输入下不会失败；失败时返回空数据，校验自然不通过。
        (try? VaultCrypto.pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            rounds: rounds,
            keyLength: keyLength
        )) ?? Data()
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (lhsByte, rhsByte) in zip(lhs, rhs) {
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}
