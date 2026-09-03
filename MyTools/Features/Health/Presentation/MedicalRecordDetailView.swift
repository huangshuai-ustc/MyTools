#if MYTOOLS_FEATURE_HEALTH
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MedicalRecordDetailView: View {
    @EnvironmentObject private var store: HealthStore
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
        if record.isPharmacyPurchase { return "购药详情" }
        if record.isPhysicalExam { return "体检详情" }
        if record.isInpatientEpisode { return "住院详情" }
        if record.isInpatientDailyRecord { return "住院日详情" }
        if record.isFollowUp { return "复诊详情" }
        return "\(record.visitType.shortTitle)详情"
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
        .appNavigationTitle(detailNavigationTitle)
        .iOSLabeledBackButton("健康档案")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let record {
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
                        .accessibilityLabel("新增复诊或购药记录")
                        .help("新增复诊或购药记录")
                    }
                    Button { editingRecord = record } label: { Image(systemName: "square.and.pencil") }
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
            AttachmentPreviewSheet(
                attachment: attachment,
                url: store.attachmentURL(for: attachment),
                onDismiss: { previewAttachment = nil }
            )
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
                                Text(associatedRecord.hospital).appFont(.headline)
                                Text(
                                    "\(associatedRecord.visitType.title) · \(AppDateFormatter.string(from: associatedRecord.date))"
                                )
                                .appFont(.subheadline)
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
                MedicalInfoOverview(
                    record: record,
                    dateTitle: dayRecordDateTitle,
                    inpatientDayCount: record.isInpatientEpisode ? inpatientDayCount(for: record) : nil
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                if record.isPharmacyPurchase {
                    if !record.chiefComplaint.isEmpty {
                        DetailValueRow(title: "用药原因", value: record.chiefComplaint, alignment: .leading)
                    }
                } else if record.isPhysicalExam {
                    if !record.diagnosis.isEmpty {
                        MarkdownValueRow(
                            title: "查出的问题",
                            markdown: record.diagnosis,
                            alignment: detailTextAlignment(for: record.diagnosis)
                        )
                    }
                } else if record.isInpatientDailyRecord {
                    if !record.chiefComplaint.isEmpty {
                        DetailValueRow(title: "当天情况", value: record.chiefComplaint, alignment: .leading)
                    }
                    if !record.diagnosis.isEmpty {
                        DetailValueRow(title: "当天诊疗结果", value: record.diagnosis, alignment: .leading)
                    }
                    if !record.treatment.isEmpty {
                        DetailValueRow(title: "当天用药与操作", value: record.treatment, alignment: .leading)
                    }
                } else if record.isInpatientEpisode {
                    if !record.chiefComplaint.isEmpty {
                        DetailValueRow(title: "入院原因", value: record.chiefComplaint, alignment: .leading)
                    }
                    if !record.diagnosis.isEmpty {
                        DetailValueRow(title: "主要诊断", value: record.diagnosis, alignment: .leading)
                    }
                    if !record.treatment.isEmpty {
                        DetailValueRow(title: "治疗方案", value: record.treatment, alignment: .leading)
                    }
                } else {
                    if !record.chiefComplaint.isEmpty {
                        DetailValueRow(title: "主诉", value: record.chiefComplaint, alignment: .leading)
                    }
                    if !record.diagnosis.isEmpty {
                        DetailValueRow(title: "初步诊断", value: record.diagnosis, alignment: .leading)
                    }
                    if !record.treatment.isEmpty {
                        DetailValueRow(title: "治疗建议", value: record.treatment, alignment: .leading)
                    }
                }
            }

            if !record.hasAssociatedRecord, !record.isPharmacyPurchase {
                if record.isPhysicalExam {
                    if !followUps.isEmpty {
                        Section("检查批次") {
                            ForEach(followUps) { followUp in
                                NavigationLink {
                                    MedicalRecordDetailView(recordID: followUp.id)
                                } label: {
                                    MedicalPhysicalExamFollowUpRow(record: followUp)
                                }
                                .appListRowStyle()
                                .appDeleteSwipeAction(isEnabled: true) {
                                    store.deleteMedicalRecords(ids: [followUp.id])
                                }
                            }
                        }
                    }
                } else if record.isInpatient {
                    Section("住院日记录") {
                        if !outOfRangeInpatientDailyRecords.isEmpty {
                            Text("区间外但已有内容的住院日记录已保留，请确认住院日期范围。")
                                .appFont(.footnote)
                                .foregroundStyle(.orange)
                        }
                        if followUps.isEmpty {
                            Text("暂无住院日记录").foregroundStyle(.secondary)
                        }
                        ForEach(followUps) { followUp in
                            NavigationLink {
                                MedicalRecordDetailView(recordID: followUp.id)
                            } label: {
                                MedicalInpatientDayRow(record: followUp, parent: record)
                            }
                            .appListRowStyle()
                            .appDeleteSwipeAction(isEnabled: true) {
                                store.deleteMedicalRecords(ids: [followUp.id])
                            }
                        }
                    }
                } else {
                    if !followUps.isEmpty {
                        Section("复诊记录") {
                            ForEach(followUps) { followUp in
                                NavigationLink {
                                    MedicalRecordDetailView(recordID: followUp.id)
                                } label: {
                                    MedicalFollowUpRow(record: followUp)
                                }
                                .appListRowStyle()
                                .appDeleteSwipeAction(isEnabled: true) {
                                    store.deleteMedicalRecords(ids: [followUp.id])
                                }
                            }
                        }
                    }

                    if !pharmacyPurchases.isEmpty {
                        Section("关联药房购药") {
                            ForEach(pharmacyPurchases) { purchase in
                                NavigationLink {
                                    MedicalRecordDetailView(recordID: purchase.id)
                                } label: {
                                    MedicalLinkedPharmacyPurchaseRow(record: purchase)
                                }
                                .appListRowStyle()
                                .appDeleteSwipeAction(isEnabled: true) {
                                    store.deleteMedicalRecords(ids: [purchase.id])
                                }
                            }
                        }
                    }
                }
            }

            Section("费用") {
                MedicalCostOverview(
                    record: record,
                    episodeCostSummary: episodeCostSummary,
                    followUpCostSummary: followUpCostSummary,
                    pharmacyPurchaseCostSummary: pharmacyPurchaseCostSummary,
                    hasFollowUps: !followUps.isEmpty,
                    hasPharmacyPurchases: !pharmacyPurchases.isEmpty
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            if !record.expenseItems.isEmpty || record.hasAssociatedRecord == false {
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
                        DetailValueRow(
                            title: "项目合计",
                            value: MedicalValueFormatter.money(record.expenseItemsTotal)
                        )
                    }
                }
            }

            if !record.attachments.isEmpty {
                Section("附件") {
                    ForEach(record.attachments) { attachment in
                        Button { open(attachment) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: attachment.kind.systemImage)
                                    .foregroundStyle(.pink)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(attachment.fileName).lineLimit(2)
                                    Text("\(attachment.kind.title) · \(attachment.displaySize)")
                                        .appFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .appFont(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !record.tags.isEmpty {
                Section("标签") {
                    AppTagCapsules(tags: record.tags)
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

    private func detailTextAlignment(for value: String) -> TextAlignment {
        value.contains(where: { $0.isNewline }) ? .leading : .trailing
    }

    private func inpatientDayCount(for record: MedicalRecord) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let start = MedicalRecord.normalizedDate(record.date)
        let end = MedicalRecord.normalizedDate(record.inpatientEndDate ?? record.date)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    private func open(_ attachment: FileAttachment) {
        let url = store.attachmentURL(for: attachment)
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
    @Environment(\.appFontScale) private var fontScale
    let record: MedicalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack {
                Label(
                    AppDateFormatter.string(from: record.date),
                    systemImage: "calendar.badge.clock"
                )
                .appFont(.subheadline.weight(.semibold))
                .foregroundStyle(.mint)
                Spacer()
                Text("体检")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if !record.diagnosis.isEmpty {
                MarkdownText(record.diagnosis, preservesLineBreaks: true)
                    .appFont(.subheadline)
                    .foregroundStyle(.primary)
            }
            HStack {
                if !record.hospital.isEmpty {
                    Text(record.hospital)
                }
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .appFont(.caption)
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
    @Environment(\.appFontScale) private var fontScale
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
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack {
                Label(
                    isWithinRange ? "住院第\(dayNumber)天" : "区间外记录",
                    systemImage: isWithinRange ? "bed.double" : "exclamationmark.triangle"
                )
                    .appFont(.subheadline.weight(.semibold))
                    .foregroundStyle(isWithinRange ? .purple : .orange)
                Spacer()
                Text(AppDateFormatter.string(from: record.date))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if !summary.isEmpty {
                Text(summary)
                    .appFont(.subheadline)
                    .lineLimit(2)
            } else {
                Text("尚未记录当天情况")
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if !record.expenseItems.isEmpty {
                    Text("项目 \(record.expenseItems.count) 项")
                }
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MedicalFollowUpRow: View {
    @Environment(\.appFontScale) private var fontScale
    let record: MedicalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack {
                Label(
                    AppDateFormatter.string(from: record.date),
                    systemImage: "calendar.badge.clock"
                )
                .appFont(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                Spacer()
                Text(record.visitType.title)
                    .appFont(.caption)
                    .foregroundStyle(record.visitType.badgeColor)
            }
            Text(record.diagnosis)
                .appFont(.subheadline)
                .lineLimit(2)
            HStack {
                Text(record.department)
                if !record.doctor.isEmpty { Text("· \(record.doctor)") }
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MedicalLinkedPharmacyPurchaseRow: View {
    @Environment(\.appFontScale) private var fontScale
    let record: MedicalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack {
                Label(
                    AppDateFormatter.string(from: record.date),
                    systemImage: "pills.fill"
                )
                .appFont(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                Spacer()
                Text(record.hospital)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let medicineNames = record.expenseItems.prefix(3).map(\.name).filter { !$0.isEmpty }
            Text(medicineNames.isEmpty ? "未记录药品" : medicineNames.joined(separator: " · "))
                .appFont(.subheadline)
                .lineLimit(2)
            HStack {
                Text("药品 \(record.expenseItems.count) 项")
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost)).monospacedDigit()
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MedicalInfoOverview: View {
    let record: MedicalRecord
    let dateTitle: String
    let inpatientDayCount: Int?

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            alignment: .leading,
            spacing: 14
        ) {
            MedicalCostCell(
                title: dateTitle,
                value: AppDateFormatter.string(from: record.date)
            )
            if record.isInpatientEpisode {
                MedicalCostCell(
                    title: "出院日期",
                    value: AppDateFormatter.string(from: record.inpatientEndDate ?? record.date)
                )
                MedicalCostCell(
                    title: "住院天数",
                    value: inpatientDayCount.map { "\($0) 天" } ?? ""
                )
            }
            MedicalCostCell(title: record.institutionLabel, value: record.hospital)
            if !record.hospitalClassificationTitles.isEmpty {
                MedicalCostCell(
                    title: "机构分类",
                    value: record.hospitalClassificationTitles.joined(separator: " · ")
                )
            }
            MedicalCostCell(title: "类型", value: record.visitType.title)
            if record.isInpatient {
                if !record.department.isEmpty {
                    MedicalCostCell(title: "科室", value: record.department)
                }
                if !record.doctor.isEmpty {
                    MedicalCostCell(title: "医生", value: record.doctor)
                }
            } else if !record.isPhysicalExam, !record.isPharmacyPurchase {
                if !record.department.isEmpty {
                    MedicalCostCell(title: "科室", value: record.department)
                }
                if !record.doctor.isEmpty {
                    MedicalCostCell(title: "医生", value: record.doctor)
                }
            }
            if record.isPhysicalExam,
               let packageName = record.physicalExamDetails?.packageName,
               !packageName.isEmpty {
                MedicalCostCell(title: "主要内容", value: packageName)
            }
        }
    }
}

private struct MedicalCostOverview: View {
    let record: MedicalRecord
    let episodeCostSummary: MedicalCostSummary
    let followUpCostSummary: MedicalCostSummary
    let pharmacyPurchaseCostSummary: MedicalCostSummary
    let hasFollowUps: Bool
    let hasPharmacyPurchases: Bool

    private var showBreakdown: Bool {
        !record.hasAssociatedRecord && (hasFollowUps || hasPharmacyPurchases)
    }

    private var followUpLabel: String {
        record.isPhysicalExam ? "其他批次费用"
            : (record.isInpatient ? "住院日费用" : "复诊费用")
    }

    private var paymentLabel: String {
        hasFollowUps || hasPharmacyPurchases ? "本次支付方式" : "支付方式"
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            alignment: .leading,
            spacing: 14
        ) {
            if showBreakdown {
                MedicalCostCell(
                    title: "本次费用",
                    value: MedicalValueFormatter.money(record.totalCost)
                )
                if hasFollowUps {
                    MedicalCostCell(
                        title: followUpLabel,
                        value: MedicalValueFormatter.money(followUpCostSummary.totalCost)
                    )
                }
                if hasPharmacyPurchases {
                    MedicalCostCell(
                        title: "关联购药费用",
                        value: MedicalValueFormatter.money(pharmacyPurchaseCostSummary.totalCost)
                    )
                }
            }
            MedicalCostCell(
                title: "总费用",
                value: MedicalValueFormatter.money(episodeCostSummary.totalCost)
            )
            MedicalCostCell(
                title: "医保支付",
                value: MedicalValueFormatter.money(episodeCostSummary.insuranceCost)
            )
            MedicalCostCell(
                title: "自费",
                value: MedicalValueFormatter.money(episodeCostSummary.selfPayCost)
            )
            MedicalCostCell(
                title: paymentLabel,
                value: record.paymentMethod.title
            )
        }
    }
}

private typealias MedicalCostCell = AppMetricCell

struct MedicalExpenseItemRow: View {
    let item: MedicalExpenseItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.name).appFont(.headline)
            Spacer(minLength: 8)
            Text(MedicalValueFormatter.money(item.amount))
                .appFont(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct MedicalExpenseItemDetailView: View {
    let item: MedicalExpenseItem

    var body: some View {
        NavigationStack {
            List {
                Section("项目") {
                    DetailValueRow(title: "项目名称", value: item.name)
                    DetailValueRow(
                        title: "金额",
                        value: MedicalValueFormatter.money(item.amount)
                    )
                    DetailValueRow(
                        title: "数量",
                        value: MedicalValueFormatter.number(item.quantity)
                    )
                    DetailValueRow(title: "单位", value: item.unit)
                }

                if !item.note.isEmpty {
                    Section("备注") {
                        Text(item.note)
                            .copyableText(item.note)
                    }
                }
            }
            .appNavigationTitle("费用项目")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }
}

#endif
