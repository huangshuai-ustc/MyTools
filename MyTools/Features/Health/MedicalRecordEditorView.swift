import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum MedicalCostInputSource {
    case insurance
    case selfPay
}

@MainActor
private final class MedicalRecordEditorDraft: ObservableObject {
    @Published var record: MedicalRecord
    @Published var insuranceCostText: String
    @Published var selfPayCostText: String
    @Published var costInputSource: MedicalCostInputSource = .insurance
    @Published var tagsText: String

    init(record: MedicalRecord) {
        self.record = record
        insuranceCostText = Self.decimalText(record.insuranceCost)
        selfPayCostText = Self.decimalText(record.selfPayCost)
        tagsText = record.tags.joined(separator: "、")
    }

    private static func decimalText(_ value: Decimal) -> String {
        value == 0 ? "" : NSDecimalNumber(decimal: value).stringValue
    }
}

struct MedicalRecordEditorView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: MedicalRecordEditorDraft
    @State private var editingExpenseItem: MedicalExpenseItem?
    @State private var editingPhysicalExamSession: PhysicalExamSession?
    @State private var editingPhysicalExamFinding: PhysicalExamFinding?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var showingAuthentication = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var didSave = false
    private let originalAttachmentIDs: Set<UUID>
    let isNew: Bool

    private let suggestedTags = ["骨科", "牙科", "感冒", "发烧", "胃病", "皮肤", "眼科"]

    init(record: MedicalRecord, isNew: Bool) {
        _draft = StateObject(wrappedValue: MedicalRecordEditorDraft(record: record))
        originalAttachmentIDs = Set(record.attachments.map(\.id))
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.record.hasAssociatedRecord {
                    associatedVisitSection
                }
                basicInformationSection
                if draft.record.isPhysicalExam {
                    physicalExamInformationSection
                    physicalExamSessionSection
                    physicalExamFindingSection
                }
                expenseItemSection
                costSection
                attachmentSection
                tagAndNotesSection
            }
            .navigationTitle(editorTitle)
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave)
                }
            }
            .sheet(item: $editingExpenseItem) { item in
                MedicalExpenseItemEditorView(item: item) { updated in
                    upsertExpenseItem(updated)
                }
                .iOSLargeSheet()
            }
            .sheet(item: $editingPhysicalExamSession) { session in
                PhysicalExamSessionEditorView(session: session) { updated in
                    upsertPhysicalExamSession(updated)
                }
                .iOSLargeSheet()
            }
            .sheet(item: $editingPhysicalExamFinding) { finding in
                PhysicalExamFindingEditorView(finding: finding) { updated in
                    upsertPhysicalExamFinding(updated)
                }
                .iOSLargeSheet()
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSAuthenticationSheet()
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image, .pdf],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
            .onChange(of: currentItemsTotal) { _, _ in
                guard draft.record.paymentMethod == .medicalInsuranceThenSelfPay else { return }
                synchronizeMixedCosts()
            }
            .onDisappear(perform: cleanUpUncommittedAttachments)
            .alert("无法完成操作", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var editorTitle: String {
        if draft.record.isPharmacyPurchase {
            return isNew ? "新增购药" : "编辑购药"
        }
        if draft.record.isPhysicalExam {
            return isNew ? "新增体检" : "编辑体检"
        }
        if draft.record.isFollowUp {
            return isNew ? "新增复诊" : "编辑复诊"
        }
        return isNew ? "新增就诊" : "编辑就诊"
    }

    private var associatedRecord: MedicalRecord? {
        guard let parentID = draft.record.parentRecordID else { return nil }
        return store.medicalRecords.first { $0.id == parentID }
    }

    private var associatedVisitSection: some View {
        Section("关联就诊") {
            if let associatedRecord {
                LabeledContent("原就诊") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(associatedRecord.hospital)
                        Text(
                            "\(associatedRecord.visitType.title) · \(associatedRecord.date.formatted(date: .abbreviated, time: .omitted))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("原就诊记录已不存在", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var basicInformationSection: some View {
        Section(draft.record.isPharmacyPurchase ? "购药信息" : (draft.record.isPhysicalExam ? "体检信息" : (draft.record.isFollowUp ? "复诊信息" : "就诊信息"))) {
            DatePicker(
                draft.record.isPharmacyPurchase ? "购药日期：" : (draft.record.isPhysicalExam ? "首个检查日期：" : (draft.record.isFollowUp ? "复诊日期：" : "就诊日期：")),
                selection: $draft.record.date,
                displayedComponents: .date
            )
            if draft.record.isPharmacyPurchase {
                safeField("药房：", prompt: "必填", text: $draft.record.hospital)
            } else {
                safeField(draft.record.isPhysicalExam ? "体检机构：" : "医院：", prompt: "必填", text: $draft.record.hospital)
                if !draft.record.isPhysicalExam, !store.hospitalProfiles.isEmpty {
                    Menu {
                        ForEach(sortedHospitalProfiles) { profile in
                            Button { applyHospital(profile) } label: {
                                if profile.id == selectedHospitalProfile?.id {
                                    Label(profile.name, systemImage: "checkmark")
                                } else {
                                    Text(profile.name)
                                }
                            }
                        }
                    } label: {
                        Label("选择已有医院", systemImage: "building.2")
                    }
                }
                if !draft.record.isPhysicalExam {
                    Picker("医院级别：", selection: $draft.record.hospitalLevel) {
                        ForEach(HospitalLevel.displayOrder) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    Picker("医院等次：", selection: $draft.record.hospitalGrade) {
                        ForEach(HospitalGrade.displayOrder) { grade in
                            Text(grade.title).tag(grade)
                        }
                    }
                    Picker("医院类型：", selection: $draft.record.hospitalCategory) {
                        ForEach(HospitalCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                }
            }
                if draft.record.hasAssociatedRecord {
                    LabeledContent(draft.record.isFollowUp ? "复诊方式：" : "记录类型：") {
                        Text(draft.record.visitType.shortTitle)
                    }
                } else {
                    Picker(draft.record.isFollowUp ? "复诊方式：" : "记录类型：", selection: $draft.record.visitType) {
                        ForEach(availableVisitTypes) { type in
                            Text(type.shortTitle).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.record.visitType) { oldValue, newValue in
                        if oldValue != .pharmacyPurchase, newValue == .pharmacyPurchase {
                            draft.record.paymentMethod = .selfPay
                            draft.insuranceCostText = ""
                        }
                        if newValue == .physicalExam {
                            ensurePhysicalExamDetails()
                        }
                    }
                }
                if draft.record.isPharmacyPurchase {
                    multilineField("用药原因（可选）", prompt: "例如：感冒、发热", text: $draft.record.chiefComplaint)
                } else if draft.record.isPhysicalExam {
                    multilineField("主检结论（可选）", prompt: "例如：轻度脂肪肝声像图", text: $draft.record.diagnosis)
                    multilineField("健康建议（可选）", prompt: "例如：年度复查腹部超声、肝功能及血脂", text: $draft.record.treatment)
                } else {
                safeField("科室：", prompt: "必填", text: $draft.record.department)
                safeField("医生：", prompt: "可选", text: $draft.record.doctor)
                multilineField("主诉", prompt: "例如：左膝疼痛", text: $draft.record.chiefComplaint)
                multilineField("初步诊断", prompt: "例如：半月板损伤", text: $draft.record.diagnosis)
                multilineField("治疗建议", prompt: "例如：保守治疗", text: $draft.record.treatment)
            }
        }
    }

    private var physicalExamInformationSection: some View {
        Section("报告信息") {
            safeField("体检套餐：", prompt: "例如：年度健康体检", text: physicalExamPackageBinding)
            if physicalExamReportDate != nil {
                DatePicker("报告日期：", selection: physicalExamReportDateBinding, displayedComponents: .date)
                Button("清除报告日期", role: .destructive) {
                    updatePhysicalExamDetails { $0.reportDate = nil }
                }
            } else {
                Button {
                    updatePhysicalExamDetails { $0.reportDate = draft.record.date }
                } label: {
                    Label("添加报告日期", systemImage: "calendar.badge.plus")
                }
            }
        }
    }

    private var physicalExamSessionSection: some View {
        Section("检查批次") {
            if physicalExamSessions.isEmpty {
                Text("至少添加一次实际检查日期；未完成的项目可在后续补检批次中继续记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(physicalExamSessions.sorted { $0.date < $1.date }) { session in
                Button { editingPhysicalExamSession = session } label: {
                    PhysicalExamSessionRow(session: session)
                }
                .buttonStyle(.plain)
                .appListRowStyle()
            }
            .onDelete(perform: deletePhysicalExamSessions)
            Button {
                editingPhysicalExamSession = PhysicalExamSession(date: draft.record.date)
            } label: {
                Label("添加检查批次", systemImage: "plus.circle")
            }
        }
    }

    private var physicalExamFindingSection: some View {
        Section("关注项") {
            if physicalExamFindings.isEmpty {
                Text("可记录体检报告中的异常、边缘结果和复查建议；完整报告可作为附件保存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(physicalExamFindings) { finding in
                Button { editingPhysicalExamFinding = finding } label: {
                    PhysicalExamFindingRow(finding: finding)
                }
                .buttonStyle(.plain)
                .appListRowStyle()
            }
            .onDelete(perform: deletePhysicalExamFindings)
            Button { editingPhysicalExamFinding = PhysicalExamFinding() } label: {
                Label("添加关注项", systemImage: "plus.circle")
            }
        }
    }

    private var costSection: some View {
        Section {
            if linkedRecords.isEmpty {
                calculatedCostRow("总费用：", amount: currentItemsTotal)
            } else {
                calculatedCostRow("本次费用：", amount: currentItemsTotal)
                if !linkedFollowUps.isEmpty {
                    calculatedCostRow("复诊费用：", amount: linkedFollowUpCostSummary.totalCost)
                }
                if !linkedPharmacyPurchases.isEmpty {
                    calculatedCostRow("关联购药费用：", amount: linkedPharmacyPurchaseCostSummary.totalCost)
                }
                calculatedCostRow("总费用：", amount: aggregateTotalCost)
            }

            Picker(linkedRecords.isEmpty ? "支付方式：" : "本次支付方式：", selection: $draft.record.paymentMethod) {
                ForEach(MedicalPaymentMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)

            switch draft.record.paymentMethod {
            case .selfPay:
                calculatedCostRow("自费：", amount: currentItemsTotal)
            case .medicalInsurance:
                calculatedCostRow("医保支付：", amount: currentItemsTotal)
            case .medicalInsuranceThenSelfPay:
                expressionField(
                    "医保支付：",
                    prompt: "填写后自动计算自费",
                    text: mixedCostBinding(for: .insurance)
                )
                expressionField(
                    "自费：",
                    prompt: "填写后自动计算医保支付",
                    text: mixedCostBinding(for: .selfPay)
                )
            }
        } header: {
            Text("费用")
        } footer: {
            if draft.record.paymentMethod == .medicalInsuranceThenSelfPay {
                Text("填写医保支付或自费中的任意一项，另一项会按本次费用自动计算。")
            }
        }
    }

    private var expenseItemSection: some View {
        Section {
            if draft.record.expenseItems.isEmpty {
                Text(draft.record.isPharmacyPurchase ? "暂无药品" : "暂无费用项目")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.record.expenseItems) { item in
                Button { editingExpenseItem = item } label: {
                    MedicalExpenseItemRow(item: item)
                }
                .buttonStyle(.plain)
                .appListRowStyle()
            }
            .onDelete { offsets in draft.record.expenseItems.remove(atOffsets: offsets) }

            Button { editingExpenseItem = MedicalExpenseItem() } label: {
                Label(draft.record.isPharmacyPurchase ? "添加药品" : "添加费用项目", systemImage: "plus.circle")
            }

        } header: {
            Text(draft.record.isPharmacyPurchase ? "药品" : "费用项目")
        }
    }

    private var attachmentSection: some View {
        Section {
            if draft.record.attachments.isEmpty {
                Text("暂无附件").foregroundStyle(.secondary)
            }
            ForEach(draft.record.attachments) { attachment in
                attachmentRow(attachment)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeAttachment(attachment)
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
            }

            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 20, matching: .images) {
                Label("从照片添加", systemImage: "photo.on.rectangle.angled")
            }
            Button { showingFileImporter = true } label: {
                Label("从文件添加图片或 PDF", systemImage: "folder.badge.plus")
            }
        } header: {
            Text("附件")
        } footer: {
            Text("附件保存在本机应用目录，并会随加密 .mytools 备份导出。")
        }
    }

    private var tagAndNotesSection: some View {
        Group {
            Section("标签") {
                safeField("标签：", prompt: "用逗号或顿号分隔", text: $draft.tagsText)
                Menu {
                    ForEach(suggestedTags, id: \.self) { tag in
                        Button(tag) { addSuggestedTag(tag) }
                    }
                } label: {
                    Label("添加常用标签", systemImage: "tag")
                }
            }
            Section("备注") {
                IMESafeMultilineTextField(prompt: "自由填写", text: $draft.record.notes)
            }
        }
    }

    private func safeField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            IMESafeTextField(prompt: prompt, text: text, alignment: .trailing)
                .frame(maxWidth: 260)
        }
    }

    private func multilineField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(title)：").font(.subheadline).foregroundStyle(.secondary)
            IMESafeMultilineTextField(prompt: prompt, text: text)
        }
    }

    private func expressionField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(prompt, text: text)
                    .multilineTextAlignment(.trailing)
#if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
#endif
                if containsArithmeticOperator(text.wrappedValue),
                   let value = DecimalTextParser.expression(from: text.wrappedValue) {
                    Text("= \(MedicalValueFormatter.money(value))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func calculatedCostRow(_ title: String, amount: Decimal?) -> some View {
        LabeledContent(title) {
            if let amount, amount >= 0 {
                Text(MedicalValueFormatter.money(amount))
                    .monospacedDigit()
            } else {
                Text("待核对").foregroundStyle(.orange)
            }
        }
    }

    private func attachmentRow(_ attachment: FileAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.kind.systemImage)
                .foregroundStyle(.pink)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.fileName).lineLimit(2)
                Text(attachment.displaySize).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("附件类型", selection: attachmentKindBinding(for: attachment.id)) {
                ForEach(AttachmentKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.vertical, 2)
    }

    private func attachmentKindBinding(for id: UUID) -> Binding<AttachmentKind> {
        Binding(
            get: { draft.record.attachments.first(where: { $0.id == id })?.kind ?? .other },
            set: { kind in
                guard let index = draft.record.attachments.firstIndex(where: { $0.id == id }) else { return }
                draft.record.attachments[index].kind = kind
            }
        )
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                draft.record.attachments.append(try store.importMedicalAttachment(from: url))
            }
        } catch {
            reportError(error.localizedDescription)
        }
    }

    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentStoreError.invalidFile
                }
                let contentType = item.supportedContentTypes.first ?? .jpeg
                let suffix = contentType.preferredFilenameExtension ?? "jpg"
                let name = "照片-\(UUID().uuidString.prefix(8)).\(suffix)"
                draft.record.attachments.append(
                    try store.saveMedicalPhoto(data: data, fileName: name, contentType: contentType)
                )
            } catch {
                reportError(error.localizedDescription)
            }
        }
    }

    private func removeAttachment(_ attachment: FileAttachment) {
        draft.record.attachments.removeAll { $0.id == attachment.id }
        if !originalAttachmentIDs.contains(attachment.id) {
            store.deleteUncommittedAttachment(attachment)
        }
    }

    private func upsertExpenseItem(_ item: MedicalExpenseItem) {
        if let index = draft.record.expenseItems.firstIndex(where: { $0.id == item.id }) {
            draft.record.expenseItems[index] = item
        } else {
            draft.record.expenseItems.append(item)
        }
    }

    private var physicalExamPackageBinding: Binding<String> {
        Binding(
            get: { draft.record.physicalExamDetails?.packageName ?? "" },
            set: { packageName in
                updatePhysicalExamDetails { $0.packageName = packageName }
            }
        )
    }

    private var physicalExamReportDate: Date? {
        draft.record.physicalExamDetails?.reportDate
    }

    private var physicalExamReportDateBinding: Binding<Date> {
        Binding(
            get: { physicalExamReportDate ?? draft.record.date },
            set: { reportDate in
                updatePhysicalExamDetails { $0.reportDate = reportDate }
            }
        )
    }

    private var physicalExamSessions: [PhysicalExamSession] {
        draft.record.physicalExamDetails?.sessions ?? []
    }

    private var physicalExamFindings: [PhysicalExamFinding] {
        draft.record.physicalExamDetails?.findings ?? []
    }

    private func ensurePhysicalExamDetails() {
        guard draft.record.physicalExamDetails == nil else { return }
        draft.record.physicalExamDetails = PhysicalExamDetails(
            sessions: [PhysicalExamSession(date: draft.record.date)]
        )
    }

    private func updatePhysicalExamDetails(_ update: (inout PhysicalExamDetails) -> Void) {
        var details = draft.record.physicalExamDetails ?? PhysicalExamDetails(
            sessions: [PhysicalExamSession(date: draft.record.date)]
        )
        update(&details)
        draft.record.physicalExamDetails = details
    }

    private func upsertPhysicalExamSession(_ session: PhysicalExamSession) {
        updatePhysicalExamDetails { details in
            if let index = details.sessions.firstIndex(where: { $0.id == session.id }) {
                details.sessions[index] = session
            } else {
                details.sessions.append(session)
            }
        }
    }

    private func deletePhysicalExamSessions(at offsets: IndexSet) {
        let sessions = physicalExamSessions.sorted { $0.date < $1.date }
        let ids = Set(offsets.map { sessions[$0].id })
        updatePhysicalExamDetails { details in
            details.sessions.removeAll { ids.contains($0.id) }
        }
    }

    private func upsertPhysicalExamFinding(_ finding: PhysicalExamFinding) {
        updatePhysicalExamDetails { details in
            if let index = details.findings.firstIndex(where: { $0.id == finding.id }) {
                details.findings[index] = finding
            } else {
                details.findings.append(finding)
            }
        }
    }

    private func deletePhysicalExamFindings(at offsets: IndexSet) {
        let ids = Set(offsets.map { physicalExamFindings[$0].id })
        updatePhysicalExamDetails { details in
            details.findings.removeAll { ids.contains($0.id) }
        }
    }

    private func addSuggestedTag(_ tag: String) {
        var tags = parsedTags()
        if !tags.contains(tag) { tags.append(tag) }
        draft.tagsText = tags.joined(separator: "、")
    }

    private func parsedTags() -> [String] {
        var result: [String] = []
        for rawTag in draft.tagsText.split(whereSeparator: { ",，、".contains($0) }) {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, !result.contains(tag) { result.append(tag) }
        }
        return result
    }

    private func requestSave() {
        commitPendingTextInput { save() }
    }

    private func save() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }

        var record = draft.record
        record.hospital = record.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
        record.department = record.department.trimmingCharacters(in: .whitespacesAndNewlines)
        record.chiefComplaint = record.chiefComplaint.trimmingCharacters(in: .whitespacesAndNewlines)
        record.diagnosis = record.diagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        record.treatment = record.treatment.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.isPharmacyPurchase {
            guard !record.hospital.isEmpty, !record.expenseItems.isEmpty else {
                reportError("请填写药房并至少添加一项药品。")
                return
            }
            record.hospitalLevel = .unspecified
            record.hospitalGrade = .unspecified
            record.hospitalCategory = .unspecified
            record.department = ""
            record.doctor = ""
            record.diagnosis = ""
            record.treatment = ""
        } else if record.isPhysicalExam {
            guard !record.hospital.isEmpty else {
                reportError("请填写体检机构。")
                return
            }
            guard var details = record.physicalExamDetails, !details.sessions.isEmpty else {
                reportError("请至少添加一个检查批次。")
                return
            }
            details.packageName = details.packageName.trimmingCharacters(in: .whitespacesAndNewlines)
            details.sessions = details.sessions.map { session in
                var session = session
                session.date = MedicalRecord.normalizedDate(session.date)
                session.institution = session.institution.trimmingCharacters(in: .whitespacesAndNewlines)
                session.completedItems = session.completedItems.trimmingCharacters(in: .whitespacesAndNewlines)
                session.notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                return session
            }
            details.findings = details.findings.map { finding in
                var finding = finding
                finding.item = finding.item.trimmingCharacters(in: .whitespacesAndNewlines)
                finding.result = finding.result.trimmingCharacters(in: .whitespacesAndNewlines)
                finding.recommendation = finding.recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
                return finding
            }
            record.physicalExamDetails = details
            record.hospitalLevel = .unspecified
            record.hospitalGrade = .unspecified
            record.hospitalCategory = .unspecified
            record.department = ""
            record.doctor = ""
            record.chiefComplaint = ""
        } else {
            guard !record.hospital.isEmpty,
                  !record.department.isEmpty,
                  !record.chiefComplaint.isEmpty,
                  !record.diagnosis.isEmpty else {
                reportError("医院、科室、主诉和初步诊断为必填项。")
                return
            }
        }

        let normalizedDate: Date
        if record.isPhysicalExam,
           let earliestSessionDate = record.physicalExamDetails?.sessions.map(\.date).min() {
            normalizedDate = MedicalRecord.normalizedDate(earliestSessionDate)
        } else {
            normalizedDate = MedicalRecord.normalizedDate(record.date)
        }
        if record.hasAssociatedRecord {
            guard let associatedRecord else {
                reportError("关联的原就诊记录已不存在，无法保存这条记录。")
                return
            }
            guard normalizedDate >= MedicalRecord.normalizedDate(associatedRecord.date) else {
                reportError(record.isPharmacyPurchase ? "购药日期不能早于关联就诊日期。" : "复诊日期不能早于原就诊日期。")
                return
            }
        }

        let totalCost = record.expenseItemsTotal

        let insuranceCost: Decimal
        let selfPayCost: Decimal
        switch record.paymentMethod {
        case .selfPay:
            insuranceCost = 0
            selfPayCost = totalCost
        case .medicalInsurance:
            insuranceCost = totalCost
            selfPayCost = 0
        case .medicalInsuranceThenSelfPay:
            switch draft.costInputSource {
            case .insurance:
                guard let value = validMixedCost(from: draft.insuranceCostText) else {
                    reportError("医保支付仅支持数字、加减乘除和括号，且不能超过本次费用。")
                    return
                }
                insuranceCost = value
                selfPayCost = totalCost - value
            case .selfPay:
                guard let value = validMixedCost(from: draft.selfPayCostText) else {
                    reportError("自费仅支持数字、加减乘除和括号，且不能超过本次费用。")
                    return
                }
                selfPayCost = value
                insuranceCost = totalCost - value
            }
        }

        record.date = normalizedDate
        record.totalCost = totalCost
        record.insuranceCost = insuranceCost
        record.selfPayCost = selfPayCost
        record.tags = parsedTags()
        record.updatedAt = Date()
        store.upsertMedicalRecord(record)
        didSave = true
        dismiss()
    }

    private func cancel() {
        cleanUpUncommittedAttachments()
        dismiss()
    }

    private func cleanUpUncommittedAttachments() {
        guard !didSave else { return }
        for attachment in draft.record.attachments where !originalAttachmentIDs.contains(attachment.id) {
            store.deleteUncommittedAttachment(attachment)
        }
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private var linkedFollowUps: [MedicalRecord] {
        guard !draft.record.hasAssociatedRecord else { return [] }
        return store.medicalRecords.filter {
            $0.parentRecordID == draft.record.id && !$0.isPharmacyPurchase
        }
    }

    private var linkedPharmacyPurchases: [MedicalRecord] {
        guard !draft.record.hasAssociatedRecord else { return [] }
        return store.medicalRecords.filter {
            $0.parentRecordID == draft.record.id && $0.isLinkedPharmacyPurchase
        }
    }

    private var linkedRecords: [MedicalRecord] {
        linkedFollowUps + linkedPharmacyPurchases
    }

    private var linkedFollowUpCostSummary: MedicalCostSummary {
        linkedFollowUps.reduce(MedicalCostSummary()) { $0 + $1.costSummary }
    }

    private var linkedPharmacyPurchaseCostSummary: MedicalCostSummary {
        linkedPharmacyPurchases.reduce(MedicalCostSummary()) { $0 + $1.costSummary }
    }

    private var currentItemsTotal: Decimal {
        draft.record.expenseItemsTotal
    }

    private var aggregateTotalCost: Decimal {
        currentItemsTotal + linkedFollowUpCostSummary.totalCost + linkedPharmacyPurchaseCostSummary.totalCost
    }

    private func mixedCostBinding(for source: MedicalCostInputSource) -> Binding<String> {
        Binding(
            get: {
                switch source {
                case .insurance: return draft.insuranceCostText
                case .selfPay: return draft.selfPayCostText
                }
            },
            set: { text in
                draft.costInputSource = source
                switch source {
                case .insurance: draft.insuranceCostText = text
                case .selfPay: draft.selfPayCostText = text
                }
                synchronizeMixedCosts(using: source)
            }
        )
    }

    private func synchronizeMixedCosts(using source: MedicalCostInputSource? = nil) {
        let source = source ?? draft.costInputSource
        switch source {
        case .insurance:
            guard let insurance = validMixedCost(from: draft.insuranceCostText) else {
                draft.selfPayCostText = ""
                return
            }
            draft.selfPayCostText = decimalInputText(currentItemsTotal - insurance)
        case .selfPay:
            guard let selfPay = validMixedCost(from: draft.selfPayCostText) else {
                draft.insuranceCostText = ""
                return
            }
            draft.insuranceCostText = decimalInputText(currentItemsTotal - selfPay)
        }
    }

    private func validMixedCost(from text: String) -> Decimal? {
        guard let value = DecimalTextParser.optionalExpression(from: text),
              value >= 0,
              value <= currentItemsTotal else { return nil }
        return value
    }

    private func decimalInputText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func containsArithmeticOperator(_ text: String) -> Bool {
        text.contains { "+-*/×÷（）()".contains($0) }
    }

    private var sortedHospitalProfiles: [HospitalProfile] {
        store.hospitalProfiles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var selectedHospitalProfile: HospitalProfile? {
        store.hospitalProfile(named: draft.record.hospital)
    }

    private var availableVisitTypes: [MedicalVisitType] {
        if draft.record.hasAssociatedRecord {
            return [draft.record.visitType]
        }
        if !linkedRecords.isEmpty {
            return MedicalVisitType.allCases.filter { $0 != .pharmacyPurchase && $0 != .physicalExam }
        }
        return MedicalVisitType.allCases
    }

    private func applyHospital(_ profile: HospitalProfile) {
        draft.record.hospital = profile.name
        draft.record.hospitalLevel = profile.level
        draft.record.hospitalGrade = profile.grade
        draft.record.hospitalCategory = profile.category
    }

}

private struct PhysicalExamSessionRow: View {
    let session: PhysicalExamSession

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            Text(session.date, format: .dateTime.year().month().day())
                .font(.headline)
            if !session.institution.isEmpty {
                Text(session.institution)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !session.completedItems.isEmpty {
                Text(session.completedItems)
                    .font(.subheadline)
                    .lineLimit(2)
            }
            if !session.notes.isEmpty {
                Text(session.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhysicalExamFindingRow: View {
    let finding: PhysicalExamFinding

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
            Text(finding.item.isEmpty ? "未命名关注项" : finding.item)
                .font(.headline)
            if !finding.result.isEmpty {
                Text(finding.result)
                    .font(.subheadline)
                    .lineLimit(2)
            }
            if !finding.recommendation.isEmpty {
                Text("建议：\(finding.recommendation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhysicalExamSessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: PhysicalExamSession
    let onSave: (PhysicalExamSession) -> Void

    init(session: PhysicalExamSession, onSave: @escaping (PhysicalExamSession) -> Void) {
        _session = State(initialValue: session)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("检查批次") {
                    DatePicker("检查日期：", selection: $session.date, displayedComponents: .date)
                    field("检查机构：", prompt: "可选；与体检机构不同才填写", text: $session.institution)
                    multilineField("完成项目", prompt: "例如：乙肝五项、肝胆脾胰双肾彩超、尿常规", text: $session.completedItems)
                }
                Section("备注") {
                    IMESafeMultilineTextField(prompt: "例如：因时间不足，后续补检", text: $session.notes)
                }
            }
            .navigationTitle("检查批次")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            session.date = MedicalRecord.normalizedDate(session.date)
                            session.institution = session.institution.trimmingCharacters(in: .whitespacesAndNewlines)
                            session.completedItems = session.completedItems.trimmingCharacters(in: .whitespacesAndNewlines)
                            session.notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(session)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            IMESafeTextField(prompt: prompt, text: text, alignment: .trailing)
                .frame(maxWidth: 260)
        }
    }

    private func multilineField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(title)：").font(.subheadline).foregroundStyle(.secondary)
            IMESafeMultilineTextField(prompt: prompt, text: text)
        }
    }
}

private struct PhysicalExamFindingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var finding: PhysicalExamFinding
    @State private var showingError = false
    let onSave: (PhysicalExamFinding) -> Void

    init(finding: PhysicalExamFinding, onSave: @escaping (PhysicalExamFinding) -> Void) {
        _finding = State(initialValue: finding)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("关注项") {
                    field("项目：", prompt: "例如：脂肪肝声像图（轻度）", text: $finding.item)
                    multilineField("结果", prompt: "例如：肝内回声呈弥漫性增强", text: $finding.result)
                    multilineField("建议", prompt: "例如：年度复查腹部超声、肝功能及血脂", text: $finding.recommendation)
                }
            }
            .navigationTitle("关注项")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            save()
                        }
                    }
                }
            }
            .alert("无法保存关注项", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text("请填写关注项名称。")
            }
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            IMESafeTextField(prompt: prompt, text: text, alignment: .trailing)
                .frame(maxWidth: 260)
        }
    }

    private func multilineField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(title)：").font(.subheadline).foregroundStyle(.secondary)
            IMESafeMultilineTextField(prompt: prompt, text: text)
        }
    }

    private func save() {
        finding.item = finding.item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finding.item.isEmpty else {
            showingError = true
            return
        }
        finding.result = finding.result.trimmingCharacters(in: .whitespacesAndNewlines)
        finding.recommendation = finding.recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(finding)
        dismiss()
    }
}

private struct MedicalExpenseItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: MedicalExpenseItem
    @State private var quantityText: String
    @State private var amountText: String
    @State private var showingError = false
    @State private var errorMessage = ""
    let onSave: (MedicalExpenseItem) -> Void

    init(item: MedicalExpenseItem, onSave: @escaping (MedicalExpenseItem) -> Void) {
        _item = State(initialValue: item)
        _quantityText = State(initialValue: Self.decimalText(item.quantity))
        _amountText = State(initialValue: Self.decimalText(item.amount))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("项目") {
                    field("项目名称：", prompt: "例如：布洛芬或膝关节 MRI", text: $item.name)
                    numericField("数量：", prompt: "例如 2", text: $quantityText, allowsExpression: false)
                    field("单位：", prompt: "例如：盒、次、项", text: $item.unit)
                    numericField("金额：", prompt: "例如 85.60+20", text: $amountText, allowsExpression: true)
                }
                Section("备注") {
                    IMESafeMultilineTextField(prompt: "可选", text: $item.note)
                }
            }
            .navigationTitle("费用项目")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            save()
                        }
                    }
                }
            }
            .alert("无法保存费用项目", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            IMESafeTextField(prompt: prompt, text: text, alignment: .trailing)
                .frame(maxWidth: 260)
        }
    }

    private func numericField(
        _ title: String,
        prompt: String,
        text: Binding<String>,
        allowsExpression: Bool
    ) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(prompt, text: text)
                    .multilineTextAlignment(.trailing)
#if os(iOS)
                    .keyboardType(allowsExpression ? .numbersAndPunctuation : .decimalPad)
#endif
                if allowsExpression,
                   text.wrappedValue.contains(where: { "+-*/×÷（）()".contains($0) }),
                   let value = DecimalTextParser.expression(from: text.wrappedValue) {
                    Text("= \(MedicalValueFormatter.money(value))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 260)
        }
    }

    private func save() {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            reportError("请填写项目名称。")
            return
        }
        guard let quantity = DecimalTextParser.decimal(from: quantityText), quantity > 0 else {
            reportError("数量必须大于零。")
            return
        }
        guard !unit.isEmpty else {
            reportError("请填写单位。")
            return
        }
        guard let amount = DecimalTextParser.expression(from: amountText), amount >= 0 else {
            reportError("金额仅支持数字、加减乘除和括号，计算结果不能小于零。")
            return
        }

        item.name = name
        item.quantity = quantity
        item.unit = unit
        item.amount = amount
        onSave(item)
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private static func decimalText(_ value: Decimal) -> String {
        value == 0 ? "" : NSDecimalNumber(decimal: value).stringValue
    }
}
