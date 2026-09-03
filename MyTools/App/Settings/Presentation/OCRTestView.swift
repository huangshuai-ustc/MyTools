import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct OCRTestView: View {
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var showingCamera = false
    @State private var document: OCRDocument?
    @State private var image: CGImage?
    @State private var pageIndex = 0
    @State private var region = OCRNormalizedRegion.fullImage
    @State private var selectedLanguages = OCRLanguage.defaultSelection
    @State private var recognitionLevel: OCRRecognitionLevel = .accurate
    @State private var result: OCRResult?
    @State private var isLoading = false
    @State private var isRecognizing = false
    @State private var errorMessage: String?
    @State private var loadingRequestID = UUID()
    @State private var loadingTask: Task<Void, Never>?
    @State private var recognitionTask: Task<Void, Never>?

    private let service = VisionOCRService()

    var body: some View {
        Form {
            sourceSection
            if let document {
                documentSection(document)
            }
            if let image {
                regionSection(image)
                recognitionSettingsSection
                recognitionSection
            }
        }
        .appNavigationTitle("文字识别测试")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .sheet(isPresented: $showingCamera) {
#if os(iOS)
            OCRCameraPicker(
                onCapture: { data in
                    showingCamera = false
                    importData(data, fileName: "相机照片.jpg")
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
#endif
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .onChange(of: pageIndex) { _, _ in
            guard document != nil else { return }
            loadCurrentPage()
        }
        .onDisappear {
            loadingTask?.cancel()
            recognitionTask?.cancel()
        }
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

    private var sourceSection: some View {
        Section("输入") {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Label("从照片选择", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("导入图片或 PDF", systemImage: "doc.badge.plus")
            }
#if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingCamera = true
                } label: {
                    Label("拍摄照片", systemImage: "camera")
                }
            }
#endif
            if isLoading {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func documentSection(_ document: OCRDocument) -> some View {
        Section("文档") {
            AppLabeledContentRow("文件") {
                Text(document.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            AppLabeledContentRow("类型") {
                Text(document.kind == .pdf ? "PDF" : "图片")
            }
            if document.pageCount > 1 {
                PickerFieldRow(title: "页面", selection: $pageIndex) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        Text("第 \(index + 1) 页").tag(index)
                    }
                }
            }
        }
    }

    private func regionSection(_ image: CGImage) -> some View {
        Section {
            OCRRegionSelector(image: image, region: $region)
                .padding(.vertical, 4)
            Button {
                region = .fullImage
            } label: {
                Label("重置识别区域", systemImage: "arrow.counterclockwise")
            }
            .disabled(region == .fullImage)
        } header: {
            Text("识别区域")
        }
    }

    private var recognitionSettingsSection: some View {
        Section("识别设置") {
            ForEach(OCRLanguage.builtIn) { language in
                ToggleFieldRow(title: language.displayName, isOn: languageBinding(for: language))
            }
            Picker("识别质量", selection: $recognitionLevel) {
                ForEach(OCRRecognitionLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var recognitionSection: some View {
        Section("结果") {
            if isRecognizing {
                Button(role: .cancel) {
                    cancelRecognition()
                } label: {
                    Label("取消识别", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    recognize()
                } label: {
                    Label("开始识别", systemImage: "text.viewfinder")
                }
                .disabled(isLoading || image == nil || selectedLanguages.isEmpty || !region.isUsable)
            }

            if isRecognizing {
                ProgressView()
            }
            if let result {
                if result.fullText.isEmpty {
                    Text("未识别到文字")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(result.fullText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 140, maxHeight: 320)
                    Button {
                        copyToPasteboard(result.fullText)
                    } label: {
                        Label("复制结果", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    private func languageBinding(for language: OCRLanguage) -> Binding<Bool> {
        Binding(
            get: { selectedLanguages.contains(language) },
            set: { isSelected in
                if isSelected {
                    selectedLanguages.insert(language)
                } else {
                    selectedLanguages.remove(language)
                }
            }
        )
    }

    private func importFile(_ completion: Result<[URL], Error>) {
        do {
            guard let url = try completion.get().first else { return }
            importDocument(from: url)
        } catch {
            show(error)
        }
    }

    private func importDocument(from url: URL) {
        let requestID = beginLoading()
        loadingTask = Task { @MainActor in
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try OCRDocumentLoader.load(from: url)
                }.value
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try loaded.image(at: 0)
                }.value
                try Task.checkCancellation()
                guard loadingRequestID == requestID else { return }
                install(loaded, image: rendered)
            } catch is CancellationError {
                return
            } catch {
                guard loadingRequestID == requestID else { return }
                show(error)
            }
            if loadingRequestID == requestID { isLoading = false }
        }
    }

    private func importData(_ data: Data, fileName: String) {
        let requestID = beginLoading()
        loadingTask = Task { @MainActor in
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try OCRDocumentLoader.load(data: data, suggestedFileName: fileName)
                }.value
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try loaded.image(at: 0)
                }.value
                try Task.checkCancellation()
                guard loadingRequestID == requestID else { return }
                install(loaded, image: rendered)
            } catch is CancellationError {
                return
            } catch {
                guard loadingRequestID == requestID else { return }
                show(error)
            }
            if loadingRequestID == requestID { isLoading = false }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        let requestID = beginLoading()
        loadingTask = Task { @MainActor in
            defer { selectedPhotoItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw OCRError.invalidDocument
                }
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try OCRDocumentLoader.load(data: data, suggestedFileName: "照片.jpg")
                }.value
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try loaded.image(at: 0)
                }.value
                try Task.checkCancellation()
                guard loadingRequestID == requestID else { return }
                install(loaded, image: rendered)
            } catch is CancellationError {
                return
            } catch {
                guard loadingRequestID == requestID else { return }
                show(error)
            }
            if loadingRequestID == requestID { isLoading = false }
        }
    }

    private func install(_ document: OCRDocument, image: CGImage) {
        self.document = document
        self.image = image
        region = .fullImage
        result = nil
    }

    private func loadCurrentPage() {
        guard let document else { return }
        let selectedPageIndex = pageIndex
        let requestID = beginPageLoading()
        isLoading = true
        loadingTask = Task { @MainActor in
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try document.image(at: selectedPageIndex)
                }.value
                try Task.checkCancellation()
                guard loadingRequestID == requestID else { return }
                image = rendered
                region = .fullImage
                result = nil
            } catch is CancellationError {
                return
            } catch {
                guard loadingRequestID == requestID else { return }
                show(error)
            }
            if loadingRequestID == requestID { isLoading = false }
        }
    }

    private func recognize() {
        guard let image, !selectedLanguages.isEmpty else { return }
        isRecognizing = true
        result = nil
        recognitionTask?.cancel()
        let configuration = OCRConfiguration(
            languages: OCRLanguage.builtIn.filter { selectedLanguages.contains($0) },
            recognitionLevel: recognitionLevel,
            region: region
        )
        recognitionTask = Task { @MainActor in
            do {
                let recognized = try await service.recognize(image: image, configuration: configuration)
                try Task.checkCancellation()
                result = recognized
            } catch is CancellationError {
                return
            } catch {
                show(error)
            }
            isRecognizing = false
        }
    }

    private func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognizing = false
    }

    private func beginLoading() -> UUID {
        loadingTask?.cancel()
        cancelRecognition()
        let requestID = UUID()
        loadingRequestID = requestID
        image = nil
        document = nil
        pageIndex = 0
        result = nil
        isLoading = true
        return requestID
    }

    private func beginPageLoading() -> UUID {
        loadingTask?.cancel()
        cancelRecognition()
        let requestID = UUID()
        loadingRequestID = requestID
        return requestID
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isLoading = false
        isRecognizing = false
    }

    private func copyToPasteboard(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
    }
}
