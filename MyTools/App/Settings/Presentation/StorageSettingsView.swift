import SwiftUI

struct StorageDataView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var moduleSettings: ToolModuleSettings
    @State private var scanResult: StorageScanResult?
    @State private var redundantDataReport: RedundantDataCleanupReport?
    @State private var isScanning = false
    @State private var showingCleanupConfirmation = false
    @State private var showingRedundantCleanupConfirmation = false
    @State private var deletionConfirmationModule: ToolModule?
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
                    Text("仅统计\(AppMetadata.appName)在本机保存的应用数据，不包括 iOS 系统缓存和临时空间。iCloud 用量是云端独立口径，可能包含待回收的历史记录或附件版本，清理后需要等待 Apple 服务回收。")
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
                    Text("只会删除未被业务记录引用的附件，不会删除有效记录中的附件。")
                }

                Section {
                    if let redundantDataReport, redundantDataReport.isEmpty {
                        Label("没有发现不适用的字段值", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if let redundantDataReport {
                        LabeledContent("可清理字段") {
                            Text("\(redundantDataReport.affectedFieldCount) 个")
                        }
                        ForEach(redundantDataReport.findings) { finding in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(finding.title, systemImage: finding.module.systemImage)
                                    .foregroundStyle(finding.module.tint)
                                Text(finding.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Spacer()
                                    Text("\(finding.affectedRecordCount) 条 · \(finding.affectedFieldCount) 个字段")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button(role: .destructive) {
                            showingRedundantCleanupConfirmation = true
                        } label: {
                            Label("清理不适用字段", systemImage: "eraser")
                        }
                        .tint(.red)
                        .disabled(!auth.isAdmin || isScanning)

                        if !auth.isAdmin {
                            Text("进入管理员模式后可以清理不适用字段。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("冗余字段")
                } footer: {
                    Text("只检查当前已编译且已开启的功能。关闭功能的数据和未编译功能的不透明数据不会被读取或修改。")
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

            if let deletion = store.pendingModuleLocalDataDeletion {
                Section {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("已删除“\(deletion.module.title)”的本地数据")
                                Text("\(remainingSeconds(until: deletion.expiresAt, at: context.date)) 秒后完成清理")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.undoModuleLocalDataDeletion(id: deletion.id)
                            } label: {
                                Label("撤回", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(context.date >= deletion.expiresAt)
                        }
                    }
                } header: {
                    Text("可撤回")
                } footer: {
                    Text("撤回会恢复刚才删除的记录；在此期间新增的其他数据不会被覆盖。")
                }
            }

            Section {
                ForEach(moduleSettings.orderedModules) { module in
                    Button(role: .destructive) {
                        deletionConfirmationModule = module
                    } label: {
                        HStack(spacing: 12) {
                            Label(module.title, systemImage: module.systemImage)
                            Spacer()
                            Image(systemName: "trash")
                                .accessibilityHidden(true)
                        }
                    }
                    .disabled(
                        !auth.isAdmin
                            || !store.isInitialDataLoaded
                            || store.pendingModuleLocalDataDeletion != nil
                    )
                    .accessibilityLabel("删除\(module.title)的所有本地数据")
                }
            } header: {
                Text("删除功能数据")
            } footer: {
                if auth.isAdmin {
                    Text("每次只能删除一个功能的数据。操作需要经过两次各 10 秒的确认，删除后还有 10 秒可以撤回。")
                } else {
                    Text("进入管理员模式后可以删除功能数据。")
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
        .alert("清理不适用字段", isPresented: $showingRedundantCleanupConfirmation) {
            Button("清理", role: .destructive) {
                cleanupRedundantData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从当前档案中删除 \(redundantDataReport?.affectedFieldCount ?? 0) 个不适用字段值。此操作无法撤销，已经导出的旧备份不会被修改。")
        }
        .alert("存储与数据", isPresented: $showingMessage) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(message)
        }
        .sheet(item: $deletionConfirmationModule) { module in
            ModuleLocalDataDeletionConfirmationView(
                module: module,
                cloudSyncEnabled: store.cloudSync.isEnabled
            ) {
                store.beginModuleLocalDataDeletion(for: module)
            }
        }
    }

    private var referencedStoredFileNames: Set<String> {
        store.referencedAttachmentStoredFileNames
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
        redundantDataReport = store.scanRedundantData()
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

    private func cleanupRedundantData() {
        guard auth.isAdmin, redundantDataReport?.isEmpty == false else { return }
        let cleanupReport = store.cleanupRedundantData()
        guard !cleanupReport.isEmpty else {
            report("没有可清理的不适用字段，或当前档案暂时无法安全写入。")
            scan()
            return
        }
        report("已清理 \(cleanupReport.affectedFieldCount) 个不适用字段值。")
        scan()
    }

    private func report(_ text: String) {
        message = text
        showingMessage = true
    }

    private func remainingSeconds(until date: Date, at now: Date) -> Int {
        max(0, Int(ceil(date.timeIntervalSince(now))))
    }
}

private struct ModuleLocalDataDeletionConfirmationView: View {
    private enum Stage {
        case first
        case second
    }

    @Environment(\.dismiss) private var dismiss
    let module: ToolModule
    let cloudSyncEnabled: Bool
    let delete: () -> Void
    @State private var stage: Stage = .first
    @State private var unlockAt = Date().addingTimeInterval(10)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: stage == .first ? "exclamationmark.triangle.fill" : "trash.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stage == .first ? "确认数据范围" : "最后确认")
                            .font(.title3.weight(.semibold))
                        Text("第 \(stage == .first ? 1 : 2) 层，共 2 层")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(message)
                    .fixedSize(horizontal: false, vertical: true)

                if stage == .second {
                    Label(
                        cloudSyncEnabled
                            ? "删除完成后会同步到 iCloud 和其他设备。"
                            : "已经导出的备份不会被修改。",
                        systemImage: cloudSyncEnabled ? "icloud" : "externaldrive"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let seconds = remainingSeconds(at: context.date)
                    Button(role: stage == .second ? .destructive : nil) {
                        guard context.date >= unlockAt else { return }
                        if stage == .first {
                            stage = .second
                            unlockAt = Date().addingTimeInterval(10)
                        } else {
                            delete()
                            dismiss()
                        }
                    } label: {
                        Text(buttonTitle(seconds: seconds))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(stage == .second ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(seconds > 0)
                }
            }
            .padding(24)
            .navigationTitle("删除\(module.title)数据")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 390)
#if os(iOS)
        .presentationDetents([.medium])
#endif
    }

    private var message: String {
        switch stage {
        case .first:
            return "将删除“\(module.title)”的\(module.localDataDeletionDescription)。首页显示开关和排序不会改变。"
        case .second:
            return "这会清空“\(module.title)”的所有本地数据。按钮解锁后执行删除，随后只有 10 秒可以撤回。"
        }
    }

    private func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(unlockAt.timeIntervalSince(date))))
    }

    private func buttonTitle(seconds: Int) -> String {
        if seconds > 0 {
            return stage == .first ? "继续（\(seconds)）" : "删除本地数据（\(seconds)）"
        }
        return stage == .first ? "继续" : "删除本地数据"
    }
}

private extension ToolModule {
    var localDataDeletionDescription: String {
        switch self {
        case .personalFinance: return "银行账户、银行卡和账单附件"
        case .myStocks: return "持仓、交易、提醒、刷新状态和图表缓存"
        case .currencyExchange: return "换汇记录和汇率提醒"
        case .healthRecords: return "健康档案、医疗机构资料和附件"
        case .foodMap: return "美食记录和照片"
        case .secrets: return "保密条目、字段模板和附件"
        case .documents: return "证照、到期提醒和附件"
        case .bills: return "全部收支账单记录"
        case .sportsLottery: return "赛事选择和本机赛果缓存"
        }
    }
}
