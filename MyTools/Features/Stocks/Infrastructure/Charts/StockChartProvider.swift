#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockChartRequest: Sendable {
    let stock: StockHolding
    let symbol: String
    let range: StockChartRange

    init(
        stock: StockHolding,
        symbol: String,
        range: StockChartRange
    ) {
        self.stock = stock
        self.symbol = symbol
        self.range = range
    }
}

protocol StockChartProvider: Sendable {
    func fetchChart(for request: StockChartRequest) async throws -> StockChartSnapshot
}

struct StockChartProviders: Sendable {
    let tencent: any StockChartProvider
    let eastmoney: any StockChartProvider
    let yahoo: any StockChartProvider
    let nasdaq: any StockChartProvider

    init(
        tencent: any StockChartProvider = TencentStockChartProvider(),
        eastmoney: any StockChartProvider = EastmoneyStockChartProvider(),
        yahoo: any StockChartProvider = YahooStockChartProvider(),
        nasdaq: any StockChartProvider = NasdaqStockChartProvider()
    ) {
        self.tencent = tencent
        self.eastmoney = eastmoney
        self.yahoo = yahoo
        self.nasdaq = nasdaq
    }
}

protocol StockChartHTTPClient: Sendable {
    func data(for url: URL, referer: String) async throws -> Data
}

struct URLSessionStockChartHTTPClient: StockChartHTTPClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func data(for url: URL, referer: String) async throws -> Data {
        try Task.checkCancellation()
        let host = url.host ?? "unknown"
        if let remaining = StockDataSourceCircuitBreaker.shared.rejectRequest(for: host) {
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=http跳过 host=\(host) 熔断剩余=\(Int(remaining))s", level: .debug)
            throw StockChartError.serviceUnavailable
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 8
        )
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let started = Date()
        do {
            let (data, response) = try await Self.session.data(for: request)
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DiagnosticLogger.shared.log(.stockQuote, "图表阶段=http host=\(host) status=\(status) bytes=\(data.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            StockDataSourceCircuitBreaker.shared.record(status: status, for: host, startedAt: started)
            guard (200..<300).contains(status) else { throw StockChartError.serviceUnavailable }
            return data
        } catch let error as StockChartError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let elapsed = Date().timeIntervalSince(started)
            let isCancellation = DiagnosticLogger.isCancellation(error)
            let wasSuspended = StockDataSourceCircuitBreaker.wasSuspended(elapsed: elapsed)
            if !isCancellation {
                StockDataSourceCircuitBreaker.shared.record(error, for: host, startedAt: started)
            }
            // -999 是主动取消；耗时远超超时上限说明进程被挂起过，都不是数据源本身的问题。
            let note = isCancellation ? " 已取消" : (wasSuspended ? " 疑似进程挂起" : "")
            DiagnosticLogger.shared.log(.stockQuote,
                "图表阶段=http失败 host=\(host) error=\(DiagnosticLogger.errorCode(error)) ms=\(Int(elapsed * 1000))\(note)",
                level: isCancellation || wasSuspended ? .info : .warning)
            throw error
        }
    }
}

/// Per-host circuit breaker shared by the chart and quote HTTP clients.
///
/// After `failureThreshold` consecutive transport failures (timeouts, lost
/// connections, TLS errors, HTTP 429/5xx) a host is skipped for a cooldown
/// that doubles on each re-trip up to `maximumCooldown`, so the next provider
/// in the fallback chain answers at once instead of after another timeout.
/// The first request after the cooldown is a probe: success closes the
/// breaker, failure re-opens it. Cancellation, device-offline errors and
/// requests that outlived a suspension are not held against the host.
final class StockDataSourceCircuitBreaker: @unchecked Sendable {
    static let shared = StockDataSourceCircuitBreaker()

    private struct HostState {
        var consecutiveFailures = 0
        var trips = 0
        var openUntil: Date?
        var skippedRequests = 0
    }

    let failureThreshold: Int
    let baseCooldown: TimeInterval
    let maximumCooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var hosts: [String: HostState] = [:]

    init(
        failureThreshold: Int = 4,
        baseCooldown: TimeInterval = 120,
        maximumCooldown: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.baseCooldown = baseCooldown
        self.maximumCooldown = max(baseCooldown, maximumCooldown)
        self.now = now
    }

    /// Returns the remaining cooldown when the host must be skipped.
    func rejectRequest(for host: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let openUntil = hosts[host]?.openUntil else { return nil }
        let remaining = openUntil.timeIntervalSince(now())
        guard remaining > 0 else { return nil }
        hosts[host]?.skippedRequests += 1
        return remaining
    }

    func record(status: Int, for host: String, startedAt: Date) {
        if status == 429 || (500..<600).contains(status) {
            recordFailure(for: host, code: "HTTP(\(status))", startedAt: startedAt)
        } else {
            recordSuccess(for: host)
        }
    }

    func record(_ error: Error, for host: String, startedAt: Date) {
        guard Self.countsAgainstHost(error) else { return }
        recordFailure(for: host, code: DiagnosticLogger.errorCode(error), startedAt: startedAt)
    }

    func recordSuccess(for host: String) {
        lock.lock()
        let previous = hosts.removeValue(forKey: host)
        lock.unlock()
        guard let previous, previous.trips > 0 else { return }
        DiagnosticLogger.shared.log(.stockQuote, "数据源恢复 host=\(host) 熔断次数=\(previous.trips) 期间跳过=\(previous.skippedRequests)")
    }

    private func recordFailure(for host: String, code: String, startedAt: Date) {
        let date = now()
        guard !Self.wasSuspended(elapsed: date.timeIntervalSince(startedAt)) else { return }
        lock.lock()
        var state = hosts[host] ?? HostState()
        // Requests already in flight when the breaker opened must not extend it.
        if let openUntil = state.openUntil, openUntil > date {
            lock.unlock()
            return
        }
        state.consecutiveFailures += 1
        var cooldown: TimeInterval?
        if state.consecutiveFailures >= failureThreshold {
            state.trips += 1
            let value = min(baseCooldown * pow(2, Double(state.trips - 1)), maximumCooldown)
            state.openUntil = date.addingTimeInterval(value)
            cooldown = value
        }
        hosts[host] = state
        let failures = state.consecutiveFailures
        let trips = state.trips
        lock.unlock()
        guard let cooldown else { return }
        DiagnosticLogger.shared.log(.stockQuote,
            "数据源熔断 host=\(host) 连续失败=\(failures) 最近错误=\(code) 冷却=\(Int(cooldown))s 第\(trips)次", level: .warning)
    }

    static func countsAgainstHost(_ error: Error) -> Bool {
        guard !DiagnosticLogger.isCancellation(error) else { return false }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        switch value.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
            return false // The device is offline; every host would trip at once.
        default:
            return true
        }
    }

    /// Any request is bounded to about 12 s; one that took far longer was
    /// frozen while the app was suspended.
    static func wasSuspended(elapsed: TimeInterval) -> Bool {
        elapsed > 30
    }
}

#endif
