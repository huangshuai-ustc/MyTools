#if MYTOOLS_FEATURE_SPORTS_LOTTERY
import Foundation

protocol SportsLotteryProviding: Sendable {
    func cachedSnapshot(leagues: [SportsLotteryLeague]) async -> SportsLotterySnapshot?
    func fetchSnapshot(leagues: [SportsLotteryLeague], forceRefresh: Bool) async throws -> SportsLotterySnapshot
    func findLeague(named name: String) async throws -> SportsLotteryLeague?
}

extension SportsLotteryProviding {
    func fetchSnapshot(forceRefresh: Bool) async throws -> SportsLotterySnapshot {
        try await fetchSnapshot(leagues: SportsLotteryLeague.allCases, forceRefresh: forceRefresh)
    }
}

protocol SportsLotteryHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionSportsLotteryHTTPClient: SportsLotteryHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

enum SportsLotteryServiceError: LocalizedError {
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "官方接口返回了无法识别的数据。"
        case .service(let message):
            return message
        }
    }
}

actor SportsLotteryService: SportsLotteryProviding {
    static let shared = SportsLotteryService()

    private static let apiBase = URL(string: "https://webapi.sporttery.cn")!
    private static let resultPageSize = 30
    private static let initialHistoryDays = 30
    private static let incrementalOverlapDays = 3
    private static let enrichmentConcurrency = 6
    private static let cacheFileName = "sports-lottery-cache-v1.json"

    private let httpClient: any SportsLotteryHTTPClient
    private let cacheFileURL: URL?
    private var hasLoadedPersistence = false
    private var persistedLeagues: [Int: PersistedLeagueCache] = [:]
    private var cachedLeagueDirectory: [SportsLotteryLeague]?
    private var cacheGeneration = 0

    init(
        httpClient: any SportsLotteryHTTPClient = URLSessionSportsLotteryHTTPClient(),
        cacheFileURL: URL? = nil
    ) {
        self.httpClient = httpClient
        self.cacheFileURL = cacheFileURL ?? Self.defaultCacheFileURL()
    }

    func fetchSnapshot(
        leagues: [SportsLotteryLeague],
        forceRefresh: Bool = false
    ) async throws -> SportsLotterySnapshot {
        loadPersistenceIfNeeded()
        let selected = unique(leagues)
        guard !selected.isEmpty else {
            return snapshot(for: selected)
        }

        let automaticSlot = Self.automaticRefreshSlot(for: Date())
        let generation = cacheGeneration
        let dueLeagues = selected.filter { league in
            guard let cache = persistedLeagues[league.leagueID] else { return true }
            if forceRefresh { return true }
            return cache.lastAutomaticRefreshSlot != automaticSlot
        }
        if !dueLeagues.isEmpty {
            try await refresh(
                dueLeagues,
                automaticSlot: automaticSlot,
                generation: generation
            )
        }
        return snapshot(for: selected)
    }

    func cachedSnapshot(leagues: [SportsLotteryLeague]) async -> SportsLotterySnapshot? {
        loadPersistenceIfNeeded()
        let selected = unique(leagues)
        guard selected.contains(where: { persistedLeagues[$0.leagueID] != nil }) else { return nil }
        return snapshot(for: selected)
    }

    func findLeague(named name: String) async throws -> SportsLotteryLeague? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let directory: [SportsLotteryLeague]
        if let cachedLeagueDirectory {
            directory = cachedLeagueDirectory
        } else {
            let range = Self.initialDateRange()
            let page = try await fetchResultPage(leagueID: nil, range: range, pageNumber: 1)
            directory = page.leagues.map {
                SportsLotteryLeague(
                    leagueID: $0.leagueID,
                    title: $0.leagueAbbreviation,
                    officialName: $0.leagueFullName
                )
            }
            cachedLeagueDirectory = directory
        }

        return directory.first {
            $0.title.caseInsensitiveCompare(normalized) == .orderedSame
                || $0.officialName.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private func refresh(
        _ leagues: [SportsLotteryLeague],
        automaticSlot: Date?,
        generation: Int
    ) async throws {
        for league in leagues {
            let oldCache = persistedLeagues[league.leagueID]
            let range = Self.refreshDateRange(for: oldCache)
            let candidates = try await fetchResultCandidates(league: league, range: range)
            guard generation == cacheGeneration else { return }
            let uniqueCandidates = candidates.reduce(into: [Int: MatchCandidate]()) { result, candidate in
                result[candidate.id] = candidate
            }
            var merged = Dictionary(uniqueKeysWithValues: (oldCache?.matches ?? []).map { ($0.id, $0) })
            let candidatesNeedingEnrichment = uniqueCandidates.values.filter { candidate in
                merged[candidate.id]?.hasCompleteResult != true
            }
            let matches = await enrich(Array(candidatesNeedingEnrichment)).sorted(by: SportsLotteryMatch.isNewer)
            guard generation == cacheGeneration else { return }
            for match in matches {
                merged[match.id] = match
            }
            let sortedMatches = merged.values.sorted(by: SportsLotteryMatch.isNewer)
            persistedLeagues[league.leagueID] = PersistedLeagueCache(
                league: league,
                matches: sortedMatches,
                lastRefreshAt: Date(),
                lastAutomaticRefreshSlot: automaticSlot ?? oldCache?.lastAutomaticRefreshSlot
            )
            try savePersistence()
        }
    }

    func clearCache() {
        cacheGeneration += 1
        hasLoadedPersistence = true
        persistedLeagues.removeAll()
        cachedLeagueDirectory = nil
        guard let cacheFileURL,
              FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }
        try? FileManager.default.removeItem(at: cacheFileURL)
    }

    private func snapshot(for leagues: [SportsLotteryLeague]) -> SportsLotterySnapshot {
        let matches = leagues.flatMap { persistedLeagues[$0.leagueID]?.matches ?? [] }
        let fetchedAt = leagues.compactMap { persistedLeagues[$0.leagueID]?.lastRefreshAt }.max() ?? Date()
        return SportsLotterySnapshot(fetchedAt: fetchedAt, matches: matches.sorted(by: SportsLotteryMatch.isNewer))
    }

    private func fetchResultCandidates(
        league: SportsLotteryLeague,
        range: ClosedRange<Date>
    ) async throws -> [MatchCandidate] {
        var pageNumber = 1
        var candidates: [MatchCandidate] = []
        while true {
            let page = try await fetchResultPage(
                leagueID: league.leagueID,
                range: range,
                pageNumber: pageNumber
            )
            candidates += page.matches.compactMap { Self.parseCandidate($0, selectedLeague: league) }
            if pageNumber >= page.pageCount { break }
            pageNumber += 1
        }
        return candidates
    }

    private func enrich(_ candidates: [MatchCandidate]) async -> [SportsLotteryMatch] {
        await withTaskGroup(of: SportsLotteryMatch.self) { group in
            var iterator = candidates.makeIterator()
            for _ in 0..<min(Self.enrichmentConcurrency, candidates.count) {
                guard let candidate = iterator.next() else { break }
                group.addTask { [httpClient] in
                    await Self.enrich(candidate, client: httpClient)
                }
            }

            var matches: [SportsLotteryMatch] = []
            while let match = await group.next() {
                matches.append(match)
                guard let candidate = iterator.next() else { continue }
                group.addTask { [httpClient] in
                    await Self.enrich(candidate, client: httpClient)
                }
            }
            return matches
        }
    }

    private func fetchResultPage(
        leagueID: Int?,
        range: ClosedRange<Date>,
        pageNumber: Int
    ) async throws -> ResultPage {
        var components = URLComponents(
            url: Self.apiBase.appendingPathComponent("gateway/uniform/football/getUniformMatchResultV1.qry"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "matchBeginDate", value: Self.dayFormatter.string(from: range.lowerBound)),
            URLQueryItem(name: "matchEndDate", value: Self.dayFormatter.string(from: range.upperBound)),
            URLQueryItem(name: "leagueId", value: leagueID.map(String.init) ?? ""),
            URLQueryItem(name: "pageSize", value: String(Self.resultPageSize)),
            URLQueryItem(name: "pageNo", value: String(pageNumber)),
            URLQueryItem(name: "isFix", value: "0"),
            URLQueryItem(name: "matchPage", value: "1"),
            URLQueryItem(name: "pcOrWap", value: "1")
        ]
        guard let url = components?.url else { throw SportsLotteryServiceError.invalidResponse }
        let (data, response) = try await httpClient.data(for: Self.request(url))
        try Self.validate(response)
        let envelope = try JSONDecoder().decode(ResultEnvelope.self, from: data)
        guard envelope.errorCode == "0", let value = envelope.value else {
            throw SportsLotteryServiceError.service(envelope.errorMessage ?? "官方赛果服务暂时不可用。")
        }
        return ResultPage(
            pageCount: max(value.pages ?? 1, 1),
            leagues: value.leagueList ?? [],
            matches: value.matchResult ?? []
        )
    }

    private static func enrich(
        _ candidate: MatchCandidate,
        client: any SportsLotteryHTTPClient
    ) async -> SportsLotteryMatch {
        async let head = fetchHead(matchID: candidate.id, client: client)
        let outcomes: [SportsLotteryOutcome]
        if let url = URL(
            string: "/gateway/uniform/football/getFixedBonusV1.qry?clientCode=3001&matchId=\(candidate.id)",
            relativeTo: apiBase
        ) {
            do {
                let (data, response) = try await client.data(for: request(url))
                try validate(response)
                let envelope = try JSONDecoder().decode(FixedBonusEnvelope.self, from: data)
                outcomes = (envelope.value?.matchResultList ?? []).compactMap { item in
                    guard let code = SportsLotteryOutcomeCode(rawValue: item.code.uppercased()),
                          !item.combinationDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    return SportsLotteryOutcome(code: code, value: item.combinationDesc, odds: item.odds)
                }
            } catch {
                outcomes = []
            }
        } else {
            outcomes = []
        }

        let matchHead = await head
        return SportsLotteryMatch(
            id: candidate.id,
            league: candidate.league,
            leagueName: matchHead?.tournamentName ?? candidate.leagueName,
            homeTeam: matchHead?.homeTeam ?? candidate.homeTeam,
            awayTeam: matchHead?.awayTeam ?? candidate.awayTeam,
            matchNumber: matchHead?.matchNumber ?? candidate.matchNumber,
            date: parseDateTime(matchHead?.matchDateTime) ?? candidate.date,
            score: matchHead?.score ?? candidate.score,
            outcomes: outcomes
        )
    }

    private static func fetchHead(
        matchID: Int,
        client: any SportsLotteryHTTPClient
    ) async -> MatchHead? {
        guard let url = URL(
            string: "/gateway/uniform/football/getMatchHeadV1.qry?source=web&sportteryMatchId=\(matchID)",
            relativeTo: apiBase
        ) else { return nil }
        do {
            let (data, response) = try await client.data(for: request(url))
            try validate(response)
            let envelope = try JSONDecoder().decode(MatchHeadEnvelope.self, from: data)
            guard envelope.errorCode == "0" else { return nil }
            return envelope.value
        } catch {
            return nil
        }
    }

    private static func parseCandidate(
        _ dto: ResultMatchDTO,
        selectedLeague: SportsLotteryLeague
    ) -> MatchCandidate? {
        guard dto.leagueID == selectedLeague.leagueID,
              let date = dayFormatter.date(from: dto.matchDate) else {
            return nil
        }
        let league = SportsLotteryLeague(
            leagueID: dto.leagueID,
            title: dto.leagueNameAbbreviation.isEmpty ? selectedLeague.title : dto.leagueNameAbbreviation,
            officialName: dto.leagueName.isEmpty ? selectedLeague.officialName : dto.leagueName
        )
        return MatchCandidate(
            id: dto.matchID,
            league: league,
            leagueName: league.officialName,
            homeTeam: dto.homeTeam,
            awayTeam: dto.awayTeam,
            matchNumber: dto.matchNumber,
            date: date,
            score: dto.fullTimeScore
        )
    }

    private static func initialDateRange(now: Date = Date()) -> ClosedRange<Date> {
        dateRange(daysBack: initialHistoryDays, now: now)
    }

    private static func refreshDateRange(for cache: PersistedLeagueCache?) -> ClosedRange<Date> {
        guard let cache else { return initialDateRange() }
        let calendar = shanghaiCalendar
        let today = calendar.startOfDay(for: Date())
        let fallbackStart = calendar.date(byAdding: .day, value: -incrementalOverlapDays, to: today) ?? today
        let historyFloor = calendar.date(byAdding: .day, value: -initialHistoryDays, to: today) ?? today
        let pendingStart = cache.matches
            .filter { !$0.hasCompleteResult }
            .map(\.date)
            .min()
            .flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
        let start = max(min(pendingStart ?? fallbackStart, fallbackStart), historyFloor)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return start...end
    }

    private static func dateRange(daysBack: Int, now: Date) -> ClosedRange<Date> {
        let calendar = shanghaiCalendar
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let start = calendar.date(byAdding: .day, value: -daysBack, to: end) ?? end
        return start...end
    }

    static func automaticRefreshSlot(for date: Date) -> Date {
        let calendar = shanghaiCalendar
        let day = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        let slotHour = hour >= 22 ? 22 : (hour >= 10 ? 10 : 22)
        let slotDay = hour >= 10 ? day : (calendar.date(byAdding: .day, value: -1, to: day) ?? day)
        return calendar.date(bySettingHour: slotHour, minute: 0, second: 0, of: slotDay) ?? date
    }

    static func nextAutomaticRefreshDate(after date: Date) -> Date {
        let calendar = shanghaiCalendar
        let day = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        if hour < 10 {
            return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? date
        }
        if hour < 22 {
            return calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day) ?? date
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? date
    }

    private static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    private func loadPersistenceIfNeeded() {
        guard !hasLoadedPersistence else { return }
        hasLoadedPersistence = true
        guard let cacheFileURL,
              let data = try? Data(contentsOf: cacheFileURL),
              let document = try? JSONDecoder().decode(SportsLotteryCacheDocument.self, from: data) else {
            return
        }
        persistedLeagues = Dictionary(uniqueKeysWithValues: document.leagues.map { ($0.league.leagueID, $0) })
    }

    private func savePersistence() throws {
        guard let cacheFileURL else { return }
        var directory = cacheFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryValues = URLResourceValues()
        // This directory also contains the business vault and attachments.
        // Keep the cache itself out of device backups without excluding them.
        directoryValues.isExcludedFromBackup = false
        try? directory.setResourceValues(directoryValues)
        let document = SportsLotteryCacheDocument(leagues: persistedLeagues.values.sorted { $0.league.leagueID < $1.league.leagueID })
        try JSONEncoder().encode(document).write(to: cacheFileURL, options: .atomic)
        var cacheValues = URLResourceValues()
        cacheValues.isExcludedFromBackup = true
        var persistedCacheURL = cacheFileURL
        try? persistedCacheURL.setResourceValues(cacheValues)
    }

    private static func defaultCacheFileURL() -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("MyTools", isDirectory: true)
            .appendingPathComponent(cacheFileName, isDirectory: false)
    }

    private static func parseDateTime(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = value.count == 16 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.sporttery.cn", forHTTPHeaderField: "Referer")
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw SportsLotteryServiceError.invalidResponse
        }
    }

    private func unique(_ leagues: [SportsLotteryLeague]) -> [SportsLotteryLeague] {
        var seen = Set<Int>()
        return leagues.filter { seen.insert($0.leagueID).inserted }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct PersistedLeagueCache: Codable, Sendable {
    let league: SportsLotteryLeague
    var matches: [SportsLotteryMatch]
    var lastRefreshAt: Date?
    var lastAutomaticRefreshSlot: Date?
}

private struct SportsLotteryCacheDocument: Codable, Sendable {
    let leagues: [PersistedLeagueCache]
}

private struct MatchCandidate: Sendable {
    let id: Int
    let league: SportsLotteryLeague
    let leagueName: String
    let homeTeam: String
    let awayTeam: String
    let matchNumber: String
    let date: Date
    let score: String?
}

private struct ResultPage {
    let pageCount: Int
    let leagues: [ResultLeagueDTO]
    let matches: [ResultMatchDTO]
}

private struct ResultEnvelope: Decodable {
    let errorCode: String
    let errorMessage: String?
    let value: ResultValue?
}

private struct ResultValue: Decodable {
    let pages: Int?
    let leagueList: [ResultLeagueDTO]?
    let matchResult: [ResultMatchDTO]?
}

private struct ResultLeagueDTO: Decodable {
    let leagueID: Int
    let leagueAbbreviation: String
    let leagueFullName: String

    private enum CodingKeys: String, CodingKey {
        case leagueID = "leagueId"
        case leagueAbbreviation = "leagueAbbName"
        case leagueFullName = "leagueAllName"
    }
}

private struct ResultMatchDTO: Decodable {
    let matchID: Int
    let leagueID: Int
    let leagueName: String
    let leagueNameAbbreviation: String
    let homeTeam: String
    let awayTeam: String
    let matchDate: String
    let matchNumber: String
    let fullTimeScore: String?

    private enum CodingKeys: String, CodingKey {
        case matchID = "matchId"
        case leagueID = "leagueId"
        case leagueName
        case leagueNameAbbreviation = "leagueNameAbbr"
        case homeTeam
        case awayTeam
        case matchDate
        case matchNumber = "matchNumStr"
        case fullTimeScore = "sectionsNo999"
    }
}

private struct FixedBonusEnvelope: Decodable {
    let value: FixedBonusValue?
}

private struct FixedBonusValue: Decodable {
    let matchResultList: [MatchResultDTO]?
}

private struct MatchResultDTO: Decodable {
    let code: String
    let combinationDesc: String
    let odds: String?
}

private struct MatchHeadEnvelope: Decodable {
    let errorCode: String
    let value: MatchHead?
}

private struct MatchHead: Decodable {
    let tournamentName: String?
    let homeTeam: String?
    let awayTeam: String?
    let matchNumber: String?
    let matchDateTime: String?
    let score: String?

    private enum CodingKeys: String, CodingKey {
        case tournamentName = "tournamentCnName"
        case homeTeam = "homeTeamShortName"
        case awayTeam = "awayTeamShortName"
        case matchNumber = "matchNum"
        case matchDateTime
        case score = "fullCourtGoal"
    }
}
#endif
