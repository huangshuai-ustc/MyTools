import Foundation

/// 主线程停顿探测。
///
/// 2026-09-22 那次 `0x8BADF00D` 崩溃里，主线程在 UIKit 的布局链上跑满 10 秒后被
/// scene-update 看门狗杀掉，而诊断日志里一个字都没留下——所有日志都是主线程发起的，
/// 主线程一停就再没有人调用 `log`。所以探测必须整条链路都不经过主线程：
///
/// - 主队列上一个定时器不断刷新 `lastHeartbeat`；主线程一卡，它就不再被调度；
/// - 后台队列上另一个定时器只读时间戳，超过阈值就直接写日志。
///
/// `DiagnosticLogger` 的写盘本来就在它自己的后台队列上，`.error` 级别还会立刻 `fsync`，
/// 因此进程被杀之前记录已经落到文件里。下次复现时日志能直接回答两个问题：卡在哪个页面、
/// 卡了多久。
final class AppHangMonitor: @unchecked Sendable {
    static let shared = AppHangMonitor()

    /// 分档上报，每档只报一次，避免一次长停顿刷出几十行。看门狗的额度是 10 秒，
    /// 所以 8 秒那一档基本就是「即将被杀」的最后一条记录，必须落盘。
    private static let thresholds: [TimeInterval] = [1.5, 4, 8]
    private static let tick: TimeInterval = 0.25
    /// 超过这个时长就不当停顿看：真实成因几乎一定是进程被挂起（断点、系统挂起、
    /// 时钟跳变），报出来只会污染日志。
    private static let suspensionGuard: TimeInterval = 20

    private let queue = DispatchQueue(
        label: "\(AppMetadata.bundleIdentifier).hang-monitor",
        qos: .utility
    )
    private let lock = NSLock()
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var stallStartedAt: TimeInterval?
    private var reportedThresholdIndex = -1
    private var mainTimer: DispatchSourceTimer?
    private var checkTimer: DispatchSourceTimer?

    private init() {}

    /// 只在前台监控。挂起期间主队列定时器不会被调度，恢复后那段空档会被误判成
    /// 一次十几分钟的「停顿」，所以进后台必须 `stop()`。
    func start() {
        queue.async { [self] in
            guard checkTimer == nil else { return }

            lock.lock()
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            stallStartedAt = nil
            reportedThresholdIndex = -1
            lock.unlock()

            let heartbeat = DispatchSource.makeTimerSource(queue: .main)
            heartbeat.schedule(
                deadline: .now() + Self.tick,
                repeating: Self.tick,
                leeway: .milliseconds(50)
            )
            heartbeat.setEventHandler { [weak self] in
                self?.recordHeartbeat()
            }
            mainTimer = heartbeat
            heartbeat.activate()

            let checker = DispatchSource.makeTimerSource(queue: queue)
            checker.schedule(
                deadline: .now() + Self.tick,
                repeating: Self.tick,
                leeway: .milliseconds(50)
            )
            checker.setEventHandler { [weak self] in
                self?.checkForStall()
            }
            checkTimer = checker
            checker.activate()

            DiagnosticLogger.shared.log(.hang, "主线程停顿探测已启动 采样=\(Self.tick)s")
        }
    }

    func stop() {
        queue.async { [self] in
            guard checkTimer != nil else { return }
            mainTimer?.cancel()
            mainTimer = nil
            checkTimer?.cancel()
            checkTimer = nil
            lock.lock()
            stallStartedAt = nil
            reportedThresholdIndex = -1
            lock.unlock()
            DiagnosticLogger.shared.log(.hang, "主线程停顿探测已停止")
        }
    }

    /// 在主线程上跑。除了刷新时间戳，还负责在停顿结束时补一条恢复记录——只有这里
    /// 能确定主线程真的重新转起来了。
    private func recordHeartbeat() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let stallDuration = stallStartedAt.map { now - $0 }
        let wasReported = reportedThresholdIndex >= 0
        lastHeartbeat = now
        stallStartedAt = nil
        reportedThresholdIndex = -1
        lock.unlock()

        guard wasReported, let stallDuration else { return }
        DiagnosticLogger.shared.log(
            .hang,
            String(
                format: "主线程已恢复 停顿共 %.2fs 页面=%@ %@",
                stallDuration,
                DiagnosticLogger.shared.currentScreenDescription,
                DiagnosticLogger.memoryDescription()
            ),
            level: .warning
        )
    }

    /// 在后台队列上跑，主线程卡死时照样执行。
    private func checkForStall() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let gap = now - lastHeartbeat
        guard gap >= Self.thresholds[0], gap < Self.suspensionGuard else {
            lock.unlock()
            return
        }
        if stallStartedAt == nil { stallStartedAt = lastHeartbeat }
        var reachedIndex = -1
        for (index, threshold) in Self.thresholds.enumerated() where gap >= threshold {
            reachedIndex = index
        }
        guard reachedIndex > reportedThresholdIndex else {
            lock.unlock()
            return
        }
        reportedThresholdIndex = reachedIndex
        let threshold = Self.thresholds[reachedIndex]
        lock.unlock()

        // 第一档只是可感知的掉帧，记 WARN；再往上就是随时会被看门狗杀掉的量级，
        // 记 ERROR 让它立刻 fsync。
        let level: DiagnosticLogLevel = reachedIndex == 0 ? .warning : .error
        DiagnosticLogger.shared.log(
            .hang,
            String(
                format: "主线程停顿 ≥%.1fs（已持续 %.2fs）页面=%@ %@ %@",
                threshold,
                gap,
                DiagnosticLogger.shared.currentScreenDescription,
                DiagnosticLogger.memoryDescription(),
                DiagnosticLogger.runtimeConditionDescription()
            ),
            level: level,
            flushesImmediately: true
        )
    }
}
