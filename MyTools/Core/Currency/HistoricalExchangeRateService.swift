import Foundation

struct ReferenceExchangeRatePoint: Codable, Equatable, Sendable, Identifiable {
    let date: Date
    /// CNY per one unit; reference rates, never bank bid/ask prices.
    let renminbiPerUnit: [CurrencyCode: Decimal]
    var id: Date { date }
}

enum HistoricalExchangeRateServiceError: LocalizedError, Sendable {
    case invalidResponse
    case unsupportedCache
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "历史参考汇率返回了无效数据。"
        case .unsupportedCache: return "历史汇率缓存无法读取，原文件已保留。可在设置中清理本地缓存后重试。"
        }
    }
}

actor HistoricalExchangeRateService {
    static let shared = HistoricalExchangeRateService()
    static let supportedCodes = Set("AUD BRL CAD CHF CNY CZK DKK EUR GBP HKD HUF IDR ILS INR ISK JPY KRW MXN MYR NOK NZD PHP PLN RON SEK SGD THB TRY USD ZAR".split(separator: " ").map(String.init))
    struct MonthCache: Codable, Equatable {
        var version = 1
        var source = "frankfurter-v1"
        let fetchedAt: Date
        let through: Date
        let points: [ReferenceExchangeRatePoint]
    }
    private let directory: URL
    private let session: URLSession
    private var generation = UUID()
    init(directory: URL? = nil, session: URLSession = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTools/ReferenceExchangeRates", isDirectory: true)
        self.session = session
    }
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    static func formatter() -> DateFormatter {
        let value = DateFormatter()
        value.calendar = calendar
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = calendar.timeZone
        value.dateFormat = "yyyy-MM-dd"
        return value
    }
    func cachedPoints() throws -> [ReferenceExchangeRatePoint] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try files.flatMap { try Self.decodeCache(Data(contentsOf: $0)).points }.sorted { $0.date < $1.date }
    }
    func clear() throws {
        generation = UUID()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func fetch(from start: Date, to end: Date, currencies: [CurrencyCode]) async throws -> [ReferenceExchangeRatePoint] {
        let token = generation
        let calendar = Self.calendar
        let formatter = Self.formatter()
        let end = calendar.startOfDay(for: end)
        guard start <= end.addingTimeInterval(86400), let firstMonth = calendar.dateInterval(of: .month, for: start)?.start else {
            throw HistoricalExchangeRateServiceError.invalidResponse
        }
        var month = firstMonth
        var result: [ReferenceExchangeRatePoint] = []
        while month <= end {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let next = calendar.date(byAdding: .month, value: 1, to: month)!
            let through = min(end, next.addingTimeInterval(-86400))
            let url = directory.appendingPathComponent(formatter.string(from: month) + ".json")
            var cached: MonthCache?
            if FileManager.default.fileExists(atPath: url.path) {
                do { cached = try Self.decodeCache(Data(contentsOf: url)) }
                catch { throw HistoricalExchangeRateServiceError.unsupportedCache }
            }
            let needsRefresh = cached == nil || cached!.through < through ||
                (through >= end.addingTimeInterval(-7 * 86400) && Date().timeIntervalSince(cached!.fetchedAt) > 3600)
            if needsRefresh {
                do {
                    // Fetch all reference currencies together: changing the chart pair needs no new request.
                    let endpoint = URL(string: "https://api.frankfurter.dev/v1/\(formatter.string(from: month))..\(formatter.string(from: through))?base=CNY")!
                    let (data, response) = try await session.data(for: URLRequest(url: endpoint, timeoutInterval: 20))
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw HistoricalExchangeRateServiceError.invalidResponse }
                    let points = try Self.decodeResponse(data, from: month, through: through)
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    let updated = MonthCache(fetchedAt: Date(), through: through, points: points)
                    let bytes = try JSONEncoder().encode(updated)
                    guard try Self.decodeCache(bytes) == updated else { throw HistoricalExchangeRateServiceError.invalidResponse }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var folder = directory
                    var values = URLResourceValues(); values.isExcludedFromBackup = true
                    try folder.setResourceValues(values)
                    try bytes.write(to: url, options: .atomic)
                    cached = updated
                } catch {
                    // Valid older files remain untouched. A failed range is not marked covered.
                    throw error
                }
            }
            result += cached?.points ?? []
            month = next
        }
        return result.filter { $0.date >= calendar.startOfDay(for: start) && $0.date <= end }.sorted { $0.date < $1.date }
    }
    static func decodeCache(_ data: Data) throws -> MonthCache {
        let cache = try JSONDecoder().decode(MonthCache.self, from: data)
        guard cache.version == 1, cache.source == "frankfurter-v1",
              Set(cache.points.map(\.date)).count == cache.points.count,
              cache.points.allSatisfy({ $0.date <= cache.through && $0.renminbiPerUnit[.cny] == 1 && $0.renminbiPerUnit.values.allSatisfy { !$0.isNaN && $0 > 0 } }) else {
            throw HistoricalExchangeRateServiceError.unsupportedCache
        }
        return cache
    }
    static func decodeResponse(_ data: Data, from start: Date, through end: Date) throws -> [ReferenceExchangeRatePoint] {
        struct Payload: Decodable { let base: String; let rates: [String: [String: Decimal]] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.base == "CNY", !payload.rates.isEmpty else { throw HistoricalExchangeRateServiceError.invalidResponse }
        let formatter = formatter()
        var result: [ReferenceExchangeRatePoint] = []
        for (day, rates) in payload.rates {
            guard let date = formatter.date(from: day), formatter.string(from: date) == day,
                  !rates.isEmpty, rates.values.allSatisfy({ !$0.isNaN && $0 > 0 }) else { throw HistoricalExchangeRateServiceError.invalidResponse }
            guard date >= start, date <= end else { continue } // API can return the preceding business day.
            var converted: [CurrencyCode: Decimal] = [.cny: 1]
            for (code, value) in rates {
                if let currency = CurrencyCode(rawValue: code) { converted[currency] = 1 / value }
            }
            guard converted[.usd] != nil else { throw HistoricalExchangeRateServiceError.invalidResponse }
            result.append(ReferenceExchangeRatePoint(date: date, renminbiPerUnit: converted))
        }
        return result.sorted { $0.date < $1.date }
    }
}
