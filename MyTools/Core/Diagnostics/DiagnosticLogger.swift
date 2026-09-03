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

    private init() {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        fileURL = baseURL
            .appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("MyTools-Diagnostics.log", isDirectory: false)

        let previousSessionWasActive = UserDefaults.standard.bool(
            forKey: "diagnostics-session-was-active-v1"
        )
        UserDefaults.standard.set(true, forKey: "diagnostics-session-was-active-v1")
        log(
            .lifecycle,
            "新会话 session=\(sessionID) version=\(AppMetadata.versionDescription) os=\(ProcessInfo.processInfo.operatingSystemVersionString) previousForegroundExit=\(previousSessionWasActive)"
        )
    }

    func log(
        _ category: DiagnosticLogCategory,
        _ message: String,
        level: DiagnosticLogLevel = .info
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
                message: message
            )
        }
    }

    func markEnteredBackground() {
        UserDefaults.standard.set(false, forKey: "diagnostics-session-was-active-v1")
        log(.lifecycle, "App 进入后台")
    }

    func markBecameActive() {
        UserDefaults.standard.set(true, forKey: "diagnostics-session-was-active-v1")
        log(.lifecycle, "App 进入前台")
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
            performDailyCleanupIfNeeded(now: Date())
            try ensureFile()
            try fileHandle?.synchronize()
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
        message: String
    ) {
        do {
            try ensureFile()
            let sanitizedMessage = message
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let timestamp = Self.timestampFormatter.string(from: date)
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
            if level == .error { try fileHandle?.synchronize() }
            internalError = nil
        } catch {
            internalError = Self.errorCode(error)
        }
    }

    /// Keep the rolling diagnostic log to the trailing 7 days. The check is
    /// performed on log access so it also works after iOS suspension.
    private func performDailyCleanupIfNeeded(now: Date) {
        let defaults = UserDefaults.standard
        let calendar = Calendar.autoupdatingCurrent
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: now)
        let dayToken = String(
            format: "%04d-%02d-%02d",
            dayComponents.year ?? 0,
            dayComponents.month ?? 0,
            dayComponents.day ?? 0
        )
        guard defaults.string(forKey: Self.lastCleanupDayKey) != dayToken else { return }

        let startOfToday = calendar.startOfDay(for: now)
        guard let keepFrom = calendar.date(byAdding: .day, value: -6, to: startOfToday) else {
            return
        }

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try removeEntries(olderThan: keepFrom)
            }
            defaults.set(dayToken, forKey: Self.lastCleanupDayKey)
        } catch {
            internalError = Self.errorCode(error)
        }
    }

    private func removeEntries(olderThan cutoff: Date) throws {
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil

        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let retainedLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard let separator = line.firstIndex(of: "|") else {
                    return true
                }
                let timestampText = line[..<separator]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timestamp = Self.timestampFormatter.date(from: timestampText) else {
                    return true
                }
                return timestamp >= cutoff
            }
        let retainedText = retainedLines.joined(separator: "\n")
        try Data(retainedText.utf8).write(to: fileURL, options: .atomic)
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#endif
    }

    private func ensureFile() throws {
        guard fileHandle == nil else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
#if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
#endif
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var persistedURL = fileURL
        try? persistedURL.setResourceValues(resourceValues)
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

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()

}
