import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @State private var eventOverview: DiagnosticLogOverview?
    @State private var systemOverview: SystemLogOverview?
    @State private var reportFileCount = 0
    @State private var exportDocument: DiagnosticBundleDocument?
    @State private var isLoading = false
    @State private var isExporting = false
    @State private var showingExporter = false
    @State private var showingClearConfirmation = false
    @State private var message = ""
    @State private var showingMessage = false
    @State private var loadGeneration = 0

    var body: some View {
        List {
            // MARK: 事件日志
            Section {
                if let overview = eventOverview {
                    DetailValueRow(
                        title: "大小",
                        value: ByteCountFormatter.string(
                            fromByteCount: overview.byteCount,
                            countStyle: .file
                        )
                    )
                    if let createdAt = overview.createdAt {
                        DetailValueRow(title: "开始记录", value: AppDateFormatter.string(from: createdAt))
                    }
                    if let modifiedAt = overview.modifiedAt {
                        DetailValueRow(title: "最近写入", value: AppDateFormatter.string(from: modifiedAt))
                    }
                }
            } header: {
                Text("事件日志")
            } footer: {
                Text("App 主动埋的关键路径时间线，包含卡顿探测与内存采样。")
            }

            // MARK: 系统日志
            Section {
                if let overview = systemOverview {
                    DetailValueRow(
                        title: "大小",
                        value: ByteCountFormatter.string(
                            fromByteCount: overview.byteCount,
                            countStyle: .file
                        )
                    )
                    if let drained = overview.lastDrainedAt {
                        DetailValueRow(title: "上次采集", value: AppDateFormatter.string(from: drained))
                    }
                    DetailValueRow(title: "本次会话采集条数", value: "\(overview.sessionEntryCount)")
                }
            } header: {
                Text("系统日志抄本")
            } footer: {
                Text("本进程统一日志的磁盘抄本，包含系统框架（CloudKit、URLSession 等）在本进程中打出的记录，每 30 秒采集一次。")
            }

            // MARK: MetricKit 报告
            Section {
                DetailValueRow(title: "已保存报告", value: "\(reportFileCount) 份")
            } header: {
                Text("MetricKit 调用栈报告")
            } footer: {
                Text("系统在下次启动时投递，包含卡顿、崩溃、CPU 异常的完整调用栈 JSON，与 .ips 崩溃报告同源。")
            }

            // MARK: 操作
            Section {
                Button(action: reload) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || isExporting)

                Button(action: prepareExport) {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("正在打包")
                        }
                    } else {
                        Label("导出诊断包（zip）", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isLoading || isExporting)

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("清空全部诊断数据", systemImage: "trash")
                }
                .tint(.red)
                .disabled(isLoading || isExporting)
            }

            // MARK: 最近事件日志
            Section("最近事件日志") {
                if isLoading, eventOverview == nil {
                    HStack {
                        ProgressView()
                        Text("正在读取")
                    }
                    .foregroundStyle(.secondary)
                } else if let text = eventOverview?.recentText, !text.isEmpty {
                    logRows(text)
                } else {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass")
                }
            }

            // MARK: 最近系统日志
            if let text = systemOverview?.recentText, !text.isEmpty {
                Section("最近系统日志") {
                    logRows(text)
                }
            }
        }
        .appNavigationTitle("调试信息")
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .task { reload() }
        .alert("清空全部诊断数据", isPresented: $showingClearConfirmation) {
            Button("清空", role: .destructive, action: clearAll)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除事件日志、系统日志抄本和所有 MetricKit 报告。")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .myToolsDiagnosticBundle,
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
        loadGeneration &+= 1
        let generation = loadGeneration
        Task { @MainActor in
            defer { isLoading = false }
            let event = Task { @MainActor in
                let result = await Task.detached(priority: .utility) {
                    Result { try DiagnosticLogger.shared.overview() }
                }.value
                guard generation == loadGeneration else { return }
                switch result {
                case .success(let overview): eventOverview = overview
                case .failure(let error): report(error.localizedDescription)
                }
            }
            let system = Task { @MainActor in
                let value = await Task.detached(priority: .utility) {
                    SystemLogCollector.shared.overview()
                }.value
                guard generation == loadGeneration else { return }
                systemOverview = value
            }
            let reports = Task { @MainActor in
                let count = await Task.detached(priority: .utility) {
                    AppDiagnosticPayloadCollector.shared.reportFileURLs().count
                }.value
                guard generation == loadGeneration else { return }
                reportFileCount = count
            }
            await event.value
            await system.value
            await reports.value
        }
    }

    private func logRows(_ text: String) -> some View {
        let lines = text.split(separator: "\n").suffix(100).reversed().map(String.init)
        return Group {
            Text("最近 100 条以内，最新在前；完整内容请导出诊断包。")
                .appFont(.caption).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .appFont(.caption2.monospaced())
                    .lineLimit(6)
                    .copyableText(line)
            }
        }
    }

    private func prepareExport() {
        guard !isExporting else { return }
        isExporting = true
        DiagnosticLogger.shared.log(.lifecycle, "用户请求导出诊断包")
        Task { @MainActor in
            defer { isExporting = false }
            do {
                // buildBundle 调用 Process（macOS）或写临时文件，不依赖主线程状态，
                // 放 detached 任务里跑，但函数本身不是 Sendable 闭包——拍成 nonisolated
                // 静态方法作为替代。
                let bundle = try await Task.detached(priority: .userInitiated) {
                    try Self.buildBundleOffMainActor()
                }.value
                exportDocument = DiagnosticBundleDocument(data: bundle)
                showingExporter = true
            } catch {
                report(error.localizedDescription)
            }
        }
    }

    nonisolated private static func buildBundleOffMainActor() throws -> Data {
        let eventData = try DiagnosticLogger.shared.exportData()
        let systemData = SystemLogCollector.shared.exportData()
        let reportURLs = AppDiagnosticPayloadCollector.shared.reportFileURLs()

        // 把所有内容拼成一份 tar 格式的字节流写进临时文件，再用系统的 `/usr/bin/ditto`
        // 打成 zip。不引入第三方依赖，直接拿 zip 命令行工具，都是系统自带的。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyToolsDiagBundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        try eventData.write(to: tmp.appendingPathComponent("event.log"), options: .atomic)
        if !systemData.isEmpty {
            try systemData.write(
                to: tmp.appendingPathComponent("system.log"),
                options: .atomic
            )
        }
        if !reportURLs.isEmpty {
            let reportsDir = tmp.appendingPathComponent("CallStacks", isDirectory: true)
            try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
            for url in reportURLs {
                try FileManager.default.copyItem(
                    at: url,
                    to: reportsDir.appendingPathComponent(url.lastPathComponent)
                )
            }
        }

        // 打包：macOS 用系统的 `ditto` 命令行；iOS 上没有 Process，改用手写 zip。
#if os(macOS)
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyToolsDiag-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        // ditto -c -k --sequesterRsrc <srcdir> <destzip>
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", tmp.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try Data(contentsOf: zipURL)
#else
        return try Self.makeZip(from: tmp)
#endif
    }

    /// 把目录打成 zip（stored，不压缩）。
    ///
    /// 系统 Foundation 在 iOS 上没有 `zipItem`，第三方库在这个项目里也没有，
    /// 所以手写最小 zip。Stored 格式：每个条目写 Local File Header + 原始字节，
    /// 结尾写 Central Directory + End-of-Central-Directory Record。
    /// 解压端（Files.app、macOS Finder、Windows 资源管理器）全部支持。
    nonisolated private static func makeZip(from directoryURL: URL) throws -> Data {
        let fm = FileManager.default
        var localHeaders = Data()
        var centralHeaders = Data()
        var entryCount: UInt16 = 0

        // 深度优先枚举目录内全部文件（不包含子目录本身）。
        let enumerator = fm.enumerator(at: directoryURL, includingPropertiesForKeys: nil)!
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            let fileData = try Data(contentsOf: fileURL)
            // zip 内路径：相对于临时目录根，用 "/" 分隔。
            let relativePath = String(fileURL.path.dropFirst(directoryURL.path.count + 1))
            guard let nameData = relativePath.data(using: .utf8) else { continue }

            let crc = crc32(fileData)
            let localOffset = UInt32(localHeaders.count)

            // Local File Header（4 字节魔数 + 26 字节固定 + 变长文件名）
            var local = Data()
            local += zipUInt32(0x04034B50)        // 签名
            local += zipUInt16(20)                // 最低兼容版本
            local += zipUInt16(0x0800)            // UTF-8 文件名
            local += zipUInt16(0)                 // 压缩方法：stored
            local += zipUInt16(0)                 // 最近修改时间
            local += zipUInt16(0)                 // 最近修改日期
            local += zipUInt32(crc)               // CRC-32
            local += zipUInt32(UInt32(fileData.count))  // 压缩大小
            local += zipUInt32(UInt32(fileData.count))  // 原始大小
            local += zipUInt16(UInt16(nameData.count))  // 文件名长度
            local += zipUInt16(0)                 // 扩展字段长度
            local += nameData
            local += fileData
            localHeaders += local

            // Central Directory 条目
            var central = Data()
            central += zipUInt32(0x02014B50)      // 签名
            central += zipUInt16(20)              // 创建版本
            central += zipUInt16(20)              // 最低兼容版本
            central += zipUInt16(0x0800)          // UTF-8 文件名
            central += zipUInt16(0)               // 压缩方法
            central += zipUInt16(0)               // 修改时间
            central += zipUInt16(0)               // 修改日期
            central += zipUInt32(crc)             // CRC-32
            central += zipUInt32(UInt32(fileData.count))
            central += zipUInt32(UInt32(fileData.count))
            central += zipUInt16(UInt16(nameData.count))
            central += zipUInt16(0)               // 扩展字段长度
            central += zipUInt16(0)               // 注释长度
            central += zipUInt16(0)               // 起始磁盘
            central += zipUInt16(0)               // 内部属性
            central += zipUInt32(0)               // 外部属性
            central += zipUInt32(localOffset)     // Local Header 相对偏移
            central += nameData
            centralHeaders += central
            entryCount += 1
        }

        // End-of-Central-Directory Record
        var eocd = Data()
        eocd += zipUInt32(0x06054B50)             // 签名
        eocd += zipUInt16(0)                      // 磁盘编号
        eocd += zipUInt16(0)                      // Central Directory 起始磁盘
        eocd += zipUInt16(entryCount)             // 本磁盘条目数
        eocd += zipUInt16(entryCount)             // 总条目数
        eocd += zipUInt32(UInt32(centralHeaders.count))   // Central Directory 大小
        eocd += zipUInt32(UInt32(localHeaders.count))     // Central Directory 偏移
        eocd += zipUInt16(0)                      // 注释长度

        return localHeaders + centralHeaders + eocd
    }

    nonisolated private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            var b = UInt32(byte) ^ (crc & 0xFF)
            for _ in 0..<8 { b = (b & 1) != 0 ? (b >> 1) ^ 0xEDB88320 : b >> 1 }
            crc = b ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    nonisolated private static func zipUInt16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    nonisolated private static func zipUInt32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private func clearAll() {
        guard !isLoading, !isExporting else { return }
        isLoading = true
        eventOverview = nil
        systemOverview = nil
        reportFileCount = 0
        Task { @MainActor in
            let started = Date()
            let errors = await DiagnosticMaintenance.clear([
                { try DiagnosticLogger.shared.clear() },
                { try SystemLogCollector.shared.clear() },
                { try AppDiagnosticPayloadCollector.shared.clearReports() }
            ])
            DiagnosticLogger.shared.log(.lifecycle, "诊断清理结束 errors=\(errors.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            isLoading = false
            reload()
            if !errors.isEmpty { report(errors.joined(separator: "\n")) }
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
        return "\(AppMetadata.appName)-诊断包-\(formatter.string(from: Date())).zip"
    }
}

struct DiagnosticBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.myToolsDiagnosticBundle] }
    static var writableContentTypes: [UTType] { [.myToolsDiagnosticBundle] }

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
    static var myToolsDiagnosticBundle: UTType {
        UTType(filenameExtension: "zip", conformingTo: .zip) ?? .zip
    }
}
