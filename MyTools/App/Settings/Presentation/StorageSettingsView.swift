import SwiftUI
#if os(macOS)
import AppKit
#endif

struct StorageDataView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var moduleSettings: ToolModuleSettings
    @State private var scanResult: StorageScanResult?
    /// Filtered once per scan; reading it from `body` must not rebuild the
    /// whole attachment reference index every time (AUDIT-084).
    @State private var unreferencedOrphans: [OrphanAttachmentInfo] = []
    @State private var redundantDataReport: RedundantDataCleanupReport?
    @State private var legacyDataReport: LegacyDataReport?
    @State private var showingLegacyCleanupConfirmation = false
    @State private var previewOrphan: OrphanAttachmentInfo?
    @State private var isScanning = false
    @State private var showingCleanupConfirmation = false
    @State private var showingRedundantCleanupConfirmation = false
    @State private var deletionConfirmationModule: ToolModule?
    @State private var cacheCleanupModule: ToolModule?
    @State private var isClearingCache = false
    @State private var showingMessage = false
    @State private var message = ""

    var body: some View {
        List {
            if let scanResult {
                Section {
                    LabeledContent {
                        Text(formattedSize(scanResult.usage.managedBytes))
                    } label: {
                        Text("应用可管理数据")
                    }
                        .appFont(.headline)
                    storageRow("本地档案", bytes: scanResult.usage.localVaultBytes)
                    storageRow(
                        "附件",
                        bytes: scanResult.usage.attachmentsBytes,
                        detail: "\(scanResult.usage.attachmentCount) 个文件"
                    )
                    if scanResult.usage.cloudSyncStateBytes > 0 {
                        storageRow("同步状态", bytes: scanResult.usage.cloudSyncStateBytes)
                    }
                    if scanResult.usage.localCacheBytes > 0 {
                        storageRow("本地缓存", bytes: scanResult.usage.localCacheBytes)
                    }
                    if scanResult.usage.systemCloudKitCacheBytes > 0 {
                        storageRow(
                            "系统 CloudKit 缓存",
                            bytes: scanResult.usage.systemCloudKitCacheBytes
                        )
                    }
                    storageRow("诊断日志", bytes: scanResult.usage.diagnosticsBytes)
                    if scanResult.usage.otherBytes > 0 {
                        storageRow("其他应用数据", bytes: scanResult.usage.otherBytes)
                    }
                } header: {
                    Text("占用空间")
                } footer: {
                    Text("同步状态、行情/赛果缓存和诊断日志均只留在本机，已排除出系统 iCloud 设备备份，也不会写入 CloudKit。系统 CloudKit 缓存由系统管理，另计为系统占用，用于已同步记录和附件的本机访问，不能由 App 直接删除；它也不代表额外上传的业务数据。iCloud 云端用量是独立口径，可能暂时保留记录或附件版本。")
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
                        DisclosureGroup("查看缺失的文件") {
                            ForEach(scanResult.missingAttachments) { attachment in
                                Text(attachment.storedFileName)
                                    .appFont(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
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
                        DisclosureGroup("查看文件") {
                            ForEach(unreferencedOrphans) { orphan in
                                orphanRow(orphan)
                            }
                        }
                        Button(role: .destructive) {
                            showingCleanupConfirmation = true
                        } label: {
                            Label("清理无效附件", systemImage: "trash")
                        }
                        .tint(.red)
                        .disabled(isScanning)
                    }
                } header: {
                    Text("无效附件")
                } footer: {
                    Text("只会删除未被业务记录引用的附件，不会删除有效记录中的附件。这些文件已没有对应记录，只能显示存储名、大小和修改时间，点按可预览。")
                }

                Section {
                    if let redundantDataReport, redundantDataReport.isEmpty {
                        Label("没有发现不适用的字段值", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if let redundantDataReport {
                        AppLabeledContentRow("可清理字段") {
                            Text("\(redundantDataReport.affectedFieldCount) 个")
                        }
                        ForEach(redundantDataReport.findings) { finding in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(finding.title, systemImage: finding.module.systemImage)
                                    .foregroundStyle(finding.module.tint)
                                Text(finding.detail)
                                    .appFont(.footnote)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Spacer()
                                    Text("\(finding.affectedRecordCount) 条 · \(finding.affectedFieldCount) 个字段")
                                        .appFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !finding.items.isEmpty {
                                    DisclosureGroup("查看记录") {
                                        ForEach(finding.items) { item in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.recordTitle)
                                                    .appFont(.subheadline)
                                                Text(item.fieldNames.joined(separator: "、"))
                                                    .appFont(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .appFont(.footnote)
                                }
                            }
                        }
                        Button(role: .destructive) {
                            showingRedundantCleanupConfirmation = true
                        } label: {
                            Label("清理不适用字段", systemImage: "eraser")
                        }
                        .tint(.red)
                        .disabled(isScanning)
                    }
                } header: {
                    Text("冗余字段")
                } footer: {
                    Text("只检查当前已编译且已开启的功能。关闭功能的数据和未编译功能的不透明数据不会被读取或修改。")
                }

                Section {
                    if let legacyDataReport, legacyDataReport.isEmpty {
                        Label("没有发现已移除功能的遗留数据", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if let legacyDataReport {
                        AppLabeledContentRow("可清理数据") {
                            Text("\(legacyDataReport.itemCount) 项 · \(legacyDataReport.attachmentStoredFileNames.count) 个附件")
                        }
                        ForEach(legacyDataReport.findings) { finding in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(finding.title)
                                Text(finding.detail)
                                    .appFont(.footnote)
                                    .foregroundStyle(.secondary)
                                DisclosureGroup("查看 \(finding.items.count) 项") {
                                    ForEach(finding.items) { item in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .appFont(.subheadline)
                                            if !item.attachmentStoredFileNames.isEmpty {
                                                Text("附件：\(item.attachmentStoredFileNames.joined(separator: "、"))")
                                                    .appFont(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                                .appFont(.footnote)
                            }
                        }
                        Button(role: .destructive) {
                            showingLegacyCleanupConfirmation = true
                        } label: {
                            Label("清理遗留数据", systemImage: "trash")
                        }
                        .tint(.red)
                        .disabled(isScanning)
                    }
                } header: {
                    Text("遗留数据")
                } footer: {
                    Text("美食地图和合伙记账已从 App 中删除，它们留在本地档案里的记录、标签和附件不会再显示。清理只影响本机档案；iCloud 中这两类旧记录不会被修改。收支账单、体彩开奖只是暂时关闭，数据不在此处清理。")
                }

                if !localCacheModules.isEmpty {
                    Section {
                        ForEach(localCacheModules) { module in
                            HStack(spacing: 12) {
                                Label(module.title, systemImage: module.systemImage)
                                    .foregroundStyle(module.tint)
                                Text(module.localCacheDescription)
                                    .appFont(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button(role: .destructive) {
                                    cacheCleanupModule = module
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("清理\(module.title)本地缓存")
                                .disabled(isClearingCache)
                            }
                        }
                    } header: {
                        Text("本地缓存")
                    } footer: {
                        Text("只删除可重新下载的行情、汇率或赛果缓存，不会删除业务记录、附件、提醒或 iCloud 数据。")
                    }
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
                                    .appFont(.caption)
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
                        !store.isInitialDataLoaded
                            || store.pendingModuleLocalDataDeletion != nil
                    )
                    .accessibilityLabel("删除\(module.title)的所有本地数据")
                }
            } header: {
                Text("删除功能数据")
            } footer: {
                Text("每次只能删除一个功能的数据。操作需要经过两次各 10 秒的确认，删除后还有 10 秒可以撤回。")
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
        .appNavigationTitle("存储与数据")
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
        .alert("清理遗留数据", isPresented: $showingLegacyCleanupConfirmation) {
            Button("清理", role: .destructive) {
                cleanupLegacyData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从本机档案中删除 \(legacyDataReport?.itemCount ?? 0) 项遗留数据，并在保存成功后删除其中 \(legacyDataReport?.attachmentStoredFileNames.count ?? 0) 个附件。此操作无法撤销，已经导出的旧备份不会被修改。")
        }
#if os(iOS)
        .sheet(item: $previewOrphan) { orphan in
            AttachmentPreviewSheet(
                attachment: orphanAttachment(orphan),
                url: store.attachmentURL(forStoredFileName: orphan.storedFileName),
                onDismiss: { previewOrphan = nil }
            )
        }
#endif
        .alert(item: $cacheCleanupModule) { module in
            Alert(
                title: Text("清理\(module.title)本地缓存？"),
                message: Text("\(module.localCacheDescription)。清理后下次使用时会重新下载，业务数据和 iCloud 数据不会受到影响。"),
                primaryButton: .destructive(Text("清理")) {
                    clearLocalCache(for: module)
                },
                secondaryButton: .cancel(Text("取消"))
            )
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

    private var orphanBytes: Int64 {
        unreferencedOrphans.reduce(Int64.zero) { $0 + $1.byteCount }
    }

    private var localCacheModules: [ToolModule] {
        CompiledToolModules.ordered.filter(\.hasLocalCache)
    }

    private func storageRow(_ title: String, bytes: Int64, detail: String? = nil) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedSize(bytes))
                if let detail {
                    Text(detail)
                        .appFont(.caption)
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

    private func orphanRow(_ orphan: OrphanAttachmentInfo) -> some View {
        Button {
#if os(iOS)
            previewOrphan = orphan
#elseif os(macOS)
            NSWorkspace.shared.open(store.attachmentURL(forStoredFileName: orphan.storedFileName))
#endif
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(orphan.storedFileName)
                        .appFont(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let modifiedAt = orphan.modifiedAt {
                        Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(formattedSize(orphan.byteCount))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("预览这个附件")
    }

    private func orphanAttachment(_ orphan: OrphanAttachmentInfo) -> FileAttachment {
        var attachment = FileAttachment()
        attachment.fileName = orphan.storedFileName
        attachment.storedFileName = orphan.storedFileName
        attachment.fileSize = orphan.byteCount
        return attachment
    }

    private func scan() {
        guard store.isInitialDataLoaded, !isScanning else { return }
        isScanning = true
        redundantDataReport = store.scanRedundantData()
        legacyDataReport = store.scanLegacyData()
        let referencedNames = store.referencedAttachmentStoredFileNames
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
                unreferencedOrphans = scanResult.orphanAttachments
            case .failure(let error):
                report(error.localizedDescription)
            }
        }
    }

    private func cleanupOrphans() {
        guard scanResult != nil else { return }
        isScanning = true
        // Re-check against the references at deletion time: records may have
        // gained an attachment with the same name since the scan.
        let referencedNames = store.referencedAttachmentStoredFileNames
        let orphans = unreferencedOrphans.filter { !referencedNames.contains($0.storedFileName) }
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
        guard redundantDataReport?.isEmpty == false else { return }
        let cleanupReport = store.cleanupRedundantData()
        guard !cleanupReport.isEmpty else {
            report("没有可清理的不适用字段，或当前档案暂时无法安全写入。")
            scan()
            return
        }
        report("已清理 \(cleanupReport.affectedFieldCount) 个不适用字段值。")
        scan()
    }

    private func cleanupLegacyData() {
        guard legacyDataReport?.isEmpty == false else { return }
        let cleanupReport = store.cleanupLegacyData()
        guard !cleanupReport.isEmpty else {
            report("没有可清理的遗留数据，或当前档案暂时无法安全写入。")
            scan()
            return
        }
        report("已清理 \(cleanupReport.itemCount) 项遗留数据，相关附件会在保存完成后删除。")
        Task { @MainActor in
            // Let the deferred attachment removal finish so the rescan reflects it.
            try? await Task.sleep(for: .milliseconds(500))
            scan()
        }
    }

    private func clearLocalCache(for module: ToolModule) {
        guard !isClearingCache else { return }
        isClearingCache = true
        Task { @MainActor in
            await store.clearLocalCache(for: module)
            isClearingCache = false
            report("已清理\(module.title)的本地缓存。")
            scan()
        }
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
                        .appFont(.system(size: 34))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stage == .first ? "确认数据范围" : "最后确认")
                            .appFont(.title3.weight(.semibold))
                        Text("第 \(stage == .first ? 1 : 2) 层，共 2 层")
                            .appFont(.caption)
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
                    .appFont(.footnote)
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
            .appNavigationTitle("删除\(module.title)数据")
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
    var hasLocalCache: Bool {
        switch self {
        case .myStocks, .currencyExchange, .sportsLottery:
            true
        case .personalFinance, .healthRecords, .foodMap, .secrets, .documents, .bills, .partnership:
            false
        }
    }

    var localCacheDescription: String {
        switch self {
        case .myStocks:
            return "行情图、刷新状态和共享汇率缓存"
        case .currencyExchange:
            return "共享中国银行汇率牌价缓存"
        case .sportsLottery:
            return "体彩赛事赛果缓存"
        case .personalFinance, .healthRecords, .foodMap, .secrets, .documents, .bills, .partnership:
            return "暂无可单独清理的模块缓存"
        }
    }

    var localDataDeletionDescription: String {
        switch self {
        case .personalFinance: return "银行账户、银行卡和账单附件"
        case .myStocks: return "持仓、交易、提醒、刷新状态、图表和共享汇率缓存"
        case .currencyExchange: return "换汇记录、汇率提醒和共享牌价缓存"
        case .healthRecords: return "健康档案、医疗机构资料和附件"
        case .foodMap: return "美食记录和照片"
        case .secrets: return "保密条目、字段模板和附件"
        case .documents: return "证照、到期提醒和附件"
        case .partnership: return "全部合伙账本、成员、注资及股票交易记录"
        case .bills: return "全部收支账单记录"
        case .sportsLottery: return "赛事选择和本机赛果缓存"
        }
    }
}
