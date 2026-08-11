#if MYTOOLS_FEATURE_DOCUMENTS
import CoreGraphics
import SwiftUI

private enum CredentialOCRCandidateKey: Hashable {
    case holderName
    case documentNumber
    case issuingAuthority
    case issuedAt
    case validityStart
    case validityEnd
    case permanent
    case field(String)
}

private struct CredentialOCRCandidate: Identifiable {
    let key: CredentialOCRCandidateKey
    let label: String
    let value: String

    var id: String { "\(key)" }
}

struct CredentialOCRView: View {
    @EnvironmentObject private var store: DocumentsStore
    @Environment(\.dismiss) private var dismiss
    let attachment: FileAttachment
    let documentType: CredentialDocumentType
    let onApply: (CredentialOCRSuggestion) -> Void
    @State private var document: OCRDocument?
    @State private var image: CGImage?
    @State private var pageIndex = 0
    @State private var region = OCRNormalizedRegion.fullImage
    @State private var result: OCRResult?
    @State private var suggestion = CredentialOCRSuggestion()
    @State private var selectedKeys: Set<CredentialOCRCandidateKey> = []
    @State private var isLoading = true
    @State private var isRecognizing = false
    @State private var errorMessage: String?
    @State private var loadingTask: Task<Void, Never>?
    @State private var recognitionTask: Task<Void, Never>?
    private let service: any OCRRecognizing = VisionOCRService()

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在载入附件")
                        }
                    }
                } else if let image {
                    Section("识别区域") {
                        OCRRegionSelector(image: image, region: $region)
                            .frame(height: 280)
                        if let document, document.pageCount > 1 {
                            Stepper(
                                "第 \(pageIndex + 1) 页，共 \(document.pageCount) 页",
                                value: $pageIndex,
                                in: 0...(document.pageCount - 1)
                            )
                            .onChange(of: pageIndex) { _, _ in loadCurrentPage() }
                        }
                    }
                }

                if let result {
                    Section("识别文字") {
                        Text(result.fullText.isEmpty ? "未识别到文字" : result.fullText)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if !candidates.isEmpty {
                    Section("可填入字段") {
                        ForEach(candidates) { candidate in
                            Button {
                                toggle(candidate.key)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: selectedKeys.contains(candidate.key) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedKeys.contains(candidate.key) ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.label)
                                            .font(.subheadline.weight(.medium))
                                        Text(candidate.value)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("识别证照")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        recognize()
                    } label: {
                        if isRecognizing {
                            ProgressView()
                        } else {
                            Label("识别", systemImage: "text.viewfinder")
                        }
                    }
                    .disabled(image == nil || isLoading || isRecognizing)
                    if !candidates.isEmpty {
                        Button("应用") {
                            onApply(selectedSuggestion)
                            dismiss()
                        }
                        .disabled(selectedKeys.isEmpty)
                    }
                }
            }
            .task { loadAttachment() }
            .onDisappear {
                loadingTask?.cancel()
                recognitionTask?.cancel()
            }
            .alert(
                "文字识别失败",
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

    private var candidates: [CredentialOCRCandidate] {
        makeCandidates(from: suggestion)
    }

    private func makeCandidates(from suggestion: CredentialOCRSuggestion) -> [CredentialOCRCandidate] {
        var values: [CredentialOCRCandidate] = []
        append(suggestion.holderName, key: .holderName, label: "持有人", to: &values)
        append(suggestion.documentNumber, key: .documentNumber, label: "证件号码", to: &values)
        append(suggestion.issuingAuthority, key: .issuingAuthority, label: "签发机构", to: &values)
        append(
            suggestion.issuedAt.map { AppDateFormatter.string(from: $0) },
            key: .issuedAt,
            label: "签发日期",
            to: &values
        )
        append(
            suggestion.validityStart.map { AppDateFormatter.string(from: $0) },
            key: .validityStart,
            label: "有效期开始",
            to: &values
        )
        append(
            suggestion.validityEnd.map { AppDateFormatter.string(from: $0) },
            key: .validityEnd,
            label: "有效期截止",
            to: &values
        )
        if suggestion.isPermanent {
            values.append(CredentialOCRCandidate(key: .permanent, label: "有效期", value: "长期有效"))
        }
        for (label, value) in suggestion.fieldValues.sorted(by: { $0.key < $1.key }) {
            append(value, key: .field(label), label: label, to: &values)
        }
        return values
    }

    private var selectedSuggestion: CredentialOCRSuggestion {
        CredentialOCRSuggestion(
            holderName: selectedKeys.contains(.holderName) ? suggestion.holderName : nil,
            documentNumber: selectedKeys.contains(.documentNumber) ? suggestion.documentNumber : nil,
            issuingAuthority: selectedKeys.contains(.issuingAuthority) ? suggestion.issuingAuthority : nil,
            issuedAt: selectedKeys.contains(.issuedAt) ? suggestion.issuedAt : nil,
            validityStart: selectedKeys.contains(.validityStart) ? suggestion.validityStart : nil,
            validityEnd: selectedKeys.contains(.validityEnd) ? suggestion.validityEnd : nil,
            isPermanent: selectedKeys.contains(.permanent) && suggestion.isPermanent,
            fieldValues: suggestion.fieldValues.filter { selectedKeys.contains(.field($0.key)) }
        )
    }

    private func append(
        _ value: String?,
        key: CredentialOCRCandidateKey,
        label: String,
        to values: inout [CredentialOCRCandidate]
    ) {
        guard let value, !value.isEmpty else { return }
        values.append(CredentialOCRCandidate(key: key, label: label, value: value))
    }

    private func toggle(_ key: CredentialOCRCandidateKey) {
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
    }

    private func loadAttachment() {
        loadingTask?.cancel()
        isLoading = true
        loadingTask = Task { @MainActor in
            do {
                let data = try store.attachmentData(for: attachment)
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try OCRDocumentLoader.load(data: data, suggestedFileName: attachment.fileName)
                }.value
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try loaded.image(at: 0)
                }.value
                try Task.checkCancellation()
                document = loaded
                image = rendered
                pageIndex = 0
                region = .fullImage
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func loadCurrentPage() {
        guard let document else { return }
        let requestedPage = pageIndex
        loadingTask?.cancel()
        isLoading = true
        loadingTask = Task { @MainActor in
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try document.image(at: requestedPage)
                }.value
                try Task.checkCancellation()
                image = rendered
                region = .fullImage
                result = nil
                suggestion = CredentialOCRSuggestion()
                selectedKeys = []
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func recognize() {
        guard let image else { return }
        recognitionTask?.cancel()
        isRecognizing = true
        recognitionTask = Task { @MainActor in
            do {
                let configuration = OCRConfiguration(
                    languages: OCRLanguage.builtIn,
                    recognitionLevel: .accurate,
                    region: region
                )
                let recognized = try await service.recognize(
                    image: image,
                    configuration: configuration
                )
                try Task.checkCancellation()
                let parsed = CredentialOCRParser.parse(recognized, for: documentType)
                result = recognized
                suggestion = parsed
                selectedKeys = Set(makeCandidates(from: parsed).map(\.key))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isRecognizing = false
        }
    }

}

#endif
