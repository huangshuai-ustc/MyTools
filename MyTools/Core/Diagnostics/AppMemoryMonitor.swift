import Foundation
#if os(iOS)
import UIKit
#endif

/// 内存足迹采样。
///
/// 目的很具体：股票图表缓存目前没有上限，行情刷新与切换股票都会往里塞数据，但日志里
/// 从来看不到内存曲线，只能等到崩溃报告出来才知道有没有踩到 jetsam。这里在后台按固定
/// 节奏取 `phys_footprint`，并且只在「涨了一截」或「隔了很久」时写一行，避免把日志刷满。
final class AppMemoryMonitor: @unchecked Sendable {
    static let shared = AppMemoryMonitor()

    private static let tick: TimeInterval = 15
    /// 比上次记录的峰值多这么多才写一行。
    private static let growthThreshold: UInt64 = 24 * 1_048_576
    /// 即使一直平稳，也每隔这么久留一个基准点。
    private static let heartbeatInterval: TimeInterval = 180

    private let queue = DispatchQueue(
        label: "\(AppMetadata.bundleIdentifier).memory-monitor",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var lastLoggedBytes: UInt64 = 0
    private var lastLoggedAt: TimeInterval = 0
    private var peakBytes: UInt64 = 0
#if os(iOS)
    private var memoryWarningObserver: NSObjectProtocol?
#endif

    private init() {}

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.tick, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in
                self?.sample()
            }
            self.timer = timer
            timer.activate()
            observeMemoryWarningsIfNeeded()
        }
    }

    func stop() {
        queue.async { [self] in
            guard let timer else { return }
            timer.cancel()
            self.timer = nil
            // 进后台时留一个终点：和下次进前台的第一条对比，就能看出挂起期间系统回收了多少。
            report(reason: "进入后台", level: .info, force: true)
        }
    }

    /// 峰值只增不减，用来回答「这次会话最高到过多少」。
    var peakFootprintBytes: UInt64 {
        queue.sync { peakBytes }
    }

    private func sample() {
        guard let bytes = DiagnosticLogger.memoryFootprintBytes() else { return }
        if bytes > peakBytes { peakBytes = bytes }
        let now = ProcessInfo.processInfo.systemUptime
        let grewEnough = bytes > lastLoggedBytes
            && bytes - lastLoggedBytes >= Self.growthThreshold
        let waitedEnough = now - lastLoggedAt >= Self.heartbeatInterval
        guard grewEnough || waitedEnough else { return }
        report(reason: grewEnough ? "增长" : "采样", level: .info, force: false)
    }

    private func report(reason: String, level: DiagnosticLogLevel, force: Bool) {
        guard let bytes = DiagnosticLogger.memoryFootprintBytes() else { return }
        if bytes > peakBytes { peakBytes = bytes }
        let delta = Double(Int64(bytes) - Int64(lastLoggedBytes)) / 1_048_576
        lastLoggedBytes = bytes
        lastLoggedAt = ProcessInfo.processInfo.systemUptime
        DiagnosticLogger.shared.log(
            .memory,
            String(
                format: "%@ 内存=%.1fMB 变化=%+.1fMB 峰值=%.1fMB 页面=%@",
                reason,
                Double(bytes) / 1_048_576,
                delta,
                Double(peakBytes) / 1_048_576,
                DiagnosticLogger.shared.currentScreenDescription
            ),
            level: level,
            flushesImmediately: force
        )
    }

    private func observeMemoryWarningsIfNeeded() {
#if os(iOS)
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // 收到内存警告离 jetsam 已经很近了，立刻落盘。
            self?.queue.async {
                self?.report(reason: "收到系统内存警告", level: .warning, force: true)
            }
        }
#endif
    }
}
