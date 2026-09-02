#if MYTOOLS_FEATURE_BILLS
import SwiftUI
import UniformTypeIdentifiers

struct BillImportView: View {
    @EnvironmentObject private var store: BillsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingFileImporter = false
    @State private var fileName: String?
    @State private var document: BillExchangeDocument?
    @State private var previewRecords: [BillRecord] = []
    @State private var outcome: BillImportOutcome?
    @State private var isLoading = false
    @State private var showingAuthentication = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    private let registry = BillImportAdapterRegistry()

    var body: some View {
        NavigationStack {
            Form {
                Section("账单文件") {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("选择账单文件", systemImage: "doc.badge.plus")
                    }
                    if let fileName {
                        DetailValueRow(title: "文件", value: fileName)
                    }
                    Text("支持方寸账单交换 JSON、微信支付 XLSX 和支付宝 CSV。银行卡账单需按具体银行格式继续接入。")
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在解析账单")
                        }
                    }
                }

                if let document {
                    Section("导入预览") {
                        DetailValueRow(title: "来源", value: document.source.providerName)
                        DetailValueRow(title: "协议版本", value: "\(document.version)")
                        DetailValueRow(title: "交易数量", value: "\(previewRecords.count)")
                    }
                    Section("交易记录") {
                        ForEach(Array(previewRecords.prefix(20))) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.displayTitle)
                                        .lineLimit(1)
                                    Text(AppDateFormatter.dateTimeWithoutSecondsString(from: record.occurredAt))
                                        .appFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(record.formattedAmount)
                                    .monospacedDigit()
                            }
                        }
                        if previewRecords.count > 20 {
                            Text("另有 \(previewRecords.count - 20) 笔将在确认后导入")
                                .appFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let outcome {
                    Section("导入结果") {
                        DetailValueRow(title: "新增", value: "\(outcome.insertedCount) 笔")
                        DetailValueRow(title: "更新", value: "\(outcome.updatedCount) 笔")
                    }
                }
            }
            .appNavigationTitle("导入账单")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(outcome == nil ? "取消" : "完成") { dismiss() }
                }
                if document != nil, outcome == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入", action: requestImport)
                            .disabled(previewRecords.isEmpty)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: Self.importContentTypes,
                allowsMultipleSelection: false,
                onCompletion: loadFile
            )
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: importAfterAuthentication)
                    .iOSAuthenticationSheet()
            }
            .onDisappear { importTask?.cancel() }
            .alert(
                "无法导入",
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

    private static var importContentTypes: [UTType] {
        var types: [UTType] = [.json, .commaSeparatedText, .plainText]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        return types
    }

    private func loadFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            fileName = url.lastPathComponent
            document = nil
            previewRecords = []
            outcome = nil
            isLoading = true
            importTask?.cancel()
            importTask = Task { @MainActor in
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        let hasAccess = url.startAccessingSecurityScopedResource()
                        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url)
                    }.value
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try registry.decode(data: data, fileName: url.lastPathComponent)
                    }.value
                    let records = try BillExchangeMapper.records(from: decoded)
                    try Task.checkCancellation()
                    document = decoded
                    previewRecords = records
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

    private func requestImport() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        performImport()
    }

    private func importAfterAuthentication() {
        showingAuthentication = false
        performImport()
    }

    private func performImport() {
        guard let document else { return }
        do {
            outcome = try store.importExchange(document)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#endif
