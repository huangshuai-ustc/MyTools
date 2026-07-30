import SwiftUI
#if os(macOS)
import AppKit
#endif

struct HealthRecordsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var selectedTag = ""
    @State private var selectedYear: Int?
    @State private var editingRecord: MedicalRecord?

    private var displayedVisitGroups: [MedicalVisitGroup] {
        let records = store.medicalRecords
        let recordIDs = Set(records.map(\.id))
        let originalVisits = records
            .filter { record in
                guard let parentID = record.parentRecordID else { return true }
                return !recordIDs.contains(parentID)
            }
            .sorted { $0.date > $1.date }
        let linkedRecordsByParentID = Dictionary(
            grouping: records.compactMap { record -> (UUID, MedicalRecord)? in
                record.parentRecordID.map { ($0, record) }
            },
            by: \.0
        ).mapValues { $0.map(\.1).sorted { $0.date < $1.date } }

        return originalVisits.compactMap { originalVisit in
            let linkedRecords = linkedRecordsByParentID[originalVisit.id, default: []]
            let followUps = linkedRecords.filter { !$0.isPharmacyPurchase }
            let pharmacyPurchases = linkedRecords.filter(\.isLinkedPharmacyPurchase)
            let episodeCostSummary = linkedRecords.reduce(originalVisit.costSummary) {
                $0 + $1.costSummary
            }
            let originalMatches = recordMatchesFilters(originalVisit)
            let matchingLinkedRecords = linkedRecords.filter(recordMatchesFilters)

            guard originalMatches || !matchingLinkedRecords.isEmpty else { return nil }
            return MedicalVisitGroup(
                originalVisit: originalVisit,
                followUps: followUps,
                pharmacyPurchases: pharmacyPurchases,
                costSummary: episodeCostSummary
            )
        }
    }

    private func yearGroups(from visitGroups: [MedicalVisitGroup]) -> [MedicalYearGroup] {
        Dictionary(grouping: visitGroups) {
            calendar.component(.year, from: $0.originalVisit.date)
        }
            .map { MedicalYearGroup(year: $0.key, visitGroups: $0.value.sorted { $0.originalVisit.date > $1.originalVisit.date }) }
            .sorted { $0.year > $1.year }
    }

    private var availableYears: [Int] {
        let currentYear = calendar.component(.year, from: Date())
        return Array(Set(store.medicalRecords.map { calendar.component(.year, from: $0.date) } + [currentYear]))
            .sorted(by: >)
    }

    private var allTags: [String] {
        Array(Set(store.medicalRecords.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var overviewSnapshot: MedicalOverviewSnapshot {
        var total = Decimal.zero
        var insurance = Decimal.zero
        var selfPay = Decimal.zero
        var visitCount = 0
        var hospitals: Set<String> = []

        for record in store.medicalRecords {
            if let selectedYear,
               calendar.component(.year, from: record.date) != selectedYear {
                continue
            }
            total += record.totalCost
            insurance += record.insuranceCost
            selfPay += record.selfPayCost
            guard !record.isPharmacyPurchase else { continue }
            visitCount += 1
            let hospital = record.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hospital.isEmpty { hospitals.insert(hospital) }
        }

        return MedicalOverviewSnapshot(
            hospitalCount: hospitals.count,
            visitCount: visitCount,
            total: total,
            insurance: insurance,
            selfPay: selfPay,
            insuranceRatio: ratio(insurance, of: total),
            selfPayRatio: ratio(selfPay, of: total)
        )
    }

    private func ratio(_ value: Decimal, of total: Decimal) -> Decimal {
        guard total > 0 else { return 0 }
        return NSDecimalNumber(decimal: value)
            .dividing(by: NSDecimalNumber(decimal: total))
            .decimalValue
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
    }

    var body: some View {
        let visitGroups = displayedVisitGroups
        let groupedRecords = yearGroups(from: visitGroups)
        List {
            Section("健康总览") {
                Picker("统计范围", selection: $selectedYear) {
                    Text("全部").tag(nil as Int?)
                    ForEach(availableYears, id: \.self) { year in
                        Text(verbatim: "\(year) 年").tag(year as Int?)
                    }
                }
                .pickerStyle(.menu)

                overviewMetrics
                    .appListRowStyle()
            }

            Section {
                NavigationLink {
                    HospitalDirectoryView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "building.2")
                            .foregroundStyle(.pink)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("医疗机构资料库")
                            Text("\(store.hospitalProfiles.count) 家机构")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !allTags.isEmpty {
                Section("标签筛选") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            tagFilterButton(title: "全部", value: "", systemImage: "tag")
                            ForEach(allTags, id: \.self) { tag in
                                tagFilterButton(title: tag, value: tag)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }

            if visitGroups.isEmpty {
                Section {
                    ContentUnavailableView(
                        store.medicalRecords.isEmpty ? "暂无健康记录" : "没有匹配的健康记录",
                        systemImage: store.medicalRecords.isEmpty ? "cross.case" : "magnifyingglass",
                        description: Text(store.medicalRecords.isEmpty ? "点右上角编辑并验证身份后记录第一次就诊、购药、体检或住院" : "请尝试其他机构、药房、体检项目、住院记录、诊断、费用项目或标签")
                    )
                }
            }

            ForEach(groupedRecords) { group in
                Section {
                    ForEach(group.visitGroups) { visitGroup in
                        recordLink(
                            visitGroup.originalVisit,
                            isFollowUp: visitGroup.originalVisit.isFollowUp,
                            followUpCount: visitGroup.followUps.count,
                            relatedPharmacyPurchaseCount: visitGroup.pharmacyPurchases.count,
                            displayedTotalCost: visitGroup.costSummary.totalCost
                        )
                    }
                } header: {
                    Text(verbatim: "\(group.year) 年")
                }
            }
        }
        .navigationTitle("健康档案")
        .iOSLabeledBackButton("工具箱")
        .searchable(text: $query, prompt: "搜索机构、药房、诊断、费用项目或标签")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton()
                if auth.isAdmin {
                    Button { editingRecord = MedicalRecord() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增健康记录")
                }
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
#endif
        .sheet(item: $editingRecord) { record in
            MedicalRecordEditorView(record: record, isNew: true)
                .id(record.id)
                .iOSLargeSheet()
        }
    }

    private var overviewMetrics: some View {
        let summary = overviewSnapshot
        return VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    summaryMetric("机构", value: "\(summary.hospitalCount) 家")
                    summaryMetric("就诊/体检", value: "\(summary.visitCount) 次")
                    summaryMetric("总费用", value: MedicalValueFormatter.money(summary.total))
                }
                VStack(alignment: .leading, spacing: 9) {
                    summaryMetric("机构", value: "\(summary.hospitalCount) 家")
                    summaryMetric("就诊/体检", value: "\(summary.visitCount) 次")
                    summaryMetric("总费用", value: MedicalValueFormatter.money(summary.total))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    summaryMetricWithRatio(
                        "医保费用",
                        amount: summary.insurance,
                        ratio: summary.insuranceRatio,
                        color: .blue
                    )
                    summaryMetricWithRatio(
                        "自费费用",
                        amount: summary.selfPay,
                        ratio: summary.selfPayRatio,
                        color: .orange
                    )
                }
                VStack(alignment: .leading, spacing: 9) {
                    summaryMetricWithRatio(
                        "医保费用",
                        amount: summary.insurance,
                        ratio: summary.insuranceRatio,
                        color: .blue
                    )
                    summaryMetricWithRatio(
                        "自费费用",
                        amount: summary.selfPay,
                        ratio: summary.selfPayRatio,
                        color: .orange
                    )
                }
            }
        }
    }

    private func summaryMetric(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryMetricWithRatio(
        _ title: String,
        amount: Decimal,
        ratio: Decimal,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MedicalValueFormatter.money(amount))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("(\(MedicalValueFormatter.percentage(ratio)))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(color.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagFilterButton(title: String, value: String, systemImage: String? = nil) -> some View {
        let isSelected = selectedTag == value
        return Button { selectedTag = value } label: {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                isSelected ? Color.pink : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private func recordMatchesFilters(_ record: MedicalRecord) -> Bool {
        guard selectedTag.isEmpty || record.tags.contains(selectedTag) else { return false }
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return searchTerm.isEmpty
            || record.hospital.localizedCaseInsensitiveContains(searchTerm)
            || record.department.localizedCaseInsensitiveContains(searchTerm)
            || record.doctor.localizedCaseInsensitiveContains(searchTerm)
            || record.chiefComplaint.localizedCaseInsensitiveContains(searchTerm)
            || record.diagnosis.localizedCaseInsensitiveContains(searchTerm)
            || record.treatment.localizedCaseInsensitiveContains(searchTerm)
            || record.physicalExamDetails?.packageName.localizedCaseInsensitiveContains(searchTerm) == true
            || record.physicalExamDetails?.completedItems.localizedCaseInsensitiveContains(searchTerm) == true
            || record.physicalExamDetails?.findings.contains {
                $0.item.localizedCaseInsensitiveContains(searchTerm)
                    || $0.result.localizedCaseInsensitiveContains(searchTerm)
                    || $0.recommendation.localizedCaseInsensitiveContains(searchTerm)
            } == true
            || record.hospitalClassificationTitles.contains {
                $0.localizedCaseInsensitiveContains(searchTerm)
            }
            || record.tags.contains { $0.localizedCaseInsensitiveContains(searchTerm) }
            || record.expenseItems.contains {
                $0.name.localizedCaseInsensitiveContains(searchTerm)
                    || $0.unit.localizedCaseInsensitiveContains(searchTerm)
                    || $0.note.localizedCaseInsensitiveContains(searchTerm)
            }
            || record.attachments.contains {
                $0.fileName.localizedCaseInsensitiveContains(searchTerm)
                    || $0.kind.title.localizedCaseInsensitiveContains(searchTerm)
            }
    }

    private func recordLink(
        _ record: MedicalRecord,
        isFollowUp: Bool,
        followUpCount: Int = 0,
        relatedPharmacyPurchaseCount: Int = 0,
        displayedTotalCost: Decimal? = nil
    ) -> some View {
        NavigationLink {
            MedicalRecordDetailView(recordID: record.id)
        } label: {
            MedicalRecordRow(
                record: record,
                isFollowUp: isFollowUp,
                followUpCount: followUpCount,
                relatedPharmacyPurchaseCount: relatedPharmacyPurchaseCount,
                displayedTotalCost: displayedTotalCost ?? record.totalCost
            )
        }
        .appListRowStyle()
        .swipeActions {
            if auth.isAdmin {
                Button(role: .destructive) {
                    store.deleteMedicalRecords(ids: [record.id])
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }
}

private struct MedicalYearGroup: Identifiable {
    let year: Int
    let visitGroups: [MedicalVisitGroup]
    var id: Int { year }
}

private struct MedicalOverviewSnapshot {
    let hospitalCount: Int
    let visitCount: Int
    let total: Decimal
    let insurance: Decimal
    let selfPay: Decimal
    let insuranceRatio: Decimal
    let selfPayRatio: Decimal
}

private struct MedicalVisitGroup: Identifiable {
    let originalVisit: MedicalRecord
    let followUps: [MedicalRecord]
    let pharmacyPurchases: [MedicalRecord]
    let costSummary: MedicalCostSummary
    var id: UUID { originalVisit.id }
}

private extension MedicalVisitType {
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
        level = record.institutionType == .hospital ? record.hospitalLevel : .unspecified
        grade = record.institutionType == .hospital ? record.hospitalGrade : .unspecified
        category = record.institutionType == .hospital ? record.hospitalCategory : .unspecified
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

private struct MedicalRecordRow: View {
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
                    Label(
                        linkedRecordTitle,
                        systemImage: linkedRecordSystemImage
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(linkedRecordColor)
                    Spacer()
                    Text(AppDateFormatter.string(from: record.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(record.hospital).font(.headline).lineLimit(1)
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(record.visitType.badgeColor)
                if !isFollowUp {
                    Text(AppDateFormatter.string(from: record.date))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !recordSummary.isEmpty {
                if record.isPharmacyPurchase {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("用药原因")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(recordSummary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .lineLimit(2)
                } else if record.isPhysicalExam {
                    MarkdownText(recordSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .accessibilityLabel("查出的问题，\(recordSummary)")
                } else {
                    Text(recordSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .accessibilityLabel("初步诊断，\(recordSummary)")
                }
            }

            HStack {
                if !isFollowUp, followUpCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: linkedRecordSystemImage)
                        Text("\(linkedRecordTitle) · \(followUpCount) \(linkedRecordCountUnit)")
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
                    Text(record.tags.prefix(2).joined(separator: " · "))
                        .lineLimit(1)
                }
                Spacer()
                Text(MedicalValueFormatter.money(displayedTotalCost))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var recordSummary: String {
        if record.isPhysicalExam {
            if !record.diagnosis.isEmpty { return record.diagnosis }
            return record.physicalExamDetails?.packageName ?? ""
        }
        guard record.isPharmacyPurchase else { return record.diagnosis }
        if !record.chiefComplaint.isEmpty { return record.chiefComplaint }
        let medicineNames = record.expenseItems.prefix(3).map(\.name).filter { !$0.isEmpty }
        return medicineNames.isEmpty ? "未填写用药原因" : medicineNames.joined(separator: " · ")
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

private struct MedicalRecordDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    let recordID: UUID
    @State private var editingRecord: MedicalRecord?
    @State private var viewingExpenseItem: MedicalExpenseItem?
    @State private var previewAttachment: FileAttachment?
    @State private var attachmentError = ""
    @State private var showingAttachmentError = false

    private var record: MedicalRecord? {
        store.medicalRecords.first { $0.id == recordID }
    }

    private var associatedRecord: MedicalRecord? {
        guard let parentID = record?.parentRecordID else { return nil }
        return store.medicalRecords.first { $0.id == parentID }
    }

    private var followUps: [MedicalRecord] {
        store.medicalRecords
            .filter { $0.parentRecordID == recordID && !$0.isPharmacyPurchase }
            .sorted { $0.date < $1.date }
    }

    private var outOfRangeInpatientDailyRecords: [MedicalRecord] {
        guard let record, record.isInpatientEpisode else { return [] }
        return followUps.filter { !inpatientDateIsWithinRange($0.date, parent: record) }
    }

    private var pharmacyPurchases: [MedicalRecord] {
        store.medicalRecords
            .filter { $0.parentRecordID == recordID && $0.isLinkedPharmacyPurchase }
            .sorted { $0.date < $1.date }
    }

    private var followUpCostSummary: MedicalCostSummary {
        followUps.reduce(MedicalCostSummary()) { $0 + $1.costSummary }
    }

    private var pharmacyPurchaseCostSummary: MedicalCostSummary {
        pharmacyPurchases.reduce(MedicalCostSummary()) { $0 + $1.costSummary }
    }

    private var episodeCostSummary: MedicalCostSummary {
        guard let record else { return MedicalCostSummary() }
        return record.hasAssociatedRecord
            ? record.costSummary
            : record.costSummary + followUpCostSummary + pharmacyPurchaseCostSummary
    }

    private var detailNavigationTitle: String {
        guard let record else { return "就诊详情" }
        if record.isPhysicalExam { return "体检详情" }
        if record.isInpatientEpisode { return "住院详情" }
        if record.isInpatientDailyRecord { return "住院日详情" }
        if record.isFollowUp { return "复诊详情" }
        return record.hospital.isEmpty ? "就诊详情" : record.hospital
    }

    private var informationSectionTitle: String {
        guard let record else { return "就诊信息" }
        if record.isPharmacyPurchase { return "购药信息" }
        if record.isPhysicalExam { return "体检信息" }
        if record.isInpatientEpisode { return "住院信息" }
        if record.isInpatientDailyRecord { return "住院日记录" }
        return record.isFollowUp ? "复诊信息" : "就诊信息"
    }

    private var dayRecordDateTitle: String {
        guard let record else { return "日期" }
        if record.isPharmacyPurchase { return "购药日期" }
        if record.isPhysicalExam { return "体检日期" }
        if record.isInpatientDailyRecord { return "记录日期" }
        if record.isInpatientEpisode { return "入院日期" }
        return record.isFollowUp ? "复诊日期" : "日期"
    }

    var body: some View {
        Group {
            if let record {
                recordList(record)
            } else {
                ContentUnavailableView("就诊记录已不存在", systemImage: "cross.case")
            }
        }
        .navigationTitle(detailNavigationTitle)
        .iOSLabeledBackButton("健康档案")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton()
                if auth.isAdmin, let record {
                    if record.isPhysicalExam, !record.hasAssociatedRecord {
                        Button { editingRecord = MedicalRecord(followUpTo: record) } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .accessibilityLabel("新增检查批次")
                        .help("新增检查批次")
                    } else if !record.hasAssociatedRecord,
                              !record.isPharmacyPurchase,
                              !record.isPhysicalExam,
                              !record.isInpatient {
                        Button {
                            editingRecord = MedicalRecord(followUpTo: record)
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .accessibilityLabel("新增复诊记录")
                        .help("新增复诊记录")

                        Button {
                            editingRecord = MedicalRecord(pharmacyPurchaseFor: record)
                        } label: {
                            Image(systemName: "pills.fill")
                        }
                        .accessibilityLabel("新增关联药房购药")
                        .help("新增关联药房购药")
                    }
                    Button { editingRecord = record } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("编辑健康记录")
                        .help(record.isPharmacyPurchase
                            ? "编辑购药记录"
                            : (record.isPhysicalExam
                                ? (record.hasAssociatedRecord ? "编辑检查批次" : "编辑体检记录")
                                : (record.isInpatient
                                    ? (record.hasAssociatedRecord ? "编辑住院日记录" : "编辑住院记录")
                                    : (record.isFollowUp ? "编辑复诊记录" : "编辑就诊记录"))))
                }
            }
        }
        .sheet(item: $editingRecord) { record in
            MedicalRecordEditorView(
                record: record,
                isNew: !store.medicalRecords.contains { $0.id == record.id }
            )
                .id(record.id)
                .iOSLargeSheet()
        }
        .sheet(item: $viewingExpenseItem) { item in
            MedicalExpenseItemDetailView(item: item)
                .iOSLargeSheet()
        }
#if os(iOS)
        .sheet(item: $previewAttachment) { attachment in
            NavigationStack {
                AttachmentPreview(url: store.medicalAttachmentURL(for: attachment))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(attachment.fileName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                previewAttachment = nil
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("关闭预览")
                        }
                    }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .interactiveDismissDisabled(false)
            .iOSLargeSheet()
        }
#endif
        .alert("无法打开附件", isPresented: $showingAttachmentError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(attachmentError)
        }
    }

    private func recordList(_ record: MedicalRecord) -> some View {
        List {
            if record.hasAssociatedRecord {
                Section(record.isInpatient ? "关联住院" : "关联就诊") {
                    if let associatedRecord {
                        NavigationLink {
                            MedicalRecordDetailView(recordID: associatedRecord.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(associatedRecord.hospital).font(.headline)
                                Text(
                                    "\(associatedRecord.visitType.title) · \(AppDateFormatter.string(from: associatedRecord.date))"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Label("原就诊记录已不存在", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section(informationSectionTitle) {
                CopyableValueRow(
                    title: dayRecordDateTitle,
                    value: AppDateFormatter.string(from: record.date)
                )
                if record.isInpatientEpisode {
                    CopyableValueRow(
                        title: "出院日期",
                        value: AppDateFormatter.string(from: record.inpatientEndDate ?? record.date)
                    )
                    CopyableValueRow(
                        title: "住院天数",
                        value: "\(inpatientDayCount(for: record)) 天"
                    )
                }
                CopyableValueRow(title: record.institutionLabel, value: record.hospital)
                if !record.hospitalClassificationTitles.isEmpty {
                    CopyableValueRow(
                        title: "机构分类",
                        value: record.hospitalClassificationTitles.joined(separator: " · ")
                    )
                }
                CopyableValueRow(title: "类型", value: record.visitType.title)
                if record.isPharmacyPurchase {
                    if !record.chiefComplaint.isEmpty {
                        CopyableValueRow(title: "用药原因", value: record.chiefComplaint)
                    }
                } else if record.isPhysicalExam {
                    CopyableValueRow(
                        title: "主要内容",
                        value: record.physicalExamDetails?.packageName ?? ""
                    )
                    MarkdownValueRow(
                        title: "查出的问题",
                        markdown: record.diagnosis,
                        alignment: .leading
                    )
                } else if record.isInpatient {
                    CopyableValueRow(title: "科室", value: record.department)
                    if !record.doctor.isEmpty { CopyableValueRow(title: "医生", value: record.doctor) }
                    if record.isInpatientDailyRecord {
                        CopyableValueRow(
                            title: "当天情况",
                            value: record.chiefComplaint,
                            alignment: .leading
                        )
                        CopyableValueRow(
                            title: "当天诊疗结果",
                            value: record.diagnosis,
                            alignment: .leading
                        )
                        CopyableValueRow(
                            title: "当天用药与操作",
                            value: record.treatment,
                            alignment: .leading
                        )
                    } else {
                        CopyableValueRow(
                            title: "入院原因",
                            value: record.chiefComplaint,
                            alignment: .leading
                        )
                        CopyableValueRow(
                            title: "主要诊断",
                            value: record.diagnosis,
                            alignment: .leading
                        )
                        CopyableValueRow(
                            title: "治疗方案",
                            value: record.treatment,
                            alignment: .leading
                        )
                    }
                } else {
                    CopyableValueRow(title: "科室", value: record.department)
                    if !record.doctor.isEmpty { CopyableValueRow(title: "医生", value: record.doctor) }
                    CopyableValueRow(
                        title: "主诉",
                        value: record.chiefComplaint,
                        alignment: .leading
                    )
                    CopyableValueRow(
                        title: "初步诊断",
                        value: record.diagnosis,
                        alignment: .leading
                    )
                    CopyableValueRow(
                        title: "治疗建议",
                        value: record.treatment,
                        alignment: .leading
                    )
                }
            }

            if !record.hasAssociatedRecord, !record.isPharmacyPurchase {
                if record.isPhysicalExam {
                    Section("检查批次") {
                        if followUps.isEmpty {
                            Text("暂无其他检查批次").foregroundStyle(.secondary)
                        }
                        ForEach(followUps) { followUp in
                            NavigationLink {
                                MedicalRecordDetailView(recordID: followUp.id)
                            } label: {
                                MedicalPhysicalExamFollowUpRow(record: followUp)
                            }
                            .appListRowStyle()
                            .swipeActions {
                                if auth.isAdmin {
                                    Button(role: .destructive) {
                                        store.deleteMedicalRecords(ids: [followUp.id])
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                    }
                } else if record.isInpatient {
                    Section("住院日记录") {
                        if followUps.isEmpty {
                            Text("暂无住院日记录").foregroundStyle(.secondary)
                        }
                        if !outOfRangeInpatientDailyRecords.isEmpty {
                            Text("区间外但已有内容的住院日记录已保留，请确认住院日期范围。")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        ForEach(followUps) { followUp in
                            NavigationLink {
                                MedicalRecordDetailView(recordID: followUp.id)
                            } label: {
                                MedicalInpatientDayRow(record: followUp, parent: record)
                            }
                            .appListRowStyle()
                            .swipeActions {
                                if auth.isAdmin {
                                    Button(role: .destructive) {
                                        store.deleteMedicalRecords(ids: [followUp.id])
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                    }
                } else {
                    Section("复诊记录") {
                        if followUps.isEmpty {
                            Text("暂无复诊记录").foregroundStyle(.secondary)
                        }
                        ForEach(followUps) { followUp in
                            NavigationLink {
                                MedicalRecordDetailView(recordID: followUp.id)
                            } label: {
                                MedicalFollowUpRow(record: followUp)
                            }
                            .appListRowStyle()
                            .swipeActions {
                                if auth.isAdmin {
                                    Button(role: .destructive) {
                                        store.deleteMedicalRecords(ids: [followUp.id])
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                    }

                    Section("关联药房购药") {
                        if pharmacyPurchases.isEmpty {
                            Text("暂无关联购药记录").foregroundStyle(.secondary)
                        }
                        ForEach(pharmacyPurchases) { purchase in
                            NavigationLink {
                                MedicalRecordDetailView(recordID: purchase.id)
                            } label: {
                                MedicalLinkedPharmacyPurchaseRow(record: purchase)
                            }
                            .appListRowStyle()
                            .swipeActions {
                                if auth.isAdmin {
                                    Button(role: .destructive) {
                                        store.deleteMedicalRecords(ids: [purchase.id])
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                    }
                }
            }

            Section("费用") {
                if !record.hasAssociatedRecord, (!followUps.isEmpty || !pharmacyPurchases.isEmpty) {
                    CopyableValueRow(title: "本次费用", value: MedicalValueFormatter.money(record.totalCost))
                    if !followUps.isEmpty {
                        CopyableValueRow(
                            title: record.isPhysicalExam
                                ? "其他检查批次费用"
                                : (record.isInpatient ? "住院日费用" : "复诊费用"),
                            value: MedicalValueFormatter.money(followUpCostSummary.totalCost)
                        )
                    }
                    if !pharmacyPurchases.isEmpty {
                        CopyableValueRow(
                            title: "关联购药费用",
                            value: MedicalValueFormatter.money(pharmacyPurchaseCostSummary.totalCost)
                        )
                    }
                }
                CopyableValueRow(
                    title: "总费用",
                    value: MedicalValueFormatter.money(episodeCostSummary.totalCost)
                )
                CopyableValueRow(
                    title: "医保支付",
                    value: MedicalValueFormatter.money(episodeCostSummary.insuranceCost)
                )
                CopyableValueRow(
                    title: "自费",
                    value: MedicalValueFormatter.money(episodeCostSummary.selfPayCost)
                )
                CopyableValueRow(
                    title: followUps.isEmpty && pharmacyPurchases.isEmpty ? "支付方式" : "本次支付方式",
                    value: record.paymentMethod.title
                )
            }

            Section(
                record.isPharmacyPurchase
                    ? "药品"
                    : (record.isPhysicalExam
                        ? "体检费用"
                        : (record.isInpatient ? "住院期间项目" : "费用项目"))
            ) {
                if record.expenseItems.isEmpty {
                    Text(record.isInpatient ? "未记录住院期间项目" : "未记录费用项目")
                        .foregroundStyle(.secondary)
                }
                ForEach(record.expenseItems) { item in
                    Button {
                        viewingExpenseItem = item
                    } label: {
                        MedicalExpenseItemRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .appListRowStyle()
                }
                if !record.expenseItems.isEmpty {
                    LabeledContent(
                        "项目合计",
                        value: MedicalValueFormatter.money(record.expenseItemsTotal)
                    )
                }
            }

            Section("附件") {
                if record.attachments.isEmpty {
                    Text("未添加附件").foregroundStyle(.secondary)
                }
                ForEach(record.attachments) { attachment in
                    Button { open(attachment) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: attachment.kind.systemImage)
                                .foregroundStyle(.pink)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attachment.fileName).lineLimit(2)
                                Text("\(attachment.kind.title) · \(attachment.displaySize)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !record.tags.isEmpty {
                Section("标签") {
                    Text(record.tags.joined(separator: " · "))
                        .copyableText(record.tags.joined(separator: " · "))
                }
            }

            if !record.notes.isEmpty {
                Section("备注") {
                    Text(record.notes)
                        .copyableText(record.notes)
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
    }

    private func inpatientDayCount(for record: MedicalRecord) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let start = MedicalRecord.normalizedDate(record.date)
        let end = MedicalRecord.normalizedDate(record.inpatientEndDate ?? record.date)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    private func open(_ attachment: FileAttachment) {
        let url = store.medicalAttachmentURL(for: attachment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            attachmentError = "附件文件已不在本机，请编辑这条记录并重新添加。"
            showingAttachmentError = true
            return
        }
#if os(iOS)
        previewAttachment = attachment
#elseif os(macOS)
        NSWorkspace.shared.open(url)
#endif
    }
}

private struct MedicalPhysicalExamFollowUpRow: View {
    let record: MedicalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack {
                Label(
                    AppDateFormatter.string(from: record.date),
                    systemImage: "calendar.badge.clock"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.mint)
                Spacer()
                Text("体检")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !record.diagnosis.isEmpty {
                MarkdownText(record.diagnosis)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            HStack {
                if !record.hospital.isEmpty {
                    Text(record.hospital)
                }
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private func inpatientDateIsWithinRange(_ date: Date, parent: MedicalRecord) -> Bool {
    let normalizedDate = MedicalRecord.normalizedDate(date)
    let startDate = MedicalRecord.normalizedDate(parent.date)
    let endDate = MedicalRecord.normalizedDate(parent.inpatientEndDate ?? parent.date)
    return normalizedDate >= startDate && normalizedDate <= endDate
}

private struct MedicalInpatientDayRow: View {
    let record: MedicalRecord
    let parent: MedicalRecord

    private var dayNumber: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let start = MedicalRecord.normalizedDate(parent.date)
        let date = MedicalRecord.normalizedDate(record.date)
        return max(1, (calendar.dateComponents([.day], from: start, to: date).day ?? 0) + 1)
    }

    private var summary: String {
        if !record.chiefComplaint.isEmpty { return record.chiefComplaint }
        if !record.diagnosis.isEmpty { return record.diagnosis }
        return record.treatment
    }

    private var isWithinRange: Bool {
        inpatientDateIsWithinRange(record.date, parent: parent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack {
                Label(
                    isWithinRange ? "住院第\(dayNumber)天" : "区间外记录",
                    systemImage: isWithinRange ? "bed.double" : "exclamationmark.triangle"
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isWithinRange ? .purple : .orange)
                Spacer()
                Text(AppDateFormatter.string(from: record.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .lineLimit(2)
            } else {
                Text("尚未记录当天情况")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if !record.expenseItems.isEmpty {
                    Text("项目 \(record.expenseItems.count) 项")
                }
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MedicalFollowUpRow: View {
    let record: MedicalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack {
                Label(
                    AppDateFormatter.string(from: record.date),
                    systemImage: "calendar.badge.clock"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                Spacer()
                Text(record.visitType.title)
                    .font(.caption)
                    .foregroundStyle(record.visitType.badgeColor)
            }
            Text(record.diagnosis)
                .font(.subheadline)
                .lineLimit(2)
            HStack {
                Text(record.department)
                if !record.doctor.isEmpty { Text("· \(record.doctor)") }
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MedicalLinkedPharmacyPurchaseRow: View {
    let record: MedicalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            HStack {
                Label(
                    AppDateFormatter.string(from: record.date),
                    systemImage: "pills.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                Spacer()
                Text(record.hospital)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let medicineNames = record.expenseItems.prefix(3).map(\.name).filter { !$0.isEmpty }
            Text(medicineNames.isEmpty ? "未记录药品" : medicineNames.joined(separator: " · "))
                .font(.subheadline)
                .lineLimit(2)
            HStack {
                Text("药品 \(record.expenseItems.count) 项")
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct MedicalExpenseItemRow: View {
    let item: MedicalExpenseItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.name).font(.headline)
            Spacer(minLength: 8)
            Text(MedicalValueFormatter.money(item.amount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct MedicalExpenseItemDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: MedicalExpenseItem

    var body: some View {
        NavigationStack {
            List {
                Section("项目") {
                    CopyableValueRow(title: "项目名称", value: item.name)
                    CopyableValueRow(
                        title: "金额",
                        value: MedicalValueFormatter.money(item.amount)
                    )
                    CopyableValueRow(
                        title: "数量",
                        value: MedicalValueFormatter.number(item.quantity)
                    )
                    CopyableValueRow(title: "单位", value: item.unit)
                }

                if !item.note.isEmpty {
                    Section("备注") {
                        Text(item.note)
                            .copyableText(item.note)
                    }
                }
            }
            .navigationTitle("费用项目")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
