import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MedicalRecordDetailView: View {
    @EnvironmentObject private var store: HealthStore
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
