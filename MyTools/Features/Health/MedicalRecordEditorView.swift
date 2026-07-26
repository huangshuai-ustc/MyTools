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
                if draft.record.isFollowUp {
                    associatedVisitSection
                }
                basicInformationSection
                expenseItemSection
                costSection
                attachmentSection
                tagAndNotesSection
            }
            .navigationTitle(editorTitle)
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
        Section(draft.record.isPharmacyPurchase ? "购药信息" : (draft.record.isFollowUp ? "复诊信息" : "就诊信息")) {
            DatePicker(
                draft.record.isPharmacyPurchase ? "购药日期：" : (draft.record.isFollowUp ? "复诊日期：" : "就诊日期："),
                selection: $draft.record.date,
                displayedComponents: .date
            )
            if draft.record.isPharmacyPurchase {
                safeField("药房：", prompt: "必填", text: $draft.record.hospital)
            } else {
                safeField("医院：", prompt: "必填", text: $draft.record.hospital)
                if !store.hospitalProfiles.isEmpty {
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
            }
            if draft.record.isPharmacyPurchase {
                multilineField("用药原因（可选）", prompt: "例如：感冒、发热", text: $draft.record.chiefComplaint)
            } else {
                safeField("科室：", prompt: "必填", text: $draft.record.department)
                safeField("医生：", prompt: "可选", text: $draft.record.doctor)
                multilineField("主诉", prompt: "例如：左膝疼痛", text: $draft.record.chiefComplaint)
                multilineField("初步诊断", prompt: "例如：半月板损伤", text: $draft.record.diagnosis)
                multilineField("治疗建议", prompt: "例如：保守治疗", text: $draft.record.treatment)
            }
        }
    }

    private var costSection: some View {
        Section {
            if linkedFollowUps.isEmpty {
                calculatedCostRow("总费用：", amount: currentItemsTotal)
            } else {
                calculatedCostRow("本次费用：", amount: currentItemsTotal)
                calculatedCostRow("复诊费用：", amount: linkedFollowUpCostSummary.totalCost)
                calculatedCostRow("总费用：", amount: aggregateTotalCost)
            }

            Picker(linkedFollowUps.isEmpty ? "支付方式：" : "本次支付方式：", selection: $draft.record.paymentMethod) {
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
        } else {
            guard !record.hospital.isEmpty,
                  !record.department.isEmpty,
                  !record.chiefComplaint.isEmpty,
                  !record.diagnosis.isEmpty else {
                reportError("医院、科室、主诉和初步诊断为必填项。")
                return
            }
        }

        let normalizedDate = MedicalRecord.normalizedDate(record.date)
        if record.isFollowUp {
            guard let associatedRecord else {
                reportError("关联的原就诊记录已不存在，无法保存这条复诊。")
                return
            }
            guard normalizedDate >= MedicalRecord.normalizedDate(associatedRecord.date) else {
                reportError("复诊日期不能早于原就诊日期。")
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
        guard !draft.record.isFollowUp else { return [] }
        return store.medicalRecords.filter { $0.parentRecordID == draft.record.id }
    }

    private var linkedFollowUpCostSummary: MedicalCostSummary {
        linkedFollowUps.reduce(MedicalCostSummary()) { $0 + $1.costSummary }
    }

    private var currentItemsTotal: Decimal {
        draft.record.expenseItemsTotal
    }

    private var aggregateTotalCost: Decimal {
        currentItemsTotal + linkedFollowUpCostSummary.totalCost
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
        if draft.record.isFollowUp || !linkedFollowUps.isEmpty {
            return MedicalVisitType.allCases.filter { $0 != .pharmacyPurchase }
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
