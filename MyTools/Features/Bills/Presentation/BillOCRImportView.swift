#if MYTOOLS_FEATURE_BILLS
import CoreGraphics
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct BillOCRImportView: View {
    @EnvironmentObject private var store: BillsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var sourceFileName: String?
    @State private var document: OCRDocument?
    @State private var image: CGImage?
    @State private var region = OCRNormalizedRegion.fullImage
    @State private var result: OCRResult?
    @State private var suggestion = BillOCRSuggestion()
    @State private var selectedCandidateID: String?
    @State private var amountText = ""
    @State private var occurredAt = Date()
    @State private var secondsText = "0"
    @State private var direction = BillDirection.expense
    @State private var currency = CurrencyCode.cny
    @State private var merchant = ""
    @State private var paymentMethod = ""
    @State private var itemDescription = ""
    @State private var note = ""
    @State private var isLoading = false
    @State private var isRecognizing = false
    @State private var showingAuthentication = false
    @State private var errorMessage: String?
    @State private var workTask: Task<Void, Never>?
    private let service: any OCRRecognizing = VisionOCRService()

    var body: some View {
        NavigationStack {
            Form {
                Section("选择图片") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("从照片中选择", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("从文件中选择", systemImage: "folder")
                    }
                    if let sourceFileName {
                        LabeledContent("当前图片", value: sourceFileName)
                    }
                }

                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在载入图片")
                        }
                    }
                } else if let image {
                    Section("识别区域") {
                        OCRRegionSelector(image: image, region: $region)
                            .frame(height: 280)
                        Button(action: recognize) {
                            if isRecognizing {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("正在识别")
                                }
                            } else {
                                Label("识别文字", systemImage: "text.viewfinder")
                            }
                        }
                        .disabled(isRecognizing)
                    }
                }

                if let result {
                    Section("识别文字") {
                        Text(result.fullText.isEmpty ? "未识别到文字" : result.fullText)
                            .appFont(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    confirmationSections
                }
            }
            .appNavigationTitle("图片识别账单")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if result != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存", action: requestSave)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false,
                onCompletion: importFile
            )
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: saveAfterAuthentication)
                    .iOSAuthenticationSheet()
            }
            .onDisappear { workTask?.cancel() }
            .alert(
                "无法完成操作",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var confirmationSections: some View {
        if !suggestion.amountCandidates.isEmpty {
            Section("金额候选") {
                ForEach(suggestion.amountCandidates) { candidate in
                    Button {
                        selectedCandidateID = candidate.id
                        amountText = NSDecimalNumber(decimal: candidate.amount).stringValue
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedCandidateID == candidate.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedCandidateID == candidate.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(BillPresentation.amount(candidate.amount, currency: currency))
                                    .appFont(.body.weight(.medium))
                                Text(candidate.sourceLine)
                                    .appFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Section("确认账单") {
            Picker("收支类型", selection: $direction) {
                ForEach(BillDirection.allCases) { direction in
                    Text(direction.title).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            NumericFieldRow(title: "金额", prompt: "必填", text: $amountText)
            Picker("币种", selection: $currency) {
                ForEach(CurrencyCode.selectableCases) { currency in
                    Text(currency.title).tag(currency)
                }
            }
            .pickerStyle(.menu)
            DatePicker("交易时间", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
            LabeledContent("秒") {
                TextField("00", text: $secondsText)
                    .multilineTextAlignment(.trailing)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
            }
            safeField("商户", prompt: "可修改", text: $merchant)
            safeField("支付方式", prompt: "可修改", text: $paymentMethod)
            safeField("商品说明", prompt: "可选", text: $itemDescription)
        }
        Section("备注") {
            IMESafeMultilineTextField(prompt: "可选", text: $note)
        }
    }

    private func safeField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        FieldEditorRow(title: label, prompt: prompt, text: text, maxFieldWidth: .infinity)
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        workTask?.cancel()
        isLoading = true
        resetRecognition()
        workTask = Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw OCRError.invalidDocument
                }
                try await load(data: data, fileName: "账单图片.jpg")
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            workTask?.cancel()
            isLoading = true
            resetRecognition()
            workTask = Task { @MainActor in
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        try OCRDocumentLoader.load(from: url)
                    }.value
                    let image = try await Task.detached(priority: .userInitiated) {
                        try loaded.image(at: 0)
                    }.value
                    try Task.checkCancellation()
                    document = loaded
                    self.image = image
                    sourceFileName = url.lastPathComponent
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(data: Data, fileName: String) async throws {
        let loaded = try await Task.detached(priority: .userInitiated) {
            try OCRDocumentLoader.load(data: data, suggestedFileName: fileName)
        }.value
        let image = try await Task.detached(priority: .userInitiated) {
            try loaded.image(at: 0)
        }.value
        try Task.checkCancellation()
        document = loaded
        self.image = image
        sourceFileName = fileName
    }

    private func resetRecognition() {
        document = nil
        image = nil
        region = .fullImage
        result = nil
        suggestion = BillOCRSuggestion()
        selectedCandidateID = nil
        amountText = ""
    }

    private func recognize() {
        guard let image else { return }
        workTask?.cancel()
        isRecognizing = true
        workTask = Task { @MainActor in
            do {
                let recognized = try await service.recognize(
                    image: image,
                    configuration: OCRConfiguration(
                        languages: OCRLanguage.builtIn,
                        recognitionLevel: .accurate,
                        region: region
                    )
                )
                try Task.checkCancellation()
                let parsed = BillOCRParser.parse(recognized)
                result = recognized
                suggestion = parsed
                direction = parsed.direction
                occurredAt = parsed.occurredAt ?? Date()
                secondsText = String(Calendar.autoupdatingCurrent.component(.second, from: occurredAt))
                merchant = parsed.merchant ?? ""
                paymentMethod = parsed.paymentMethod ?? ""
                if let candidate = parsed.amountCandidates.first {
                    selectedCandidateID = candidate.id
                    amountText = NSDecimalNumber(decimal: candidate.amount).stringValue
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isRecognizing = false
        }
    }

    private func requestSave() {
        commitPendingTextInput { validateAndRequestSave() }
    }

    private func validateAndRequestSave() {
        guard let amount = DecimalTextParser.expression(from: amountText), amount > 0 else {
            errorMessage = "请选择或输入大于 0 的有效金额。"
            return
        }
        guard applySeconds() else {
            errorMessage = "请输入 0 到 59 之间的秒数。"
            return
        }
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        save(amount: amount)
    }

    private func applySeconds() -> Bool {
        guard let seconds = Int(secondsText.trimmingCharacters(in: .whitespacesAndNewlines)), (0...59).contains(seconds) else {
            return false
        }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurredAt)
        components.second = seconds
        guard let date = calendar.date(from: components) else { return false }
        occurredAt = date
        return true
    }

    private func saveAfterAuthentication() {
        showingAuthentication = false
        guard let amount = DecimalTextParser.expression(from: amountText), amount > 0 else {
            errorMessage = "请选择或输入大于 0 的有效金额。"
            return
        }
        save(amount: amount)
    }

    private func save(amount: Decimal) {
        let category: BillCategory
        switch direction {
        case .refund: category = .refund
        case .income: category = .salary
        case .neutral: category = .transfer
        case .expense: category = .other
        }
        store.upsert(BillRecord(
            occurredAt: occurredAt,
            direction: direction,
            amount: amount,
            currency: currency,
            merchant: merchant,
            itemDescription: itemDescription,
            paymentMethod: paymentMethod,
            category: category,
            note: note,
            origin: .ocr(fileName: sourceFileName)
        ))
        dismiss()
    }
}

#endif
