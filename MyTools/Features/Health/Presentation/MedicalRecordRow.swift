#if MYTOOLS_FEATURE_HEALTH
import SwiftUI

extension MedicalVisitType {
    var badgeColor: Color {
        switch self {
        case .outpatient: return .blue
        case .emergency: return .red
        case .inpatient: return .purple
        case .pharmacyPurchase: return .green
        case .physicalExam: return .mint
        }
    }
}

private extension HospitalLevel {
    var badgeColor: Color {
        switch self {
        case .levelThree: return .indigo
        case .levelTwo: return .indigo.opacity(0.72)
        case .levelOne: return .indigo.opacity(0.48)
        case .unspecified: return .secondary
        }
    }
}

private extension HospitalGrade {
    var badgeColor: Color {
        switch self {
        case .classA: return .purple
        case .classB: return .purple.opacity(0.72)
        case .classC: return .purple.opacity(0.48)
        case .unspecified: return .secondary
        }
    }
}

private extension HospitalCategory {
    var badgeColor: Color {
        switch self {
        case .specialized: return .mint
        case .general: return .cyan
        case .unspecified: return .secondary
        }
    }
}

struct HospitalClassificationBadges: View {
    let level: HospitalLevel
    let grade: HospitalGrade
    let category: HospitalCategory

    init(record: MedicalRecord) {
        level = record.institutionType == .hospital
            ? record.hospitalLevel
            : .unspecified
        grade = record.institutionType == .hospital
            ? record.hospitalGrade
            : .unspecified
        category = record.institutionType == .hospital
            ? record.hospitalCategory
            : .unspecified
    }

    init(profile: HospitalProfile) {
        level = profile.supports(.hospital) ? profile.level : .unspecified
        grade = profile.supports(.hospital) ? profile.grade : .unspecified
        category = profile.supports(.hospital) ? profile.category : .unspecified
    }

    var body: some View {
        HStack(spacing: 4) {
            if level != .unspecified {
                badge(level.title, color: level.badgeColor)
            }
            if grade != .unspecified {
                badge(grade.title, color: grade.badgeColor)
            }
            if category != .unspecified {
                badge(category.title, color: category.badgeColor)
            }
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .appFont(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

struct MedicalRecordRow: View {
    let record: MedicalRecord
    let isFollowUp: Bool
    let followUpCount: Int
    let relatedPharmacyPurchaseCount: Int
    let displayedTotalCost: Decimal

    init(
        record: MedicalRecord,
        isFollowUp: Bool = false,
        followUpCount: Int = 0,
        relatedPharmacyPurchaseCount: Int = 0,
        displayedTotalCost: Decimal? = nil
    ) {
        self.record = record
        self.isFollowUp = isFollowUp
        self.followUpCount = followUpCount
        self.relatedPharmacyPurchaseCount = relatedPharmacyPurchaseCount
        self.displayedTotalCost = displayedTotalCost ?? record.totalCost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            if isFollowUp {
                HStack {
                    Label(linkedRecordTitle, systemImage: linkedRecordSystemImage)
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(linkedRecordColor)
                    Spacer()
                    Text(AppDateFormatter.string(from: record.date))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(record.hospital).appFont(.headline).lineLimit(1)
                Spacer(minLength: 8)
                HospitalClassificationBadges(record: record)
            }
            HStack {
                if record.isPharmacyPurchase {
                    Text("药品 \(record.expenseItems.count) 项")
                } else if record.isPhysicalExam {
                    Text(record.physicalExamDetails?.packageName.isEmpty == false
                        ? record.physicalExamDetails?.packageName ?? ""
                        : "健康体检")
                } else {
                    Text(record.department)
                }
                Spacer()
                Text(record.visitType.title)
                    .appFont(.caption2.weight(.semibold))
                    .foregroundStyle(record.visitType.badgeColor)
                if !isFollowUp {
                    Text(AppDateFormatter.string(from: record.date))
                }
            }
            .appFont(.subheadline)
            .foregroundStyle(.secondary)

            if !recordSummary.isEmpty {
                recordSummaryView
            }

            HStack {
                if !isFollowUp, followUpCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: linkedRecordSystemImage)
                        Text(
                            "\(linkedRecordTitle) · \(followUpCount) \(linkedRecordCountUnit)"
                        )
                        .fontWeight(.semibold)
                    }
                    .foregroundStyle(linkedRecordColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                if !isFollowUp, relatedPharmacyPurchaseCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "pills.fill")
                        Text("关联购药 · \(relatedPharmacyPurchaseCount) 次")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                if !record.tags.isEmpty {
                    AppTagCapsules(tags: record.tags, limit: 2)
                }
                Spacer()
                Text(MedicalValueFormatter.money(displayedTotalCost))
                    .monospacedDigit()
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recordSummaryView: some View {
        if record.isPharmacyPurchase {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("用药原因")
                    .appFont(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(recordSummary)
                    .appFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .lineLimit(2)
        } else if record.isPhysicalExam {
            MarkdownText(recordSummary)
                .appFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .accessibilityLabel("查出的问题，\(recordSummary)")
        } else {
            Text(recordSummary)
                .appFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .accessibilityLabel("初步诊断，\(recordSummary)")
        }
    }

    private var recordSummary: String {
        if record.isPhysicalExam {
            if !record.diagnosis.isEmpty { return record.diagnosis }
            return record.physicalExamDetails?.packageName ?? ""
        }
        guard record.isPharmacyPurchase else { return record.diagnosis }
        if !record.chiefComplaint.isEmpty { return record.chiefComplaint }
        let medicineNames = record.expenseItems.prefix(3)
            .map(\.name)
            .filter { !$0.isEmpty }
        return medicineNames.isEmpty
            ? "未填写用药原因"
            : medicineNames.joined(separator: " · ")
    }

    private var linkedRecordTitle: String {
        if record.isPhysicalExam { return "补检记录" }
        if record.isInpatient { return "住院日记录" }
        return "复诊记录"
    }

    private var linkedRecordSystemImage: String {
        if record.isPhysicalExam { return "heart.text.clipboard" }
        return record.isInpatient ? "bed.double" : "calendar.badge.clock"
    }

    private var linkedRecordColor: Color {
        if record.isPhysicalExam { return .mint }
        return record.isInpatient ? .purple : .blue
    }

    private var linkedRecordCountUnit: String {
        record.isInpatient ? "天" : "次"
    }
}

#endif
