import Foundation

enum SecretCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case login
    case email
    case serviceToken
    case backupRecovery
    case softwareLicense
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .login: return "登录凭据"
        case .email: return "邮箱账户"
        case .serviceToken: return "服务令牌"
        case .backupRecovery: return "备份与恢复"
        case .softwareLicense: return "软件授权"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .login: return "person.badge.key.fill"
        case .email: return "envelope.badge.shield.half.filled"
        case .serviceToken: return "key.fill"
        case .backupRecovery: return "arrow.triangle.2.circlepath"
        case .softwareLicense: return "checkmark.seal.fill"
        case .other: return "lock.fill"
        }
    }

    var defaultFields: [SecretField] {
        switch self {
        case .login:
            return [
                SecretField(label: "用户名", kind: .username),
                SecretField(label: "密码", kind: .password)
            ]
        case .email:
            return [
                SecretField(label: "邮箱地址", kind: .email),
                SecretField(label: "登录密码", kind: .password),
                SecretField(label: "授权密码", kind: .password)
            ]
        case .serviceToken:
            return [
                SecretField(label: "Token", kind: .token),
                SecretField(label: "服务地址", kind: .url),
                SecretField(label: "有效期", kind: .date)
            ]
        case .backupRecovery:
            return [
                SecretField(label: "备份密钥", kind: .recoveryCode),
                SecretField(label: "身份验证器备份码", kind: .recoveryCode),
                SecretField(label: "恢复码", kind: .multiline)
            ]
        case .softwareLicense:
            return [
                SecretField(label: "授权姓名", kind: .text),
                SecretField(label: "授权邮箱", kind: .email),
                SecretField(label: "产品密钥", kind: .licenseKey)
            ]
        case .other:
            return [SecretField(label: "保密内容", kind: .password)]
        }
    }
}

enum SecretFieldKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case username
    case email
    case password
    case token
    case recoveryCode
    case licenseKey
    case url
    case date
    case multiline

    var id: Self { self }

    var title: String {
        switch self {
        case .text: return "文本"
        case .username: return "用户名"
        case .email: return "邮箱"
        case .password: return "密码"
        case .token: return "Token"
        case .recoveryCode: return "密钥/恢复码"
        case .licenseKey: return "许可证密钥"
        case .url: return "网址"
        case .date: return "日期"
        case .multiline: return "多行文本"
        }
    }

    var isMultiline: Bool {
        self == .multiline
    }

    var defaultIsSensitive: Bool {
        switch self {
        case .url, .date: return false
        default: return true
        }
    }
}

struct SecretField: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var label = ""
    var value = ""
    var kind: SecretFieldKind = .text
    var isSensitive = true

    init(
        id: UUID = UUID(),
        label: String = "",
        value: String = "",
        kind: SecretFieldKind = .text,
        isSensitive: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.kind = kind
        self.isSensitive = isSensitive ?? kind.defaultIsSensitive
    }
}

struct SecretItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var category: SecretCategory = .login
    var fields: [SecretField] = SecretCategory.login.defaultFields
    var attachments: [FileAttachment] = []
    var tags = ""
    var note = ""
    var createdAt = Date()
    var updatedAt = Date()

    init(
        id: UUID = UUID(),
        title: String = "",
        category: SecretCategory = .login,
        fields: [SecretField]? = nil,
        attachments: [FileAttachment] = [],
        tags: String = "",
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.fields = fields ?? category.defaultFields
        self.attachments = attachments
        self.tags = tags
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

}
