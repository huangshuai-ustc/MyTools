import Foundation
import CryptoKit
import Security

enum VaultEncryptionKeyError: LocalizedError {
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainWriteFailed(let status):
            return "本地加密密钥写入系统安全存储失败（status=\(status)）。"
        }
    }
}

/// 本地 Vault 加密密钥提供者。生产实现把随机 256 位密钥保存在 Keychain，
/// 属性为 `WhenUnlockedThisDeviceOnly`：仅本机、不可迁移，符合"本地静态
/// 加密不跨设备"的语义。密钥丢失时档案不可读，只能通过 `.mytools` 加密
/// 备份恢复，因此导出备份流程是最终恢复路径。
protocol VaultEncryptionKeyProviding: Sendable {
    /// 读取已存在的密钥；不存在时返回 nil。Keychain 异常时抛出。
    func loadKey() throws -> SymmetricKey?
    /// 生成随机密钥并持久化。
    func createAndStoreKey() throws -> SymmetricKey
}

struct KeychainVaultEncryptionKey: VaultEncryptionKeyProviding {
    private let service: String
    private let account: String

    init(
        service: String = AppMetadata.bundleIdentifier,
        account: String = "local-vault-encryption-key-v1"
    ) {
        self.service = service
        self.account = account
    }

    func loadKey() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                DiagnosticLogger.shared.log(
                    .persistence,
                    "读取本地加密密钥失败 status=\(status)",
                    level: .warning
                )
            }
            return nil
        }
        return SymmetricKey(data: data)
    }

    func createAndStoreKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        var item = baseQuery
        item[kSecValueData as String] = keyData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultEncryptionKeyError.keychainWriteFailed(status)
        }
        return key
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
