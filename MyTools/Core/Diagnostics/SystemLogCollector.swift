import Foundation
import OSLog

/// 把本进程的统一日志（unified logging）增量抄到磁盘。
///
/// 自建的 `DiagnosticLogger` 只记我们主动埋的点——没写 `log(...)` 的地方永远不会留痕，
/// 而问题恰恰常出在没想到要埋点的位置。`OSLogStore` 能读到本进程的全部统一日志条目：
/// 不只我们自己那几个 `Logger`（CloudSync / Persistence / Notifications / Startup），
/// 还包括 CloudKit、URLSession、SwiftUI、LocalAuthentication 这些系统框架在我们进程里
/// 打的日志——那些一行代码都没写，但系统一直在记，只是从来没人去取。
///
/// 为什么还要抄到文件：`OSLogStore(scope: .currentProcessIdentifier)` 只能读**当前进程**。
/// 进程被看门狗杀掉后，下次启动再也读不到上一轮的任何条目，而要查的恰恰是上一轮。
/// 所以这个类的唯一职责，就是给系统日志补一个跨进程的持久层。
final class SystemLogCollector: @unchecked Sendable {
    static let shared = SystemLogCollector()

    /// 采集间隔。`getEntries` 是同步查询，几百条就要几十毫秒，所以放后台队列低频跑，
    /// 不跟卡顿探测抢 CPU。
    private static let interval: TimeInterval = 30
    /// 单次抄写条数上限。CloudKit 同步一轮能刷几百条，设上限免得一次把整段历史读进内存。
    private static let maxEntriesPerDrain = 4_000
    private static let maxFileBytes = 4 * 1024 * 1024
    /// 单条消息长度上限。统一日志里偶尔有几十 KB 的巨型消息，留个头部足够定位。
    private static let maxMessageLength = 600
    /// 首次采集回溯多久。冷启动那几秒最容易卡，必须把启动期的条目一起抄进来；
    /// scope 限定在本进程，所以回溯再多也不会抄到上一轮运行的内容。
    private static let initialLookback: TimeInterval = 300
    private static let lastCleanupDayKey = "system-log-last-cleanup-day-v1"

    private let queue = DispatchQueue(
        label: "\(AppMetadata.bundleIdentifier).system-log-collector",
        qos: .utility
    )
    private let fileManager = FileManager.default
    private let fileURL = DiagnosticPaths.systemLogURL
    private let appSubsystem = AppMetadata.bundleIdentifier

    private var timer: DispatchSourceTimer?
    private var store: OSLogStore?
    private var didReportStoreFailure = false
    /// 游标：上一次抄到的最后一条的时间。下次从这个时间之后接着抄。
    private var lastEntryDate: Date?
    private var totalEntryCount = 0
    private var lastDrainedAt: Date?

    private init() {}

    /// 只在前台采集。后台被挂起时定时器不会被调度，回前台补抄即可——统一日志在系统
    /// 缓冲里还留着，不会因为我们没及时读而丢失。
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            trimFileIfNeeded()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + 1,
                repeating: Self.interval,
                leeway: .seconds(5)
            )
            source.setEventHandler { [weak self] in
                self?.drain()
            }
            timer = source
            source.activate()
            DiagnosticLogger.shared.log(
                .systemLog,
                "系统日志抄写已启动 间隔=\(Int(Self.interval))s"
            )
        }
    }

    /// 停止前先抄一次：进后台是最常见的「最后一次机会」，挂起后再想抄就没有调度了。
    func stop() {
        queue.async { [self] in
            guard timer != nil else { return }
            drain()
            timer?.cancel()
            timer = nil
            DiagnosticLogger.shared.log(
                .systemLog,
                "系统日志抄写已停止 本会话累计=\(totalEntryCount)条"
            )
        }
    }

    /// 供进后台路径 `await`，确保挂起前这一段确实落到了磁盘。
    func drainNow() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain()
                continuation.resume()
            }
        }
    }

    // MARK: - 抄写

    private func drain() {
        guard let store = ensureStore() else { return }
        pruneIfNeeded(now: Date())

        let since = lastEntryDate ?? Date(timeIntervalSinceNow: -Self.initialLookback)
        var lines: [String] = []
        var newestDate = lastEntryDate
        var isTruncated = false

        do {
            let entries = try store.getEntries(at: store.position(date: since))
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                // 严格大于：`position(date:)` 会把游标那一刻的条目再给一遍。同一纳秒
                // 撞上多条的概率极低，换来的是绝不重复抄写。
                if let lastEntryDate, log.date <= lastEntryDate { continue }
                guard shouldInclude(log) else { continue }
                if lines.count >= Self.maxEntriesPerDrain {
                    isTruncated = true
                    break
                }
                lines.append(line(for: log))
                if newestDate == nil || log.date > newestDate! { newestDate = log.date }
            }
        } catch {
            reportStoreFailure(error)
            return
        }

        lastEntryDate = newestDate
        lastDrainedAt = Date()
        guard !lines.isEmpty else { return }
        totalEntryCount += lines.count
        append(lines)

        if isTruncated {
            DiagnosticLogger.shared.log(
                .systemLog,
                "单次抄写达到上限 \(Self.maxEntriesPerDrain) 条，本轮其余条目已跳过",
                level: .warning
            )
        }
    }

    /// 过滤规则只有两条，刻意保持可解释：
    ///
    /// - 我们自己的 subsystem 全收，包括 `debug`／`info`——那是我们主动打的，一条不漏；
    /// - 其他 subsystem 只收 `notice` 及以上。系统框架的 `debug`／`info` 量极大且多为
    ///   内部细节，收进来只会把文件撑爆、把有用的行淹掉。
    private func shouldInclude(_ entry: OSLogEntryLog) -> Bool {
        if entry.subsystem == appSubsystem { return true }
        return entry.level.rawValue >= OSLogEntryLog.Level.notice.rawValue
    }

    private func line(for entry: OSLogEntryLog) -> String {
        var message = entry.composedMessage
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if message.count > Self.maxMessageLength {
            message = String(message.prefix(Self.maxMessageLength)) + "…（已截断）"
        }
        let source = [entry.subsystem, entry.category]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return [
            DiagnosticTimestamp.string(from: entry.date),
            Self.levelToken(entry.level),
            source.isEmpty ? "未标注来源" : source,
            message
        ].joined(separator: " | ")
    }

    private static func levelToken(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "UNDEF"
        @unknown default: return "UNDEF"
        }
    }

    // MARK: - 文件

    /// 低频写入，所以每次开关一次文件句柄而不常驻：省掉「裁剪后句柄失效」这类状态，
    /// 30 秒一次的开销可以忽略。
    private func append(_ lines: [String]) {
        do {
            try ensureFile()
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.synchronize()
            trimFileIfNeeded()
        } catch {
            DiagnosticLogger.logError(.systemLog, operation: "写入系统日志抄本", error: error)
        }
    }

    private func trimFileIfNeeded() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try DiagnosticMaintenance.trimLog(at: fileURL, maximumBytes: Self.maxFileBytes,
                                              retainedBytes: 3 * 1024 * 1024)
        } catch {
            DiagnosticLogger.logError(.systemLog, operation: "限制系统日志大小", error: error)
        }
    }

    private func ensureFile() throws {
        try DiagnosticPaths.createDirectoryIfNeeded()
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            DiagnosticPaths.applyProtection(to: fileURL)
        }
        DiagnosticPaths.excludeFromBackup(fileURL)
    }

    private func ensureStore() -> OSLogStore? {
        if let store { return store }
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            self.store = store
            return store
        } catch {
            reportStoreFailure(error)
            return nil
        }
    }

    /// 只报一次。取不到 `OSLogStore` 时每 30 秒刷一条错误，反而会把事件日志淹掉。
    private func reportStoreFailure(_ error: Error) {
        guard !didReportStoreFailure else { return }
        didReportStoreFailure = true
        DiagnosticLogger.logError(.systemLog, operation: "读取统一日志", error: error)
    }

    private func pruneIfNeeded(now: Date) {
        guard DiagnosticLogPruner.shouldPrune(now: now, key: Self.lastCleanupDayKey),
              let cutoff = DiagnosticLogPruner.cutoff(for: now),
              fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try DiagnosticLogPruner.retainEntries(in: fileURL, since: cutoff)
        } catch {
            DiagnosticLogger.logError(.systemLog, operation: "裁剪系统日志抄本", error: error)
        }
    }

    // MARK: - 查看与导出

    func overview(recentByteLimit: Int = 16 * 1_024) -> SystemLogOverview {
        queue.sync {
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
            return SystemLogOverview(
                byteCount: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: attributes?[.modificationDate] as? Date,
                lastDrainedAt: lastDrainedAt,
                sessionEntryCount: totalEntryCount,
                recentText: (try? readTail(maximumByteCount: recentByteLimit)) ?? ""
            )
        }
    }

    func exportData() -> Data {
        queue.sync {
            (try? Data(contentsOf: fileURL)) ?? Data()
        }
    }

    func clear() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            totalEntryCount = 0
            lastDrainedAt = nil
            // 游标留着：清空的是历史抄本，不该把已经抄过的条目再抄一遍。
        }
    }

    private func readTail(maximumByteCount: Int) throws -> String {
        guard fileManager.fileExists(atPath: fileURL.path) else { return "" }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maximumByteCount) ? size - UInt64(maximumByteCount) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newlineIndex = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newlineIndex)...]
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct SystemLogOverview: Sendable {
    let byteCount: Int64
    let modifiedAt: Date?
    let lastDrainedAt: Date?
    let sessionEntryCount: Int
    let recentText: String
}
