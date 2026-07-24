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

    var id: Self { self }

    var title: String {
        switch self {
        case .outpatient: return "门诊"
        case .emergency: return "急诊"
        case .inpatient: return "住院"
        }
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

struct Prescription: Identifiable, Codable, Equatable {
    var id = UUID()
    var medicine = ""
    var specification = ""
    var frequency = ""
    var dose = ""
    var duration = ""
    var remark = ""
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
    var date = Date()
    var hospital = ""
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
    var prescriptions: [Prescription] = []
    var attachments: [FileAttachment] = []
    var tags: [String] = []
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    private enum CodingKeys: String, CodingKey {
        case id, date, hospital, department, doctor, visitType
        case chiefComplaint, diagnosis, treatment
        case totalCost, insuranceCost, selfPayCost, paymentMethod
        case prescriptions, attachments, tags, notes, createdAt, updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        hospital = try values.decodeIfPresent(String.self, forKey: .hospital) ?? ""
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
        prescriptions = try values.decodeIfPresent([Prescription].self, forKey: .prescriptions) ?? []
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
}
