import Foundation
#if os(iOS)
import MetricKit
#endif

/// 订阅 MetricKit，把系统给出的卡顿／崩溃／CPU 异常报告落到诊断目录。
///
/// 这是官方唯一让 App 自己拿到 **hang 与崩溃调用栈** 的途径。`AppHangMonitor` 能在停顿
/// 当场记下「卡了多久、卡在哪个页面」，但拿不到调用栈——后台线程只能取自己的栈，要展开
/// 主线程的栈得手动走栈帧，不稳定且容易自己引入崩溃。MetricKit 把这件事交给系统做，
/// 给回来的 `callStackTree` 和崩溃报告里的栈是同一个来源。
///
/// 代价是**不实时**：诊断载荷通常在下次启动时、甚至再往后才投递，指标载荷每天一次。
/// 所以它补的是「事后能拿到和 Apple 同级别的调用栈」，实时预警仍然靠 `AppHangMonitor`。
///
/// macOS 上不订阅：MetricKit 在 macOS 的投递依赖 App Store 分发渠道，本地构建拿不到
/// 载荷，注册了只是空跑。卡顿问题的主战场也在 iOS 真机。
final class AppDiagnosticPayloadCollector: NSObject, @unchecked Sendable {
    static let shared = AppDiagnosticPayloadCollector()

    /// 调用栈 JSON 的保留个数。这些文件每个几十到几百 KB，出问题时只看最近几份，
    /// 留太多只会把导出包撑大。
    private static let maxRetainedReports = 20

    private let queue = DispatchQueue(
        label: "\(AppMetadata.bundleIdentifier).diagnostic-payloads",
        qos: .utility
    )
    private var isSubscribed = false

    private override init() {
        super.init()
    }

    /// 启动时注册一次即可，不随前后台启停：载荷可能在任意时刻投递，取消订阅只会漏掉。
    func start() {
#if os(iOS)
        guard !isSubscribed else { return }
        isSubscribed = true
        MXMetricManager.shared.add(self)
        DiagnosticLogger.shared.log(.diagnosticReport, "MetricKit 已订阅")
#endif
    }

    /// 报告文件清单，供调试页展示与导出打包。
    func reportFileURLs() -> [URL] {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: DiagnosticPaths.callStackDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        return (urls ?? []).sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    func clearReports() throws {
        try queue.sync {
            for url in reportFileURLs() {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 落盘

    private func persist(_ data: Data, kind: String, at date: Date) {
        queue.async { [self] in
            do {
                try DiagnosticPaths.createDirectoryIfNeeded()
                let directory = DiagnosticPaths.callStackDirectoryURL
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let url = directory.appendingPathComponent(
                    "\(Self.fileNameFormatter.string(from: date))-\(kind).json",
                    isDirectory: false
                )
                try data.write(to: url, options: .atomic)
                DiagnosticPaths.applyProtection(to: url)
                pruneReports()
            } catch {
                DiagnosticLogger.logError(
                    .diagnosticReport,
                    operation: "保存 \(kind) 报告",
                    error: error
                )
            }
        }
    }

    private func pruneReports() {
        let urls = reportFileURLs()
        guard urls.count > Self.maxRetainedReports else { return }
        for url in urls.dropFirst(Self.maxRetainedReports) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

#if os(iOS)
extension AppDiagnosticPayloadCollector: MXMetricManagerSubscriber {
    /// 诊断载荷：崩溃、卡顿、CPU／磁盘异常、启动过慢。整份 payload 的 JSON 落盘
    /// （里面已经含 `callStackTree`），事件日志里只留一行可读摘要，方便先按时间定位。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            logSummaries(for: payload)
            persist(payload.jsonRepresentation(), kind: "diagnostic", at: payload.timeStampEnd)
        }
    }

    /// 指标载荷：每天一份的聚合数据。量小，同样整份落盘并记一行关键指标。
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            logSummary(for: payload)
            persist(payload.jsonRepresentation(), kind: "metric", at: payload.timeStampEnd)
        }
    }

    private func logSummaries(for payload: MXDiagnosticPayload) {
        for crash in payload.crashDiagnostics ?? [] {
            var parts = ["系统崩溃报告"]
            if let type = crash.exceptionType {
                parts.append("exceptionType=\(type.intValue)")
            }
            if let code = crash.exceptionCode {
                // `0x8BADF00D`（看门狗）这类值按十六进制读才认得出来。
                parts.append(String(format: "exceptionCode=0x%llX", code.uint64Value))
            }
            if let signal = crash.signal {
                parts.append("signal=\(signal.intValue)")
            }
            if let reason = crash.terminationReason {
                parts.append("终止原因=\(reason)")
            }
            parts.append(Self.description(for: crash.metaData))
            DiagnosticLogger.shared.log(
                .diagnosticReport,
                parts.joined(separator: " "),
                level: .error,
                flushesImmediately: true
            )
        }

        for hang in payload.hangDiagnostics ?? [] {
            DiagnosticLogger.shared.log(
                .diagnosticReport,
                String(
                    format: "系统卡顿报告 时长=%.2fs %@",
                    hang.hangDuration.converted(to: .seconds).value,
                    Self.description(for: hang.metaData)
                ),
                level: .error,
                flushesImmediately: true
            )
        }

        for exception in payload.cpuExceptionDiagnostics ?? [] {
            DiagnosticLogger.shared.log(
                .diagnosticReport,
                String(
                    format: "系统 CPU 异常 占用=%.1fs 采样窗口=%.1fs %@",
                    exception.totalCPUTime.converted(to: .seconds).value,
                    exception.totalSampledTime.converted(to: .seconds).value,
                    Self.description(for: exception.metaData)
                ),
                level: .error
            )
        }

        for exception in payload.diskWriteExceptionDiagnostics ?? [] {
            DiagnosticLogger.shared.log(
                .diagnosticReport,
                String(
                    format: "系统磁盘写入异常 写入=%.1fMB %@",
                    exception.totalWritesCaused.converted(to: .megabytes).value,
                    Self.description(for: exception.metaData)
                ),
                level: .warning
            )
        }

        for launch in payload.appLaunchDiagnostics ?? [] {
            DiagnosticLogger.shared.log(
                .diagnosticReport,
                String(
                    format: "系统启动过慢报告 启动耗时=%.2fs %@",
                    launch.launchDuration.converted(to: .seconds).value,
                    Self.description(for: launch.metaData)
                ),
                level: .warning
            )
        }
    }

    private func logSummary(for payload: MXMetricPayload) {
        var parts = ["系统指标日报"]
        if let hangTime = payload.applicationResponsivenessMetrics?
            .histogrammedApplicationHangTime {
            let (count, seconds) = Self.aggregate(hangTime)
            parts.append(String(format: "卡顿次数=%d 累计=%.1fs", count, seconds))
        }
        if let peak = payload.memoryMetrics?.peakMemoryUsage {
            parts.append(String(
                format: "内存峰值=%.1fMB",
                peak.converted(to: .megabytes).value
            ))
        }
        if let cpuTime = payload.cpuMetrics?.cumulativeCPUTime {
            parts.append(String(
                format: "CPU 累计=%.1fs",
                cpuTime.converted(to: .seconds).value
            ))
        }
        DiagnosticLogger.shared.log(.diagnosticReport, parts.joined(separator: " "))
    }

    /// 直方图只取「样本数」与「累计时长」两个数：日报是用来判断趋势的，
    /// 需要分布时去看落盘的 JSON。
    private static func aggregate(
        _ histogram: MXHistogram<UnitDuration>
    ) -> (count: Int, seconds: Double) {
        let buckets = histogram.bucketEnumerator.allObjects
            .compactMap { $0 as? MXHistogramBucket<UnitDuration> }
        let count = buckets.reduce(0) { $0 + $1.bucketCount }
        let seconds = buckets.reduce(0.0) { partial, bucket in
            let mid = (bucket.bucketStart.converted(to: .seconds).value
                + bucket.bucketEnd.converted(to: .seconds).value) / 2
            return partial + mid * Double(bucket.bucketCount)
        }
        return (count, seconds)
    }

    private static func description(for metaData: MXMetaData) -> String {
        "设备=\(metaData.deviceType) 系统=\(metaData.osVersion) 构建=\(metaData.applicationBuildVersion)"
    }
}
#endif
