#if MYTOOLS_FEATURE_DOCUMENTS
import Foundation

enum CredentialDocumentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case identityCard
    case passport
    case hongKongMacaoPermit
    case driversLicense
    case educationCertificate
    case degreeCertificate
    case propertyOwnershipCertificate
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .identityCard: return "身份证"
        case .passport: return "护照"
        case .hongKongMacaoPermit: return "港澳通行证"
        case .driversLicense: return "驾驶证"
        case .educationCertificate: return "学历证"
        case .degreeCertificate: return "学位证"
        case .propertyOwnershipCertificate: return "房产证"
        case .other: return "自定义"
        }
    }

    var systemImage: String {
        switch self {
        case .identityCard: return "person.text.rectangle"
        case .passport: return "globe.asia.australia.fill"
        case .hongKongMacaoPermit: return "airplane"
        case .driversLicense: return "car.fill"
        case .educationCertificate: return "graduationcap.fill"
        case .degreeCertificate: return "scroll.fill"
        case .propertyOwnershipCertificate: return "house.fill"
        case .other: return "doc.badge.gearshape"
        }
    }

    var defaultFields: [CredentialField] {
        switch self {
        case .identityCard:
            return [
                CredentialField(label: "性别", isSensitive: false),
                CredentialField(label: "民族", isSensitive: false),
                CredentialField(label: "住址", kind: .multiline)
            ]
        case .passport:
            return [
                CredentialField(label: "国籍", isSensitive: false),
                CredentialField(label: "出生地")
            ]
        case .hongKongMacaoPermit:
            return [
                CredentialField(label: "出生地"),
                CredentialField(label: "换证次数", isSensitive: false)
            ]
        case .driversLicense:
            return [
                CredentialField(label: "准驾车型", isSensitive: false),
                CredentialField(label: "档案编号"),
                CredentialField(label: "住址", kind: .multiline)
            ]
        case .educationCertificate:
            return [
                CredentialField(label: "学校", isSensitive: false),
                CredentialField(label: "专业", isSensitive: false),
                CredentialField(label: "学历层次", isSensitive: false),
                CredentialField(label: "学习形式", isSensitive: false)
            ]
        case .degreeCertificate:
            return [
                CredentialField(label: "授予单位", isSensitive: false),
                CredentialField(label: "学位类别", isSensitive: false),
                CredentialField(label: "专业", isSensitive: false)
            ]
        case .propertyOwnershipCertificate:
            return [
                CredentialField(label: "坐落", kind: .multiline),
                CredentialField(label: "不动产单元号"),
                CredentialField(label: "权利类型", isSensitive: false),
                CredentialField(label: "共有情况", isSensitive: false)
            ]
        case .other:
            return []
        }
    }
}

enum CredentialFieldKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case multiline

    var id: Self { self }
    var title: String { self == .text ? "单行文本" : "多行文本" }
}

struct CredentialField: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var label = ""
    var value = ""
    var kind: CredentialFieldKind = .text
    var isSensitive = true

    init(
        id: UUID = UUID(),
        label: String = "",
        value: String = "",
        kind: CredentialFieldKind = .text,
        isSensitive: Bool = true
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.kind = kind
        self.isSensitive = isSensitive
    }
}

enum CredentialAttachmentRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case front
    case back
    case insidePage
    case scan
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .front: return "正面"
        case .back: return "反面"
        case .insidePage: return "内页"
        case .scan: return "扫描件"
        case .other: return "其他"
        }
    }
}

struct CredentialAttachment: Identifiable, Codable, Equatable, Sendable {
    var file: FileAttachment
    var role: CredentialAttachmentRole = .other

    var id: UUID { file.id }
}

enum CredentialValidityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case unspecified
    case fiveYears
    case tenYears
    case twentyYears
    case dateRange
    case permanent

    var id: Self { self }

    var title: String {
        switch self {
        case .unspecified: return "暂不设置"
        case .fiveYears: return "五年"
        case .tenYears: return "十年"
        case .twentyYears: return "二十年"
        case .dateRange: return "固定期限"
        case .permanent: return "长期有效"
        }
    }

    var durationYears: Int? {
        switch self {
        case .fiveYears: return 5
        case .tenYears: return 10
        case .twentyYears: return 20
        case .unspecified, .dateRange, .permanent: return nil
        }
    }

    static let identityCardOptions: [Self] = [
        .fiveYears, .tenYears, .twentyYears, .permanent
    ]

    static let standardOptions: [Self] = [.unspecified, .dateRange, .permanent]

    static func identityCardTerm(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self? {
        for kind in [Self.fiveYears, .tenYears, .twentyYears] {
            guard let years = kind.durationYears,
                  let expected = calendar.date(byAdding: .year, value: years, to: startDate) else {
                continue
            }
            let difference = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: expected),
                to: calendar.startOfDay(for: endDate)
            ).day ?? .max
            if abs(difference) <= 1 { return kind }
        }
        return nil
    }
}

struct CredentialValidity: Codable, Equatable, Sendable {
    var kind: CredentialValidityKind = .unspecified
    var startDate: Date?
    var endDate: Date?

    mutating func normalize() {
        switch kind {
        case .unspecified:
            startDate = nil
            endDate = nil
        case .dateRange:
            break
        case .fiveYears, .tenYears, .twentyYears, .permanent:
            startDate = nil
            endDate = nil
        }
    }
}

enum CredentialVersionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case expired
    case lost
    case replaced
    case invalidated

    var id: Self { self }

    var title: String {
        switch self {
        case .normal: return "正常"
        case .expired: return "已过期"
        case .lost: return "已遗失"
        case .replaced: return "已换发"
        case .invalidated: return "已作废"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .expired: return "clock.badge.xmark.fill"
        case .lost: return "questionmark.folder.fill"
        case .replaced: return "arrow.triangle.2.circlepath.circle.fill"
        case .invalidated: return "xmark.octagon.fill"
        }
    }
}

struct CredentialExpiryReminder: Codable, Equatable, Sendable {
    static let dayOptions = [0, 7, 30, 60, 90, 180]

    var isEnabled = false
    var daysBefore = 30

    mutating func normalize() {
        if !Self.dayOptions.contains(daysBefore) {
            daysBefore = 30
        }
    }
}

enum CredentialValidityStatus: Equatable, Sendable {
    case unspecified
    case permanent
    case valid(daysRemaining: Int)
    case expiringSoon(daysRemaining: Int)
    case expired(daysElapsed: Int)

    var title: String {
        switch self {
        case .unspecified: return "未设置期限"
        case .permanent: return "长期有效"
        case .valid(let days): return "剩余 \(days) 天"
        case .expiringSoon(let days): return days == 0 ? "今日到期" : "\(days) 天后到期"
        case .expired(let days): return days == 0 ? "已到期" : "已过期 \(days) 天"
        }
    }

    var systemImage: String {
        switch self {
        case .unspecified: return "calendar.badge.questionmark"
        case .permanent: return "checkmark.seal.fill"
        case .valid: return "checkmark.circle.fill"
        case .expiringSoon: return "exclamationmark.triangle.fill"
        case .expired: return "xmark.octagon.fill"
        }
    }
}

struct CredentialDocument: Identifiable, Codable, Equatable, Sendable {
    static let expiringSoonDays = 90

    var id = UUID()
    var parentDocumentID: UUID?
    var versionStatus: CredentialVersionStatus = .normal
    var title = ""
    var type: CredentialDocumentType = .identityCard
    var customTypeName = ""
    var holderName = ""
    var documentNumber = ""
    var legacyDateOfBirth: Date?
    var issuingAuthority = ""
    var issuedAt: Date?
    var validity = CredentialValidity()
    var fields: [CredentialField] = CredentialDocumentType.identityCard.defaultFields
    var attachments: [CredentialAttachment] = []
    var tags: [String] = []
    var note = ""
    var expiryReminder = CredentialExpiryReminder()
    var createdAt = Date()
    var updatedAt = Date()

    init(
        id: UUID = UUID(),
        parentDocumentID: UUID? = nil,
        versionStatus: CredentialVersionStatus = .normal,
        title: String = "",
        type: CredentialDocumentType = .identityCard,
        customTypeName: String = "",
        holderName: String = "",
        documentNumber: String = "",
        legacyDateOfBirth: Date? = nil,
        issuingAuthority: String = "",
        issuedAt: Date? = nil,
        validity: CredentialValidity = CredentialValidity(),
        fields: [CredentialField]? = nil,
        attachments: [CredentialAttachment] = [],
        tags: [String] = [],
        note: String = "",
        expiryReminder: CredentialExpiryReminder = CredentialExpiryReminder(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.parentDocumentID = parentDocumentID
        self.versionStatus = versionStatus
        self.title = title
        self.type = type
        self.customTypeName = customTypeName
        self.holderName = holderName
        self.documentNumber = documentNumber
        self.legacyDateOfBirth = legacyDateOfBirth
        self.issuingAuthority = issuingAuthority
        self.issuedAt = issuedAt
        self.validity = validity
        self.fields = fields ?? type.defaultFields
        self.attachments = attachments
        self.tags = tags
        self.note = note
        self.expiryReminder = expiryReminder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(versionOf source: CredentialDocument) {
        self.init(
            parentDocumentID: source.rootDocumentID,
            title: source.title,
            type: source.type,
            customTypeName: source.customTypeName,
            holderName: source.holderName,
            legacyDateOfBirth: source.legacyDateOfBirth,
            issuingAuthority: source.issuingAuthority,
            fields: source.fields.map {
                CredentialField(
                    label: $0.label,
                    value: $0.value,
                    kind: $0.kind,
                    isSensitive: $0.isSensitive
                )
            },
            tags: source.tags
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentDocumentID
        case versionStatus
        case title
        case type
        case customTypeName
        case holderName
        case documentNumber
        case legacyDateOfBirth = "dateOfBirth"
        case issuingAuthority
        case issuedAt
        case validity
        case fields
        case attachments
        case tags
        case note
        case expiryReminder
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        parentDocumentID = try values.decodeIfPresent(UUID.self, forKey: .parentDocumentID)
        versionStatus = try values.decodeIfPresent(
            CredentialVersionStatus.self,
            forKey: .versionStatus
        ) ?? .normal
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try values.decodeIfPresent(CredentialDocumentType.self, forKey: .type) ?? .identityCard
        customTypeName = try values.decodeIfPresent(String.self, forKey: .customTypeName) ?? ""
        holderName = try values.decodeIfPresent(String.self, forKey: .holderName) ?? ""
        documentNumber = try values.decodeIfPresent(String.self, forKey: .documentNumber) ?? ""
        legacyDateOfBirth = try values.decodeIfPresent(Date.self, forKey: .legacyDateOfBirth)
        issuingAuthority = try values.decodeIfPresent(String.self, forKey: .issuingAuthority) ?? ""
        issuedAt = try values.decodeIfPresent(Date.self, forKey: .issuedAt)
        validity = try values.decodeIfPresent(CredentialValidity.self, forKey: .validity)
            ?? CredentialValidity()
        fields = try values.decodeIfPresent([CredentialField].self, forKey: .fields)
            ?? type.defaultFields
        attachments = try values.decodeIfPresent(
            [CredentialAttachment].self,
            forKey: .attachments
        ) ?? []
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        expiryReminder = try values.decodeIfPresent(
            CredentialExpiryReminder.self,
            forKey: .expiryReminder
        ) ?? CredentialExpiryReminder()
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var typeTitle: String {
        if type == .other {
            let custom = customTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? type.title : custom
        }
        return type.title
    }

    var displayTitle: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? typeTitle : name
    }

    var attachmentFiles: [FileAttachment] {
        attachments.map(\.file)
    }

    mutating func migrateLegacyDateOfBirthToCustomField() {
        guard let legacyDateOfBirth else { return }
        let value = AppDateFormatter.string(from: legacyDateOfBirth)
        if let index = fields.firstIndex(where: {
            $0.label.localizedCaseInsensitiveCompare("出生日期") == .orderedSame
        }) {
            let existingValue = fields[index].value.trimmingCharacters(in: .whitespacesAndNewlines)
            if existingValue.isEmpty {
                fields[index].value = value
            } else if existingValue != value,
                      !fields.contains(where: {
                          $0.label == "出生日期（旧版）" && $0.value == value
                      }) {
                fields.append(CredentialField(label: "出生日期（旧版）", value: value))
            }
        } else {
            fields.append(CredentialField(label: "出生日期", value: value))
        }
        self.legacyDateOfBirth = nil
    }

    var rootDocumentID: UUID {
        parentDocumentID ?? id
    }

    var isVersion: Bool {
        parentDocumentID != nil
    }

    static func versionDisplayPrecedes(
        _ lhs: CredentialDocument,
        _ rhs: CredentialDocument
    ) -> Bool {
        switch (lhs.versionExpirationSortValue, rhs.versionExpirationSortValue) {
        case (.permanent, .permanent):
            break
        case (.permanent, _):
            return true
        case (_, .permanent):
            return false
        case (.date(let lhsDate), .date(let rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.date, .missing):
            return true
        case (.missing, .date):
            return false
        case (.date, .date), (.missing, .missing):
            break
        }

        let lhsIssuedAt = lhs.issuedAt ?? lhs.validity.startDate ?? lhs.createdAt
        let rhsIssuedAt = rhs.issuedAt ?? rhs.validity.startDate ?? rhs.createdAt
        if lhsIssuedAt != rhsIssuedAt { return lhsIssuedAt > rhsIssuedAt }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func preferredVersion(in documents: [CredentialDocument]) -> CredentialDocument? {
        documents.sorted(by: versionDisplayPrecedes).first
    }

    func expirationDate(calendar: Calendar = .autoupdatingCurrent) -> Date? {
        if let years = validity.kind.durationYears, let issuedAt {
            return calendar.date(byAdding: .year, value: years, to: issuedAt)
        }
        return validity.kind == .dateRange ? validity.endDate : nil
    }

    private enum VersionExpirationSortValue {
        case permanent
        case date(Date)
        case missing
    }

    private var versionExpirationSortValue: VersionExpirationSortValue {
        if validity.kind == .permanent { return .permanent }
        if let date = expirationDate() { return .date(date) }
        return .missing
    }

    func validityStatus(
        on date: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> CredentialValidityStatus {
        switch validity.kind {
        case .unspecified:
            return .unspecified
        case .permanent:
            return .permanent
        case .fiveYears, .tenYears, .twentyYears, .dateRange:
            guard let endDate = expirationDate(calendar: calendar) else { return .unspecified }
            let today = calendar.startOfDay(for: date)
            let expiryDay = calendar.startOfDay(for: endDate)
            let days = calendar.dateComponents([.day], from: today, to: expiryDay).day ?? 0
            if days < 0 {
                return .expired(daysElapsed: abs(days))
            }
            if days <= Self.expiringSoonDays {
                return .expiringSoon(daysRemaining: days)
            }
            return .valid(daysRemaining: days)
        }
    }

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return displayTitle.localizedCaseInsensitiveContains(term)
            || typeTitle.localizedCaseInsensitiveContains(term)
            || holderName.localizedCaseInsensitiveContains(term)
            || documentNumber.localizedCaseInsensitiveContains(term)
            || issuingAuthority.localizedCaseInsensitiveContains(term)
            || tags.contains { $0.localizedCaseInsensitiveContains(term) }
            || fields.contains {
                $0.label.localizedCaseInsensitiveContains(term)
                    || $0.value.localizedCaseInsensitiveContains(term)
            }
    }
}

#endif
