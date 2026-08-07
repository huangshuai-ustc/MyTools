import Foundation
import UniformTypeIdentifiers

enum AttachmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case invoice
    case medicalRecord
    case laboratoryReport
    case ct
    case mri
    case xray
    case testSheet
    case physicalExamReport
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
        case .physicalExamReport: return "体检报告"
        case .scan: return "扫描件"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .invoice: return "receipt"
        case .medicalRecord: return "doc.text"
        case .laboratoryReport, .testSheet: return "cross.vial"
        case .physicalExamReport: return "heart.text.clipboard"
        case .ct, .mri, .xray: return "waveform.path.ecg.rectangle"
        case .scan: return "doc.viewfinder"
        case .other: return "paperclip"
        }
    }
}

struct FileAttachment: Identifiable, Codable, Equatable, Sendable {
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
