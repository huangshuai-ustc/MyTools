#if MYTOOLS_FEATURE_HEALTH
import Foundation

enum MedicalVisitType: String, Codable, CaseIterable, Identifiable {
    case outpatient
    case emergency
    case inpatient
    case pharmacyPurchase
    case physicalExam

    var id: Self { self }

    var title: String {
        switch self {
        case .outpatient: return "门诊"
        case .emergency: return "急诊"
        case .inpatient: return "住院"
        case .pharmacyPurchase: return "药房购药"
        case .physicalExam: return "体检"
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

    static var displayOrder: [Self] {
        [.levelThree, .levelTwo, .levelOne, .unspecified]
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

    static var displayOrder: [Self] {
        [.classA, .classB, .classC, .unspecified]
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
        case .general: return "综合"
        case .specialized: return "专科"
        }
    }
}

enum MedicalInstitutionType: String, Codable, CaseIterable, Identifiable {
    case hospital
    case pharmacy
    case physicalExam

    var id: Self { self }

    var title: String {
        switch self {
        case .hospital: return "医院"
        case .pharmacy: return "药房"
        case .physicalExam: return "体检机构"
        }
    }

    var systemImage: String {
        switch self {
        case .hospital: return "building.2"
        case .pharmacy: return "pills"
        case .physicalExam: return "heart.text.clipboard"
        }
    }
}

struct HospitalProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var institutionTypes: Set<MedicalInstitutionType> = [.hospital]
    var level: HospitalLevel = .unspecified
    var grade: HospitalGrade = .unspecified
    var category: HospitalCategory = .unspecified
    var createdAt = Date()
    var updatedAt = Date()

    var primaryInstitutionType: MedicalInstitutionType {
        MedicalInstitutionType.allCases.first(where: { institutionTypes.contains($0) }) ?? .hospital
    }

    var institutionTypeTitles: [String] {
        MedicalInstitutionType.allCases
            .filter { institutionTypes.contains($0) }
            .map(\.title)
    }

    var institutionTypeTitle: String {
        institutionTypeTitles.joined(separator: "、")
    }

    var institutionTypeSystemImage: String {
        primaryInstitutionType.systemImage
    }

    func supports(_ type: MedicalInstitutionType) -> Bool {
        institutionTypes.contains(type)
    }

    mutating func setSupport(_ type: MedicalInstitutionType, enabled: Bool) {
        if enabled {
            institutionTypes.insert(type)
        } else if institutionTypes.count > 1 {
            institutionTypes.remove(type)
        }
    }

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

}

struct PhysicalExamFinding: Identifiable, Codable, Equatable {
    var id = UUID()
    var item = ""
    var result = ""
    var recommendation = ""

    init(
        id: UUID = UUID(),
        item: String = "",
        result: String = "",
        recommendation: String = ""
    ) {
        self.id = id
        self.item = item
        self.result = result
        self.recommendation = recommendation
    }
}

struct PhysicalExamDetails: Codable, Equatable {
    var packageName = ""
    var reportDate: Date?
    var completedItems = ""
    var findings: [PhysicalExamFinding] = []

    init(
        packageName: String = "",
        reportDate: Date? = nil,
        completedItems: String = "",
        findings: [PhysicalExamFinding] = []
    ) {
        self.packageName = packageName
        self.reportDate = reportDate
        self.completedItems = completedItems
        self.findings = findings
    }
}

struct MedicalRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var parentRecordID: UUID?
    var date = Date()
    // Only the root inpatient record uses this as the inclusive discharge date.
    var inpatientEndDate: Date?
    var hospital = ""
    var hospitalLevel: HospitalLevel = .unspecified
    var hospitalGrade: HospitalGrade = .unspecified
    var hospitalCategory: HospitalCategory = .unspecified
    var department = ""
    var doctor = ""
    var visitType: MedicalVisitType = .outpatient
    var physicalExamDetails: PhysicalExamDetails?
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
        chiefComplaint = parent.chiefComplaint
        diagnosis = parent.diagnosis
        treatment = parent.treatment
        if parent.isPhysicalExam {
            let parentDetails = parent.physicalExamDetails
            physicalExamDetails = PhysicalExamDetails(
                packageName: parentDetails?.packageName ?? ""
            )
        }
        tags = parent.tags
    }

    init(inpatientDayFor parent: MedicalRecord, date: Date) {
        parentRecordID = parent.parentRecordID ?? parent.id
        self.date = Self.normalizedDate(date)
        hospital = parent.hospital
        hospitalLevel = parent.hospitalLevel
        hospitalGrade = parent.hospitalGrade
        hospitalCategory = parent.hospitalCategory
        department = parent.department
        doctor = parent.doctor
        visitType = .inpatient
        tags = parent.tags
    }

    init(pharmacyPurchaseFor parent: MedicalRecord, date: Date = Date()) {
        parentRecordID = parent.parentRecordID ?? parent.id
        self.date = Self.normalizedDate(date)
        visitType = .pharmacyPurchase
        chiefComplaint = parent.diagnosis
        tags = parent.tags
    }

    init(physicalExamOn date: Date = Date()) {
        self.date = Self.normalizedDate(date)
        visitType = .physicalExam
        physicalExamDetails = PhysicalExamDetails()
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
        parentRecordID != nil && !isPharmacyPurchase
    }

    var isPharmacyPurchase: Bool {
        visitType == .pharmacyPurchase
    }

    var isLinkedPharmacyPurchase: Bool {
        isPharmacyPurchase && parentRecordID != nil
    }

    var hasAssociatedRecord: Bool {
        parentRecordID != nil
    }

    var isPhysicalExam: Bool {
        visitType == .physicalExam
    }

    var isInpatient: Bool {
        visitType == .inpatient
    }

    var isInpatientEpisode: Bool {
        isInpatient && parentRecordID == nil
    }

    var isInpatientDailyRecord: Bool {
        isInpatient && parentRecordID != nil
    }

    var hasInpatientDailyContent: Bool {
        isInpatientDailyRecord && (
            !chiefComplaint.isEmpty
                || !diagnosis.isEmpty
                || !treatment.isEmpty
                || !expenseItems.isEmpty
                || !attachments.isEmpty
                || !notes.isEmpty
                || totalCost != 0
                || insuranceCost != 0
                || selfPayCost != 0
        )
    }

    var institutionType: MedicalInstitutionType {
        if isPharmacyPurchase { return .pharmacy }
        if isPhysicalExam { return .physicalExam }
        return .hospital
    }

    var institutionLabel: String {
        if isPharmacyPurchase { return "药房" }
        return isPhysicalExam ? "体检机构" : "医院"
    }

    var hospitalClassificationTitles: [String] {
        guard institutionType == .hospital else { return [] }
        return [
            hospitalLevel == .unspecified ? nil : hospitalLevel.title,
            hospitalGrade == .unspecified ? nil : hospitalGrade.title,
            hospitalCategory == .unspecified ? nil : hospitalCategory.title
        ].compactMap { $0 }
    }

    mutating func normalizeInstitutionClassification() {
        guard institutionType == .hospital else {
            hospitalLevel = .unspecified
            hospitalGrade = .unspecified
            hospitalCategory = .unspecified
            return
        }
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
    private enum CodingKeys: String, CodingKey {
        case id, name, institutionTypes, level, grade, category, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        institutionTypes = try values.decode(Set<MedicalInstitutionType>.self, forKey: .institutionTypes)
        level = try values.decode(HospitalLevel.self, forKey: .level)
        grade = try values.decode(HospitalGrade.self, forKey: .grade)
        category = try values.decode(HospitalCategory.self, forKey: .category)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        normalizeClassification()
    }

    init(record: MedicalRecord) {
        name = record.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
        institutionTypes = [record.institutionType]
        level = record.hospitalLevel
        grade = record.hospitalGrade
        category = record.hospitalCategory
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        normalizeClassification()
    }

    mutating func normalizeClassification() {
        guard !supports(.hospital) else { return }
        level = .unspecified
        grade = .unspecified
        category = .unspecified
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

#endif
