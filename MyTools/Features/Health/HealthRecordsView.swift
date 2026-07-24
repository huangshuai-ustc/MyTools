import SwiftUI
#if os(iOS)
import QuickLook
#elseif os(macOS)
import AppKit
#endif

struct HealthRecordsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var selectedTag = ""
    @State private var selectedYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    @State private var editingRecord: MedicalRecord?

    private var displayedRecords: [MedicalRecord] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.medicalRecords
            .filter { selectedTag.isEmpty || $0.tags.contains(selectedTag) }
            .filter { record in
                searchTerm.isEmpty
                    || record.hospital.localizedCaseInsensitiveContains(searchTerm)
                    || record.department.localizedCaseInsensitiveContains(searchTerm)
                    || record.doctor.localizedCaseInsensitiveContains(searchTerm)
                    || record.chiefComplaint.localizedCaseInsensitiveContains(searchTerm)
                    || record.diagnosis.localizedCaseInsensitiveContains(searchTerm)
                    || record.treatment.localizedCaseInsensitiveContains(searchTerm)
                    || record.tags.contains { $0.localizedCaseInsensitiveContains(searchTerm) }
                    || record.prescriptions.contains { $0.medicine.localizedCaseInsensitiveContains(searchTerm) }
                    || record.attachments.contains {
                        $0.fileName.localizedCaseInsensitiveContains(searchTerm)
                            || $0.kind.title.localizedCaseInsensitiveContains(searchTerm)
                    }
            }
            .sorted { $0.date > $1.date }
    }

    private var groupedRecords: [MedicalYearGroup] {
        Dictionary(grouping: displayedRecords) { calendar.component(.year, from: $0.date) }
            .map { MedicalYearGroup(year: $0.key, records: $0.value) }
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

    private var annualRecords: [MedicalRecord] {
        store.medicalRecords.filter { calendar.component(.year, from: $0.date) == selectedYear }
    }

    private var annualTotal: Decimal { annualRecords.reduce(0) { $0 + $1.totalCost } }
    private var annualInsurance: Decimal { annualRecords.reduce(0) { $0 + $1.insuranceCost } }
    private var annualSelfPay: Decimal { annualRecords.reduce(0) { $0 + $1.selfPayCost } }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
    }

    var body: some View {
        List {
            Section("年度费用") {
                Picker("统计年份", selection: $selectedYear) {
                    ForEach(availableYears, id: \.self) { year in
                        Text(verbatim: "\(year) 年").tag(year)
                    }
                }
                .pickerStyle(.menu)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { annualMetrics }
                    VStack(alignment: .leading, spacing: 9) { annualMetrics }
                }
                .padding(.vertical, 4)
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

            if displayedRecords.isEmpty {
                Section {
                    ContentUnavailableView(
                        store.medicalRecords.isEmpty ? "暂无就诊记录" : "没有匹配的就诊记录",
                        systemImage: store.medicalRecords.isEmpty ? "cross.case" : "magnifyingglass",
                        description: Text(store.medicalRecords.isEmpty ? "点右上角编辑并验证身份后记录第一次就诊" : "请尝试其他医院、科室、诊断、药物或标签")
                    )
                }
            }

            ForEach(groupedRecords) { group in
                Section {
                    if auth.isAdmin {
                        ForEach(group.records) { record in recordLink(record) }
                            .onDelete { offsets in deleteRecords(at: offsets, from: group.records) }
                    } else {
                        ForEach(group.records) { record in recordLink(record) }
                    }
                } header: {
                    Text(verbatim: "\(group.year) 年")
                }
            }
        }
        .navigationTitle("健康档案")
        .iOSLabeledBackButton("工具箱")
        .searchable(text: $query, prompt: "搜索医院、诊断、药物或标签")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton { editingRecord = MedicalRecord() }
                if auth.isAdmin {
                    Button { editingRecord = MedicalRecord() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增就诊记录")
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

    @ViewBuilder
    private var annualMetrics: some View {
        medicalMetric("总医疗费用", value: annualTotal, color: .primary)
        medicalMetric("医保支付", value: annualInsurance, color: .blue)
        medicalMetric("自费", value: annualSelfPay, color: .orange)
    }

    private func medicalMetric(_ title: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MedicalValueFormatter.money(value))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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

    private func recordLink(_ record: MedicalRecord) -> some View {
        NavigationLink {
            MedicalRecordDetailView(recordID: record.id)
        } label: {
            MedicalRecordRow(record: record)
        }
    }

    private func deleteRecords(at offsets: IndexSet, from records: [MedicalRecord]) {
        store.deleteMedicalRecords(ids: Set(offsets.map { records[$0].id }))
    }
}

private struct MedicalYearGroup: Identifiable {
    let year: Int
    let records: [MedicalRecord]
    var id: Int { year }
}

private extension MedicalVisitType {
    var badgeColor: Color {
        switch self {
        case .outpatient: return .blue
        case .emergency: return .red
        case .inpatient: return .purple
        }
    }
}

private struct MedicalRecordRow: View {
    let record: MedicalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.hospital).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text(record.visitType.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(record.visitType.badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(record.visitType.badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
            HStack {
                Text(record.department)
                if !record.doctor.isEmpty { Text("· \(record.doctor)") }
                Spacer()
                Text(record.date, format: .dateTime.year().month().day())
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(record.diagnosis)
                .font(.subheadline)
                .lineLimit(2)

            HStack {
                if !record.tags.isEmpty {
                    Text(record.tags.prefix(2).joined(separator: " · "))
                        .lineLimit(1)
                }
                Spacer()
                Text(MedicalValueFormatter.money(record.totalCost))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct MedicalRecordDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    let recordID: UUID
    @State private var editingRecord: MedicalRecord?
    @State private var previewAttachment: FileAttachment?
    @State private var attachmentError = ""
    @State private var showingAttachmentError = false

    private var record: MedicalRecord? {
        store.medicalRecords.first { $0.id == recordID }
    }

    var body: some View {
        Group {
            if let record {
                recordList(record)
            } else {
                ContentUnavailableView("就诊记录已不存在", systemImage: "cross.case")
            }
        }
        .navigationTitle(record?.hospital ?? "就诊详情")
        .iOSLabeledBackButton("健康档案")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton()
                if auth.isAdmin, let record {
                    Button { editingRecord = record } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("编辑就诊记录")
                }
            }
        }
        .sheet(item: $editingRecord) { record in
            MedicalRecordEditorView(record: record, isNew: false)
                .id(record.id)
                .iOSLargeSheet()
        }
#if os(iOS)
        .sheet(item: $previewAttachment) { attachment in
            NavigationStack {
                MedicalAttachmentPreview(url: store.medicalAttachmentURL(for: attachment))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(attachment.fileName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") {
                                previewAttachment = nil
                            }
                        }
                    }
            }
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
            Section("就诊信息") {
                CopyableValueRow(title: "日期", value: record.date.formatted(date: .long, time: .omitted))
                CopyableValueRow(title: "医院", value: record.hospital)
                CopyableValueRow(title: "科室", value: record.department)
                if !record.doctor.isEmpty { CopyableValueRow(title: "医生", value: record.doctor) }
                CopyableValueRow(title: "类型", value: record.visitType.title)
                CopyableValueRow(title: "主诉", value: record.chiefComplaint)
                CopyableValueRow(title: "初步诊断", value: record.diagnosis)
                CopyableValueRow(title: "治疗建议", value: record.treatment)
            }

            Section("费用") {
                CopyableValueRow(title: "总费用", value: MedicalValueFormatter.money(record.totalCost))
                CopyableValueRow(title: "医保支付", value: MedicalValueFormatter.money(record.insuranceCost))
                CopyableValueRow(title: "自费", value: MedicalValueFormatter.money(record.selfPayCost))
                CopyableValueRow(title: "支付方式", value: record.paymentMethod.title)
            }

            Section("处方") {
                if record.prescriptions.isEmpty {
                    Text("未记录处方").foregroundStyle(.secondary)
                }
                ForEach(record.prescriptions) { prescription in
                    PrescriptionRow(prescription: prescription)
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
                    }
                    .buttonStyle(.plain)
                }
            }

            if !record.tags.isEmpty {
                Section("标签") {
                    Text(record.tags.joined(separator: " · ")).textSelection(.enabled)
                }
            }

            if !record.notes.isEmpty {
                Section("备注") { Text(record.notes).textSelection(.enabled) }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
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

struct PrescriptionRow: View {
    let prescription: Prescription

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(prescription.medicine).font(.headline)
            let details = [prescription.specification, prescription.frequency, prescription.dose, prescription.duration]
                .filter { !$0.isEmpty }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !prescription.remark.isEmpty {
                Text(prescription.remark).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .textSelection(.enabled)
    }
}

#if os(iOS)
private struct MedicalAttachmentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
