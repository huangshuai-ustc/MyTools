#if MYTOOLS_FEATURE_SECRETS
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
                SecretField(label: "密码", kind: .password),
                SecretField(label: "URL", kind: .url)
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

enum SecretPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal
    case work

    var id: Self { self }

    var title: String {
        switch self {
        case .personal: return "个人"
        case .work: return "工作"
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
        true
    }
}

enum SecretFieldInputType: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case url
    case date

    var id: Self { self }

    var title: String {
        switch self {
        case .text: return "文本"
        case .date: return "日期"
        case .url: return "网址"
        }
    }

    init(kind: SecretFieldKind) {
        switch kind {
        case .date: self = .date
        case .url: self = .url
        default: self = .text
        }
    }
}

struct SecretField: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var label = ""
    var value = ""
    var kind: SecretFieldKind = .text
    var inputType: SecretFieldInputType = .text
    var isSensitive = true

    init(
        id: UUID = UUID(),
        label: String = "",
        value: String = "",
        kind: SecretFieldKind = .text,
        inputType: SecretFieldInputType? = nil,
        isSensitive: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.kind = kind
        self.inputType = inputType ?? SecretFieldInputType(kind: kind)
        self.isSensitive = isSensitive ?? kind.defaultIsSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, value, kind, inputType, isSensitive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(SecretFieldKind.self, forKey: .kind) ?? .text
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            value: try container.decodeIfPresent(String.self, forKey: .value) ?? "",
            kind: kind,
            inputType: try container.decodeIfPresent(SecretFieldInputType.self, forKey: .inputType)
                ?? SecretFieldInputType(kind: kind),
            isSensitive: try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? kind.defaultIsSensitive
        )
    }
}

struct SecretFieldTemplate: Codable, Equatable, Identifiable, Sendable {
    var category: SecretCategory
    var fields: [SecretField]

    var id: SecretCategory { category }

    static var defaultTemplates: [Self] {
        SecretCategory.allCases.map { Self(category: $0, fields: $0.defaultFields) }
    }

    func makeFields() -> [SecretField] {
        fields.map { field in
            SecretField(
                label: field.label,
                kind: field.kind,
                inputType: field.inputType,
                isSensitive: field.isSensitive
            )
        }
    }

    func normalized() -> Self {
        Self(
            category: category,
            fields: fields.map {
                SecretField(
                    label: $0.label,
                    kind: $0.kind,
                    inputType: $0.inputType,
                    isSensitive: $0.isSensitive
                )
            }
        )
    }
}

struct SecretItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var category: SecretCategory = .login
    var purpose: SecretPurpose = .personal
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
        purpose: SecretPurpose = .personal,
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
        self.purpose = purpose
        self.fields = fields ?? category.defaultFields
        self.attachments = attachments
        self.tags = tags
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case category
        case purpose
        case fields
        case attachments
        case tags
        case note
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        category = try container.decodeIfPresent(SecretCategory.self, forKey: .category) ?? .login
        purpose = try container.decodeIfPresent(SecretPurpose.self, forKey: .purpose) ?? .personal
        fields = try container.decodeIfPresent([SecretField].self, forKey: .fields)
            ?? category.defaultFields
        attachments = try container.decodeIfPresent([FileAttachment].self, forKey: .attachments) ?? []
        tags = try container.decodeIfPresent(String.self, forKey: .tags) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

}

#endif
