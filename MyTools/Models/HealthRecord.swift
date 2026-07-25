import Foundation
import UniformTypeIdentifiers

protocol ToolEvent: Identifiable, Codable {
    var id: UUID { get set }
    var date: Date { get set }
    var tags: [String] { get set }
    var notes: String { get set }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
}

enum MedicalVisitType: String, Codable, CaseIterable, Identifiable {
    case outpatient
    case emergency
    case inpatient
    case pharmacyPurchase

    var id: Self { self }

    var title: String {
        switch self {
        case .outpatient: return "门诊"
        case .emergency: return "急诊"
        case .inpatient: return "住院"
        case .pharmacyPurchase: return "药房购药"
        }
    }

    var shortTitle: String {
        self == .pharmacyPurchase ? "购药" : title
    }
}

enum HospitalLevel: String, Codable, CaseIterable, Identifiable {
    case unspecified
    case levelOne
    case levelTwo
    case levelThree

    var id: Self { self }

    var title: String {
        switch self {
        case .unspecified: return "未设置"
        case .levelOne: return "一级"
        case .levelTwo: return "二级"
        case .levelThree: return "三级"
        }
    }
}

enum HospitalGrade: String, Codable, CaseIterable, Identifiable {
    case unspecified
    case classA
    case classB
    case classC

    var id: Self { self }

    var title: String {
        switch self {
        case .unspecified: return "未设置"
        case .classA: return "甲等"
        case .classB: return "乙等"
        case .classC: return "丙等"
        }
    }
}

enum HospitalCategory: String, Codable, CaseIterable, Identifiable {
    case unspecified
    case general
    case specialized

    var id: Self { self }

    var title: String {
        switch self {
        case .unspecified: return "未设置"
        case .general: return "综合医院"
        case .specialized: return "专科医院"
        }
    }
}

struct HospitalProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var level: HospitalLevel = .unspecified
    var grade: HospitalGrade = .unspecified
    var category: HospitalCategory = .unspecified
    var createdAt = Date()
    var updatedAt = Date()

    var classificationTitles: [String] {
        [
            level == .unspecified ? nil : level.title,
            grade == .unspecified ? nil : grade.title,
            category == .unspecified ? nil : category.title
        ].compactMap { $0 }
    }
}

enum MedicalPaymentMethod: String, Codable, CaseIterable, Identifiable {
    case medicalInsurance
    case selfPay
    case medicalInsuranceThenSelfPay

    var id: Self { self }

    var title: String {
        switch self {
        case .medicalInsurance: return "医保"
        case .selfPay: return "自费"
        case .medicalInsuranceThenSelfPay: return "医保后自费"
        }
    }
}

struct MedicalExpenseItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var quantity: Decimal
    var unit: String
    var amount: Decimal
    var note: String

    private enum CodingKeys: String, CodingKey {
        case id, name, quantity, unit, amount, note
        case medicine, specification, frequency, dose, duration, remark
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        quantity: Decimal = 0,
        unit: String = "",
        amount: Decimal = 0,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.amount = amount
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        if values.contains(.name) {
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
            quantity = try values.decodeIfPresent(Decimal.self, forKey: .quantity) ?? 0
            unit = try values.decodeIfPresent(String.self, forKey: .unit) ?? ""
            amount = try values.decodeIfPresent(Decimal.self, forKey: .amount) ?? 0
            note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
            return
        }

        name = try values.decodeIfPresent(String.self, forKey: .medicine) ?? ""
        quantity = 0
        unit = ""
        amount = 0
        let legacyDetails = [
            Self.labeledLegacyValue("规格", try values.decodeIfPresent(String.self, forKey: .specification)),
            Self.labeledLegacyValue("频率", try values.decodeIfPresent(String.self, forKey: .frequency)),
            Self.labeledLegacyValue("每次用量", try values.decodeIfPresent(String.self, forKey: .dose)),
            Self.labeledLegacyValue("疗程", try values.decodeIfPresent(String.self, forKey: .duration)),
            try values.decodeIfPresent(String.self, forKey: .remark) ?? ""
        ]
        note = legacyDetails.filter { !$0.isEmpty }.joined(separator: "；")
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(quantity, forKey: .quantity)
        try values.encode(unit, forKey: .unit)
        try values.encode(amount, forKey: .amount)
        try values.encode(note, forKey: .note)
    }

    private static func labeledLegacyValue(_ label: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return "\(label)：\(value)"
    }
}

enum AttachmentKind: String, Codable, CaseIterable, Identifiable {
    case invoice
    case medicalRecord
    case laboratoryReport
    case ct
    case mri
    case xray
    case testSheet
    case scan
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .invoice: return "发票"
        case .medicalRecord: return "病历"
        case .laboratoryReport: return "检验报告"
        case .ct: return "CT"
        case .mri: return "MRI"
        case .xray: return "X 光"
        case .testSheet: return "化验单"
        case .scan: return "扫描件"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .invoice: return "receipt"
        case .medicalRecord: return "doc.text"
        case .laboratoryReport, .testSheet: return "cross.vial"
        case .ct, .mri, .xray: return "waveform.path.ecg.rectangle"
        case .scan: return "doc.viewfinder"
        case .other: return "paperclip"
        }
    }
}

struct FileAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName = ""
    var storedFileName = ""
    var contentTypeIdentifier = UTType.data.identifier
    var kind: AttachmentKind = .other
    var createdAt = Date()
    var fileSize: Int64 = 0
    var backupData: Data?

    var contentType: UTType {
        UTType(contentTypeIdentifier) ?? .data
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct MedicalRecord: ToolEvent, Equatable {
    var id = UUID()
    var parentRecordID: UUID?
    var date = Date()
    var hospital = ""
    var hospitalLevel: HospitalLevel = .unspecified
    var hospitalGrade: HospitalGrade = .unspecified
    var hospitalCategory: HospitalCategory = .unspecified
    var department = ""
    var doctor = ""
    var visitType: MedicalVisitType = .outpatient
    var chiefComplaint = ""
    var diagnosis = ""
    var treatment = ""
    var totalCost: Decimal = 0
    var insuranceCost: Decimal = 0
    var selfPayCost: Decimal = 0
    var paymentMethod: MedicalPaymentMethod = .medicalInsuranceThenSelfPay
    var expenseItems: [MedicalExpenseItem] = []
    var attachments: [FileAttachment] = []
    var tags: [String] = []
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    private enum CodingKeys: String, CodingKey {
        case id, parentRecordID, date, hospital, hospitalLevel, hospitalGrade, hospitalCategory
        case department, doctor, visitType
        case chiefComplaint, diagnosis, treatment
        case totalCost, insuranceCost, selfPayCost, paymentMethod
        case expenseItems = "prescriptions"
        case attachments, tags, notes, createdAt, updatedAt
    }

    init() {}

    init(followUpTo parent: MedicalRecord, date: Date = Date()) {
        parentRecordID = parent.parentRecordID ?? parent.id
        self.date = Self.normalizedDate(date)
        hospital = parent.hospital
        hospitalLevel = parent.hospitalLevel
        hospitalGrade = parent.hospitalGrade
        hospitalCategory = parent.hospitalCategory
        department = parent.department
        doctor = parent.doctor
        visitType = parent.visitType
        tags = parent.tags
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        parentRecordID = try values.decodeIfPresent(UUID.self, forKey: .parentRecordID)
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        hospital = try values.decodeIfPresent(String.self, forKey: .hospital) ?? ""
        hospitalLevel = try values.decodeIfPresent(HospitalLevel.self, forKey: .hospitalLevel) ?? .unspecified
        hospitalGrade = try values.decodeIfPresent(HospitalGrade.self, forKey: .hospitalGrade) ?? .unspecified
        hospitalCategory = try values.decodeIfPresent(HospitalCategory.self, forKey: .hospitalCategory) ?? .unspecified
        department = try values.decodeIfPresent(String.self, forKey: .department) ?? ""
        doctor = try values.decodeIfPresent(String.self, forKey: .doctor) ?? ""
        visitType = try values.decodeIfPresent(MedicalVisitType.self, forKey: .visitType) ?? .outpatient
        chiefComplaint = try values.decodeIfPresent(String.self, forKey: .chiefComplaint) ?? ""
        diagnosis = try values.decodeIfPresent(String.self, forKey: .diagnosis) ?? ""
        treatment = try values.decodeIfPresent(String.self, forKey: .treatment) ?? ""
        totalCost = try values.decodeIfPresent(Decimal.self, forKey: .totalCost) ?? 0
        insuranceCost = try values.decodeIfPresent(Decimal.self, forKey: .insuranceCost) ?? 0
        selfPayCost = try values.decodeIfPresent(Decimal.self, forKey: .selfPayCost) ?? 0
        let paymentRawValue = try values.decodeIfPresent(String.self, forKey: .paymentMethod)
        if let paymentRawValue,
           let storedMethod = MedicalPaymentMethod(rawValue: paymentRawValue) {
            paymentMethod = storedMethod
        } else if insuranceCost > 0, selfPayCost > 0 {
            paymentMethod = .medicalInsuranceThenSelfPay
        } else if insuranceCost > 0 {
            paymentMethod = .medicalInsurance
        } else {
            paymentMethod = .selfPay
        }
        expenseItems = try values.decodeIfPresent(
            [MedicalExpenseItem].self,
            forKey: .expenseItems
        ) ?? []

        let storedItemsTotal = expenseItems.reduce(Decimal.zero) { $0 + $1.amount }
        if totalCost > storedItemsTotal {
            expenseItems.append(
                MedicalExpenseItem(
                    name: storedItemsTotal == 0 ? "历史费用汇总" : "历史费用差额",
                    quantity: 1,
                    unit: "项",
                    amount: totalCost - storedItemsTotal,
                    note: "由旧版手动填写的总费用自动迁移"
                )
            )
        }
        totalCost = expenseItems.reduce(Decimal.zero) { $0 + $1.amount }
        switch paymentMethod {
        case .selfPay:
            insuranceCost = 0
            selfPayCost = totalCost
        case .medicalInsurance:
            insuranceCost = totalCost
            selfPayCost = 0
        case .medicalInsuranceThenSelfPay:
            insuranceCost = min(max(insuranceCost, 0), totalCost)
            selfPayCost = totalCost - insuranceCost
        }

        attachments = try values.decodeIfPresent([FileAttachment].self, forKey: .attachments) ?? []
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? date
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    static func normalizedDate(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12
        )) ?? date
    }

    var expenseItemsTotal: Decimal {
        expenseItems.reduce(Decimal.zero) { $0 + $1.amount }
    }

    var isFollowUp: Bool {
        parentRecordID != nil
    }

    var isPharmacyPurchase: Bool {
        visitType == .pharmacyPurchase
    }

    var institutionLabel: String {
        isPharmacyPurchase ? "药房" : "医院"
    }

    var hospitalClassificationTitles: [String] {
        [
            hospitalLevel == .unspecified ? nil : hospitalLevel.title,
            hospitalGrade == .unspecified ? nil : hospitalGrade.title,
            hospitalCategory == .unspecified ? nil : hospitalCategory.title
        ].compactMap { $0 }
    }

    var costSummary: MedicalCostSummary {
        MedicalCostSummary(
            totalCost: totalCost,
            insuranceCost: insuranceCost,
            selfPayCost: selfPayCost
        )
    }
}

extension HospitalProfile {
    init(record: MedicalRecord) {
        name = record.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
        level = record.hospitalLevel
        grade = record.hospitalGrade
        category = record.hospitalCategory
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    static func inferred(from records: [MedicalRecord]) -> [HospitalProfile] {
        var profiles: [String: HospitalProfile] = [:]
        for record in records where !record.isPharmacyPurchase {
            let name = record.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_CN")
            )
            if var profile = profiles[key] {
                if profile.level == .unspecified { profile.level = record.hospitalLevel }
                if profile.grade == .unspecified { profile.grade = record.hospitalGrade }
                if profile.category == .unspecified { profile.category = record.hospitalCategory }
                profile.createdAt = min(profile.createdAt, record.createdAt)
                profile.updatedAt = max(profile.updatedAt, record.updatedAt)
                profiles[key] = profile
            } else {
                profiles[key] = HospitalProfile(record: record)
            }
        }
        return profiles.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct MedicalCostSummary: Equatable {
    var totalCost: Decimal = 0
    var insuranceCost: Decimal = 0
    var selfPayCost: Decimal = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            totalCost: lhs.totalCost + rhs.totalCost,
            insuranceCost: lhs.insuranceCost + rhs.insuranceCost,
            selfPayCost: lhs.selfPayCost + rhs.selfPayCost
        )
    }
}

enum MedicalValueFormatter {
    static func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "¥0.00"
    }

    static func number(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        formatter.usesGroupingSeparator = false
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    static func percentage(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0%"
    }
}
