import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @State private var overview: DiagnosticLogOverview?
    @State private var exportDocument: DiagnosticLogDocument?
    @State private var isLoading = false
    @State private var isExporting = false
    @State private var showingExporter = false
    @State private var showingClearConfirmation = false
    @State private var message = ""
    @State private var showingMessage = false

    var body: some View {
        List {
            Section("日志文件") {
                if let overview {
                    LabeledContent("大小", value: ByteCountFormatter.string(
                        fromByteCount: overview.byteCount,
                        countStyle: .file
                    ))
                    if let createdAt = overview.createdAt {
                        LabeledContent("开始记录", value: AppDateFormatter.string(from: createdAt))
                    }
                    if let modifiedAt = overview.modifiedAt {
                        LabeledContent("最近写入", value: AppDateFormatter.string(from: modifiedAt))
                    }
                }

                Button(action: reload) {
                    Label("刷新日志", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || isExporting)

                Button(action: prepareExport) {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("正在准备日志")
                        }
                    } else {
                        Label("导出诊断日志", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isLoading || isExporting)

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("清空诊断日志", systemImage: "trash")
                }
                .tint(.red)
                .disabled(isLoading || isExporting)
            }

            Section("最近日志") {
                if isLoading, overview == nil {
                    HStack {
                        ProgressView()
                        Text("正在读取")
                    }
                    .foregroundStyle(.secondary)
                } else if let text = overview?.recentText, !text.isEmpty {
                    ScrollView(.horizontal) {
                        Text(text)
                            .appFont(.caption2.monospaced())
                            .copyableText(text)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .appNavigationTitle("调试信息")
        .adminModeIndicator()
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .task { reload() }
        .alert("清空诊断日志", isPresented: $showingClearConfirmation) {
            Button("清空", role: .destructive, action: clearLogs)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除安装以来的全部诊断日志。")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .myToolsDiagnosticLog,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result {
                report(error.localizedDescription)
            }
        }
        .alert("调试信息", isPresented: $showingMessage) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(message)
        }
        .diagnosticScreen("调试信息")
    }

    private func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                overview = try await Task.detached(priority: .utility) {
                    try DiagnosticLogger.shared.overview()
                }.value
            } catch {
                report(error.localizedDescription)
            }
        }
    }

    private func prepareExport() {
        guard !isExporting else { return }
        isExporting = true
        DiagnosticLogger.shared.log(.lifecycle, "用户请求导出诊断日志")
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try DiagnosticLogger.shared.exportData()
                }.value
                exportDocument = DiagnosticLogDocument(data: data)
                showingExporter = true
            } catch {
                report(error.localizedDescription)
            }
        }
    }

    private func clearLogs() {
        do {
            try DiagnosticLogger.shared.clear()
            reload()
        } catch {
            report(error.localizedDescription)
        }
    }

    private func report(_ value: String) {
        message = value
        showingMessage = true
    }

    private var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "\(AppMetadata.appName)-诊断日志-\(formatter.string(from: Date())).log"
    }
}

struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.myToolsDiagnosticLog] }
    static var writableContentTypes: [UTType] { [.myToolsDiagnosticLog] }

    let data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static var myToolsDiagnosticLog: UTType {
        UTType(filenameExtension: "log", conformingTo: .plainText) ?? .plainText
    }
}
