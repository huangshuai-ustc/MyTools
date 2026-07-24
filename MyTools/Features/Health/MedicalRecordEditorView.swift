import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
private final class MedicalRecordEditorDraft: ObservableObject {
    @Published var record: MedicalRecord
    @Published var totalCostText: String
    @Published var insuranceCostText: String
    @Published var selfPayCostText: String
    @Published var tagsText: String

    init(record: MedicalRecord) {
        self.record = record
        totalCostText = Self.decimalText(record.totalCost)
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
    @State private var editingPrescription: Prescription?
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
                basicInformationSection
                costSection
                prescriptionSection
                attachmentSection
                tagAndNotesSection
            }
            .navigationTitle(isNew ? "新增就诊" : "编辑就诊")
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
            .sheet(item: $editingPrescription) { prescription in
                PrescriptionEditorView(prescription: prescription) { updated in
                    upsertPrescription(updated)
                }
                .iOSLargeSheet()
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSLargeSheet()
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
            .onDisappear(perform: cleanUpUncommittedAttachments)
            .alert("无法完成操作", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var basicInformationSection: some View {
        Section("就诊信息") {
            DatePicker("就诊日期：", selection: $draft.record.date, displayedComponents: .date)
            safeField("医院：", prompt: "必填", text: $draft.record.hospital)
            safeField("科室：", prompt: "必填", text: $draft.record.department)
            safeField("医生：", prompt: "可选", text: $draft.record.doctor)
            Picker("就诊类型：", selection: $draft.record.visitType) {
                ForEach(MedicalVisitType.allCases) { type in Text(type.title).tag(type) }
            }
            .pickerStyle(.segmented)
            multilineField("主诉", prompt: "例如：左膝疼痛", text: $draft.record.chiefComplaint)
            multilineField("初步诊断", prompt: "例如：半月板损伤", text: $draft.record.diagnosis)
            multilineField("治疗建议", prompt: "例如：保守治疗", text: $draft.record.treatment)
        }
    }

    private var costSection: some View {
        Section {
            decimalField("总费用：", prompt: "0.00", text: $draft.totalCostText)
            decimalField("医保支付：", prompt: "0.00", text: $draft.insuranceCostText)
            decimalField("自费：", prompt: "留空自动计算", text: $draft.selfPayCostText)
            Picker("支付方式：", selection: $draft.record.paymentMethod) {
                ForEach(MedicalPaymentMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("费用")
        } footer: {
            Text("自费留空时按“总费用 - 医保支付”自动计算。")
        }
    }

    private var prescriptionSection: some View {
        Section("处方") {
            if draft.record.prescriptions.isEmpty {
                Text("暂无药物").foregroundStyle(.secondary)
            }
            ForEach(draft.record.prescriptions) { prescription in
                Button { editingPrescription = prescription } label: {
                    PrescriptionRow(prescription: prescription)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in draft.record.prescriptions.remove(atOffsets: offsets) }

            Button { editingPrescription = Prescription() } label: {
                Label("添加药物", systemImage: "plus.circle")
            }
        }
    }

    private var attachmentSection: some View {
        Section {
            if draft.record.attachments.isEmpty {
                Text("暂无附件").foregroundStyle(.secondary)
            }
            ForEach(draft.record.attachments) { attachment in
                attachmentRow(attachment)
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

    private func decimalField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
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
            Button(role: .destructive) { removeAttachment(attachment) } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("移除附件")
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

    private func upsertPrescription(_ prescription: Prescription) {
        if let index = draft.record.prescriptions.firstIndex(where: { $0.id == prescription.id }) {
            draft.record.prescriptions[index] = prescription
        } else {
            draft.record.prescriptions.append(prescription)
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
        guard !record.hospital.isEmpty,
              !record.department.isEmpty,
              !record.chiefComplaint.isEmpty,
              !record.diagnosis.isEmpty else {
            reportError("医院、科室、主诉和初步诊断为必填项。")
            return
        }

        guard let totalCost = DecimalTextParser.optionalDecimal(from: draft.totalCostText),
              let insuranceCost = DecimalTextParser.optionalDecimal(from: draft.insuranceCostText),
              totalCost >= 0,
              insuranceCost >= 0 else {
            reportError("请输入有效且不小于零的费用。")
            return
        }
        let selfPayCost: Decimal
        if draft.selfPayCostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selfPayCost = max(totalCost - insuranceCost, 0)
        } else if let value = DecimalTextParser.decimal(from: draft.selfPayCostText), value >= 0 {
            selfPayCost = value
        } else {
            reportError("请输入有效且不小于零的自费金额。")
            return
        }
        guard insuranceCost + selfPayCost <= totalCost else {
            reportError("医保支付与自费之和不能超过总费用。")
            return
        }

        record.date = MedicalRecord.normalizedDate(record.date)
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
}

private struct PrescriptionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prescription: Prescription
    @State private var showingError = false
    let onSave: (Prescription) -> Void

    init(prescription: Prescription, onSave: @escaping (Prescription) -> Void) {
        _prescription = State(initialValue: prescription)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("药物") {
                    field("药品名称：", prompt: "例如：布洛芬", text: $prescription.medicine)
                    field("规格：", prompt: "例如：0.3g", text: $prescription.specification)
                    field("频率：", prompt: "例如：每日 2 次", text: $prescription.frequency)
                    field("每次用量：", prompt: "例如：1 片", text: $prescription.dose)
                    field("疗程：", prompt: "例如：7 天", text: $prescription.duration)
                }
                Section("备注") {
                    IMESafeMultilineTextField(prompt: "例如：饭后服用", text: $prescription.remark)
                }
            }
            .navigationTitle("处方药物")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            let medicine = prescription.medicine.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !medicine.isEmpty else {
                                showingError = true
                                return
                            }
                            prescription.medicine = medicine
                            onSave(prescription)
                            dismiss()
                        }
                    }
                }
            }
            .alert("请填写药品名称", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            }
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            IMESafeTextField(prompt: prompt, text: text, alignment: .trailing)
                .frame(maxWidth: 260)
        }
    }
}
