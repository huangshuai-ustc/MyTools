import SwiftUI

struct StorageDataView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var scanResult: StorageScanResult?
    @State private var isScanning = false
    @State private var showingCleanupConfirmation = false
    @State private var showingMessage = false
    @State private var message = ""

    var body: some View {
        List {
            if let scanResult {
                Section {
                    LabeledContent {
                        Text(formattedSize(scanResult.usage.totalBytes))
                    } label: {
                        Text("应用数据总计")
                    }
                        .font(.headline)
                    storageRow("本地档案", bytes: scanResult.usage.localVaultBytes)
                    storageRow(
                        "附件",
                        bytes: scanResult.usage.attachmentsBytes,
                        detail: "\(scanResult.usage.attachmentCount) 个文件"
                    )
                    storageRow("诊断日志", bytes: scanResult.usage.diagnosticsBytes)
                    if scanResult.usage.otherBytes > 0 {
                        storageRow("其他应用数据", bytes: scanResult.usage.otherBytes)
                    }
                } header: {
                    Text("占用空间")
                } footer: {
                    Text("仅统计\(AppMetadata.appName)在本机保存的应用数据，不包括 iOS 系统缓存和临时空间。")
                }

                Section {
                    if scanResult.missingAttachments.isEmpty {
                        Label("已引用的附件均存在", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(
                            "发现 \(scanResult.missingAttachments.count) 个附件文件缺失",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        Text(missingAttachmentSummary(scanResult.missingAttachments))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("数据完整性")
                }

                Section {
                    if unreferencedOrphans.isEmpty {
                        Label("没有发现未被记录引用的附件", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent {
                            Text("\(unreferencedOrphans.count) 个 · \(formattedSize(orphanBytes))")
                        } label: {
                            Text("可清理附件")
                        }
                        Button(role: .destructive) {
                            showingCleanupConfirmation = true
                        } label: {
                            Label("清理无效附件", systemImage: "trash")
                        }
                        .tint(.red)
                        .disabled(!auth.isAdmin || isScanning)

                        if !auth.isAdmin {
                            Text("进入管理员模式后可以清理无效附件。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("无效附件")
                } footer: {
                    Text("只会删除未被银行账单、健康档案或保密资料引用的附件，不会删除有效记录中的附件。")
                }
            } else if isScanning || !store.isInitialDataLoaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(store.isInitialDataLoaded ? "正在检查本地数据" : "正在载入本地档案")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    scan()
                } label: {
                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在检查")
                        }
                    } else {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isScanning || !store.isInitialDataLoaded)
            }
        }
        .navigationTitle("存储与数据")
        .adminModeIndicator()
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .task(id: store.isInitialDataLoaded) {
            guard store.isInitialDataLoaded else { return }
            scan()
        }
        .alert("清理无效附件", isPresented: $showingCleanupConfirmation) {
            Button("清理", role: .destructive) {
                cleanupOrphans()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(unreferencedOrphans.count) 个未被记录引用的附件，共 \(formattedSize(orphanBytes))。此操作无法撤销。")
        }
        .alert("存储与数据", isPresented: $showingMessage) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    private var referencedStoredFileNames: Set<String> {
        let medicalAttachments = store.healthStore.medicalRecords.flatMap(\.attachments)
        let cardAttachments = store.financeStore.cards.flatMap { card in
            card.statements.compactMap(\.attachment)
        }
        let secretAttachments = store.secretStore.secretItems.flatMap(\.attachments)
        return Set((medicalAttachments + cardAttachments + secretAttachments)
            .map(\.storedFileName)
            .filter { !$0.isEmpty })
    }

    private var orphanBytes: Int64 {
        unreferencedOrphans.reduce(Int64.zero) { $0 + $1.byteCount }
    }

    private var unreferencedOrphans: [OrphanAttachmentInfo] {
        guard let scanResult else { return [] }
        let referencedNames = referencedStoredFileNames
        return scanResult.orphanAttachments.filter {
            !referencedNames.contains($0.storedFileName)
        }
    }

    private func storageRow(_ title: String, bytes: Int64, detail: String? = nil) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedSize(bytes))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(title)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func missingAttachmentSummary(_ attachments: [MissingAttachmentInfo]) -> String {
        let names = attachments.prefix(5).map(\.storedFileName).joined(separator: "、")
        return attachments.count > 5 ? "\(names) 等" : names
    }

    private func scan() {
        guard store.isInitialDataLoaded, !isScanning else { return }
        isScanning = true
        let referencedNames = referencedStoredFileNames
        Task { @MainActor in
            let result: Result<StorageScanResult, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try StorageUsageService().scan(referencedStoredFileNames: referencedNames))
                } catch {
                    return .failure(error)
                }
            }.value
            isScanning = false
            switch result {
            case .success(let scanResult):
                self.scanResult = scanResult
            case .failure(let error):
                report(error.localizedDescription)
            }
        }
    }

    private func cleanupOrphans() {
        guard auth.isAdmin, scanResult != nil else { return }
        isScanning = true
        let orphans = unreferencedOrphans
        guard !orphans.isEmpty else {
            isScanning = false
            scan()
            return
        }
        Task { @MainActor in
            let result: Result<Int64, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try StorageUsageService().deleteOrphans(orphans))
                } catch {
                    return .failure(error)
                }
            }.value
            isScanning = false
            switch result {
            case .success(let removedBytes):
                report("已清理 \(orphans.count) 个无效附件，释放 \(formattedSize(removedBytes))。")
                scan()
            case .failure(let error):
                report(error.localizedDescription)
            }
        }
    }

    private func report(_ text: String) {
        message = text
        showingMessage = true
    }
}
