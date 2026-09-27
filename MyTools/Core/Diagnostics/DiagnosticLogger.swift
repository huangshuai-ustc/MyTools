import Foundation

enum DiagnosticLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

enum DiagnosticLogCategory: String, Sendable {
    case lifecycle = "生命周期"
    case startup = "启动"
    case persistence = "存储"
    case authentication = "认证"
    case backup = "备份"
    case attachment = "附件"
    case stockQuote = "股票行情"
    case exchangeRate = "外汇牌价"
    case textInput = "文字输入"
    case navigation = "页面"
    case data = "数据"
    case cloudSync = "云同步"
    case notification = "通知"
    /// 主线程停顿。看门狗杀进程前的最后线索基本只会出现在这一类里。
    case hang = "卡顿"
    case memory = "内存"
    /// `SystemLogCollector` 自身的状态（采集了多少条、失败原因）。抄本内容另存一份文件。
    case systemLog = "系统日志"
    /// MetricKit 投递的 hang／崩溃／CPU 异常报告，完整调用栈另存 JSON。
    case diagnosticReport = "诊断报告"
}

struct DiagnosticLogOverview: Sendable {
    let recentText: String
    let byteCount: Int64
    let createdAt: Date?
    let modifiedAt: Date?
}

/// A low-volume event log for diagnosing hangs on physical devices.
/// Callers must only include timings, counts and redacted identifiers.
final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    private let queue = DispatchQueue(
        label: "\(AppMetadata.bundleIdentifier).diagnostics",
        qos: .utility
    )
    private let fileManager = FileManager.default
    private let fileURL: URL
    private let sessionID = String(UUID().uuidString.prefix(8))
    private let sessionStartedAt = ProcessInfo.processInfo.systemUptime
    private var fileHandle: FileHandle?
    private var internalError: String?

    private static let lastCleanupDayKey = "diagnostics-last-cleanup-day-v1"

    /// 当前打开的页面栈。卡顿探测在后台线程读它，所以单独加锁，不走 `queue`
    /// （`queue` 上的任务在写盘，卡顿时也要能马上读到页面名）。
    private let screenLock = NSLock()
    private var screenStack: [String] = []

    /// 形如 `股票详情<-股票`：最近打开的页面在最前。给卡顿与内存日志做定位用。
    var currentScreenDescription: String {
        screenLock.lock()
        defer { screenLock.unlock() }
        guard !screenStack.isEmpty else { return "无" }
        return screenStack.reversed().joined(separator: "<-")
    }

    private init() {
        fileURL = DiagnosticPaths.eventLogURL

        let previousSessionWasActive = UserDefaults.standard.bool(
            forKey: "diagnostics-session-was-active-v1"
        )
        UserDefaults.standard.set(true, forKey: "diagnostics-session-was-active-v1")
        let process = ProcessInfo.processInfo
        log(
            .lifecycle,
            "新会话 session=\(sessionID) version=\(AppMetadata.versionDescription) os=\(process.operatingSystemVersionString) previousForegroundExit=\(previousSessionWasActive)"
        )
        // 机型／核心数／物理内存决定了后面所有耗时和内存数字该怎么读，每次会话记一行。
        log(
            .startup,
            String(
                format: "运行环境 机型=%@ 核心=%d 物理内存=%.1fGB %@ %@",
                Self.hardwareModel(),
                process.processorCount,
                Double(process.physicalMemory) / 1_073_741_824,
                Self.runtimeConditionDescription(),
                Self.memoryDescription()
            )
        )
    }

    func log(
        _ category: DiagnosticLogCategory,
        _ message: String,
        level: DiagnosticLogLevel = .info,
        flushesImmediately: Bool = false
    ) {
        let date = Date()
        let elapsed = ProcessInfo.processInfo.systemUptime - sessionStartedAt
        let thread = Thread.isMainThread ? "main" : "background"
        queue.async { [self] in
            performDailyCleanupIfNeeded(now: date)
            write(
                date: date,
                elapsed: elapsed,
                thread: thread,
                category: category,
                level: level,
                message: message,
                flushesImmediately: flushesImmediately
            )
        }
    }

    // MARK: - 页面栈

    func markScreenAppeared(_ name: String) {
        screenLock.lock()
        screenStack.append(name)
        let depth = screenStack.count
        screenLock.unlock()
        log(.navigation, "页面显示：\(name) 层级=\(depth) \(Self.memoryDescription())")
    }

    func markScreenDisappeared(_ name: String, duration: TimeInterval?) {
        screenLock.lock()
        // 倒着找：同名页面可能同时在栈里（例如从一只股票的详情页跳到另一只）。
        if let index = screenStack.lastIndex(of: name) {
            screenStack.remove(at: index)
        }
        let depth = screenStack.count
        screenLock.unlock()
        let stay = duration.map { String(format: " 停留=%.2fs", $0) } ?? ""
        log(.navigation, "页面离开：\(name) 层级=\(depth)\(stay) \(Self.memoryDescription())")
    }

    // MARK: - 内存

    /// `phys_footprint` 就是 jetsam 判定用的那个值，比 `resident_size` 更贴近系统视角。
    static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// 直接拼进日志消息里的片段，形如 `内存=182.4MB`。取不到就给 `内存=未知`。
    static func memoryDescription() -> String {
        guard let bytes = memoryFootprintBytes() else { return "内存=未知" }
        return String(format: "内存=%.1fMB", Double(bytes) / 1_048_576)
    }

    // MARK: - 运行环境

    /// 机型标识（iOS 上形如 `iPhone18,1`，macOS 上形如 `Mac15,3`）。
    ///
    /// 崩溃报告头部的 `Hardware Model` 就是这个值。对上机型才能判断日志里的内存与耗时
    /// 出自哪一档设备——同样的 10 秒看门狗额度，核心数与主频不同，结论完全不一样。
    static func hardwareModel() -> String {
#if os(macOS)
        sysctlString("hw.model") ?? "未知"
#else
        sysctlString("hw.machine") ?? "未知"
#endif
    }

    /// 会随时间变化的运行环境：热状态与低电量模式。
    ///
    /// 两者都会直接压低主频，「同一段代码平时 2 秒、降频后跑满看门狗额度」是很常见的
    /// 成因，所以卡顿日志必须带上，否则只看耗时会误判成代码回退。
    static func runtimeConditionDescription() -> String {
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "正常"
        case .fair: thermal = "偏高"
        case .serious: thermal = "严重"
        case .critical: thermal = "临界"
        @unknown default: thermal = "未知"
        }
        return "热状态=\(thermal) 低电量=\(process.isLowPowerModeEnabled ? "开" : "关")"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl 返回的是 C 字符串，末尾那个 0 要先切掉再解码。
        if let terminator = buffer.firstIndex(of: 0) {
            buffer.removeSubrange(terminator...)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    func markEnteredBackground() {
        UserDefaults.standard.set(false, forKey: "diagnostics-session-was-active-v1")
        log(.lifecycle, "App 进入后台 页面=\(currentScreenDescription) \(Self.memoryDescription())")
    }

    func markBecameActive() {
        UserDefaults.standard.set(true, forKey: "diagnostics-session-was-active-v1")
        log(.lifecycle, "App 进入前台 页面=\(currentScreenDescription) \(Self.memoryDescription())")
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                try? fileHandle?.synchronize()
                continuation.resume()
            }
        }
    }

    func overview(recentByteLimit: Int = 64 * 1_024) throws -> DiagnosticLogOverview {
        try queue.sync {
            try ensureFile()
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            return DiagnosticLogOverview(
                recentText: try readTail(maximumByteCount: recentByteLimit),
                byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                createdAt: attributes[.creationDate] as? Date,
                modifiedAt: attributes[.modificationDate] as? Date
            )
        }
    }

    func exportData() throws -> Data {
        try queue.sync {
            performDailyCleanupIfNeeded(now: Date())
            try ensureFile()
            try fileHandle?.synchronize()
            return try Data(contentsOf: fileURL)
        }
    }

    func clear() throws {
        try queue.sync {
            try fileHandle?.close()
            fileHandle = nil
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try ensureFile()
            write(
                date: Date(),
                elapsed: ProcessInfo.processInfo.systemUptime - sessionStartedAt,
                thread: Thread.isMainThread ? "main" : "background",
                category: .lifecycle,
                level: .info,
                message: "用户已清空旧诊断日志，当前会话继续记录 session=\(sessionID)"
            )
        }
    }

    static func errorCode(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain)(\(value.code))"
    }

    static func logError(
        _ category: DiagnosticLogCategory,
        operation: String,
        error: Error
    ) {
        let code = errorCode(error)
        shared.log(category, "\(operation) error=\(code)", level: .error)
    }

    private func write(
        date: Date,
        elapsed: TimeInterval,
        thread: String,
        category: DiagnosticLogCategory,
        level: DiagnosticLogLevel,
        message: String,
        flushesImmediately: Bool = false
    ) {
        do {
            try ensureFile()
            let sanitizedMessage = message
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let timestamp = DiagnosticTimestamp.string(from: date)
            let line = String(
                format: "%@ | +%.3fs | %@ | %@ | %@ | %@\n",
                timestamp,
                elapsed,
                level.rawValue,
                thread,
                category.rawValue,
                sanitizedMessage
            )
            try fileHandle?.write(contentsOf: Data(line.utf8))
            if level == .error || flushesImmediately { try fileHandle?.synchronize() }
            internalError = nil
        } catch {
            internalError = Self.errorCode(error)
        }
    }

    /// Keep the rolling diagnostic log to the trailing 7 days. The check is
    /// performed on log access so it also works after iOS suspension.
    private func performDailyCleanupIfNeeded(now: Date) {
        guard DiagnosticLogPruner.shouldPrune(now: now, key: Self.lastCleanupDayKey) else {
            return
        }
        guard let keepFrom = DiagnosticLogPruner.cutoff(for: now) else { return }

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try removeEntries(olderThan: keepFrom)
            }
        } catch {
            internalError = Self.errorCode(error)
        }
    }

    private func removeEntries(olderThan cutoff: Date) throws {
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
        try DiagnosticLogPruner.retainEntries(in: fileURL, since: cutoff)
    }

    private func ensureFile() throws {
        guard fileHandle == nil else { return }
        try DiagnosticPaths.createDirectoryIfNeeded()
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            DiagnosticPaths.applyProtection(to: fileURL)
        }
        DiagnosticPaths.excludeFromBackup(fileURL)
        fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle?.seekToEnd()
    }

    private func readTail(maximumByteCount: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maximumByteCount) ? size - UInt64(maximumByteCount) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newlineIndex = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newlineIndex)...]
        }
        var text = String(decoding: data, as: UTF8.self)
        if let internalError {
            text += "\n诊断日志内部错误：\(internalError)\n"
        }
        return text
    }

}
