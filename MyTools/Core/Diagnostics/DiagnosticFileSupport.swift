import Foundation

enum DiagnosticMaintenance {
    /// File work is never inherited onto MainActor. All collectors are tried,
    /// so one unavailable artifact cannot prevent the others being cleared.
    static func clear(_ actions: [@Sendable () throws -> Void]) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for action in actions {
                group.addTask {
                    do { try action(); return nil }
                    catch { return error.localizedDescription }
                }
            }
            var errors: [String] = []
            for await error in group { if let error { errors.append(error) } }
            return errors
        }
    }

    static func trimLog(at url: URL, maximumBytes: Int, retainedBytes: Int) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue > maximumBytes else { return }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let count = max(1, min(retainedBytes, maximumBytes))
        try reader.seek(toOffset: UInt64(size.intValue - count))
        let tail = try reader.read(upToCount: count) ?? Data()
        let aligned = tail.drop(while: { $0 != 0x0A }).dropFirst()
        try Data(aligned).write(to: url, options: .atomic)
        DiagnosticPaths.applyProtection(to: url)
        DiagnosticPaths.excludeFromBackup(url)
    }
}

/// 诊断产物的统一落盘位置。
///
/// 现在有三份产物：自建事件日志（`DiagnosticLogger`，只记我们主动埋的点）、系统统一
/// 日志抄本（`SystemLogCollector`，把本进程 unified logging 抄到磁盘）、MetricKit 调用栈
/// （`AppDiagnosticPayloadCollector`）。三份都放同一个目录，导出时整目录打包即可；路径、
/// 文件保护和备份排除只在这里写一次，避免三个采集器各拼一遍、各漏一处。
enum DiagnosticPaths {
    static let directoryURL: URL = {
        let fileManager = FileManager.default
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    /// 自建事件日志。文件名沿用旧版本，升级安装后历史日志继续可读。
    static var eventLogURL: URL {
        directoryURL.appendingPathComponent("MyTools-Diagnostics.log", isDirectory: false)
    }

    /// 系统统一日志抄本。与事件日志分开存：事件日志是精挑的时间线，先看它；
    /// 这份是海量原料，定位到可疑时段再翻，混在一起会把那几十条埋点淹掉。
    static var systemLogURL: URL {
        directoryURL.appendingPathComponent("MyTools-SystemLog.log", isDirectory: false)
    }

    static var callStackDirectoryURL: URL {
        directoryURL.appendingPathComponent("CallStacks", isDirectory: true)
    }

    /// 诊断产物一律排除备份：它们是可重建的排查材料，不该占用 iCloud 备份空间。
    /// 注意只排除 `Diagnostics` 子目录——`Application Support/MyTools` 根目录装着业务档案，
    /// 排除它会让用户的数据进不了备份。
    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    /// 首次解锁后可读。诊断写入要覆盖「App 在后台被唤醒、屏幕还锁着」这段时间，
    /// 默认的 `completeUnlessOpen` 会在那时写失败。
    static func applyProtection(to url: URL) {
#if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    static func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        excludeFromBackup(directoryURL)
    }
}

/// 两份日志文件共用的行首时间戳。格式必须一致，否则交错阅读时对不上时间，
/// 裁剪逻辑也无法复用同一个解析器。
enum DiagnosticTimestamp {
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        formatter.date(from: text)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()
}

/// 按行裁剪日志文件，只保留 `cutoff` 之后的条目。
///
/// 解析不出时间戳的行一律保留：多行消息的续行、以及写入被截断的那一行都属于这种，
/// 宁可留着也不要把上下文删掉。
enum DiagnosticLogPruner {
    static func retainEntries(in url: URL, since cutoff: Date) throws {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let retained = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard let separator = line.firstIndex(of: "|") else { return true }
                let timestampText = line[..<separator]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timestamp = DiagnosticTimestamp.date(from: timestampText) else {
                    return true
                }
                return timestamp >= cutoff
            }
        try Data(retained.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        DiagnosticPaths.applyProtection(to: url)
    }

    /// 每天最多裁剪一次。判定用的「今天」以 `key` 区分存放，两份日志各自记账。
    /// 返回 true 表示这次需要执行裁剪。
    static func shouldPrune(now: Date, key: String) -> Bool {
        let defaults = UserDefaults.standard
        let components = Calendar.autoupdatingCurrent
            .dateComponents([.year, .month, .day], from: now)
        let token = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        guard defaults.string(forKey: key) != token else { return false }
        defaults.set(token, forKey: key)
        return true
    }

    /// 保留最近 7 天（含今天）。
    static func cutoff(for now: Date) -> Date? {
        let calendar = Calendar.autoupdatingCurrent
        return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
    }
}
