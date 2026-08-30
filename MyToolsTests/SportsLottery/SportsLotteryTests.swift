#if MYTOOLS_FEATURE_SPORTS_LOTTERY
import Foundation
import Testing
@testable import MyTools

@MainActor
struct SportsLotteryTests {
    @Test func outcomeHeadersUseRequestedOrderAndAbbreviations() {
        #expect(SportsLotteryOutcomeCode.allCases == [.had, .hhad, .hafu, .ttg, .crs])
        #expect(SportsLotteryOutcomeCode.allCases.map(\.title) == ["胜平负", "让球", "半全场", "总进球", "比分"])
    }

    @Test func officialLeagueNamesMapToSupportedLeagues() {
        #expect(SportsLotteryLeague.match(for: "英格兰超级联赛") == .premierLeague)
        #expect(SportsLotteryLeague.match(for: "西班牙甲级联赛") == .laLiga)
        #expect(SportsLotteryLeague.match(for: "意大利甲级联赛") == .serieA)
        #expect(SportsLotteryLeague.match(for: "德国甲级联赛") == .bundesliga)
        #expect(SportsLotteryLeague.match(for: "法国甲级联赛") == .ligue1)
        #expect(SportsLotteryLeague.match(for: "欧冠") == .championsLeague)
        #expect(SportsLotteryLeague.match(for: "欧洲冠军联赛") == .championsLeague)
        #expect(SportsLotteryLeague.match(for: "英格兰冠军联赛") == nil)
        #expect(!ToolModule.sportsLottery.definition.participatesInBackup)
        #expect(!ToolModule.sportsLottery.definition.participatesInCloudSync)
        #expect(!ToolModuleCatalog.backupModules.contains(.sportsLottery))
        #expect(!ToolModuleCatalog.cloudSyncModules.contains(.sportsLottery))
    }

    @Test func leaguePreferencesDefaultToSixAndPreserveAnEmptySelection() {
        let suiteName = "SportsLotteryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            SportsLotteryLeaguePreferences.load(from: defaults)
                == [.bundesliga, .ligue1, .championsLeague, .laLiga, .serieA, .premierLeague]
        )
        SportsLotteryLeaguePreferences.save([.championsLeague], to: defaults)
        #expect(SportsLotteryLeaguePreferences.load(from: defaults) == [.championsLeague])
        SportsLotteryLeaguePreferences.save([], to: defaults)
        #expect(SportsLotteryLeaguePreferences.load(from: defaults).isEmpty)
    }

    @Test func leaguePreferencesUsePinyinDictionaryOrder() {
        let suiteName = "SportsLotterySortingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SportsLotteryLeaguePreferences.save(
            [.premierLeague, .championsLeague, .bundesliga],
            to: defaults
        )

        #expect(
            SportsLotteryLeaguePreferences.load(from: defaults)
                == [.bundesliga, .championsLeague, .premierLeague]
        )
    }

    @Test func matchOrderPreferencesPersistPerLeague() {
        let suiteName = "SportsLotteryMatchOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SportsLotteryMatchOrderPreferences.load(for: 69, from: defaults).isEmpty)
        SportsLotteryMatchOrderPreferences.save([7, 6], for: 69, to: defaults)
        SportsLotteryMatchOrderPreferences.save([3, 2], for: 25, to: defaults)
        #expect(SportsLotteryMatchOrderPreferences.load(for: 69, from: defaults) == [7, 6])
        #expect(SportsLotteryMatchOrderPreferences.load(for: 25, from: defaults) == [3, 2])
    }

    @Test func matchGroupsCanBeSortedNewestFirst() {
        let old = SportsLotteryMatch(
            id: 1, league: .premierLeague, leagueName: "英格兰超级联赛",
            homeTeam: "A", awayTeam: "B", matchNumber: "周一001",
            date: Date(timeIntervalSince1970: 10), score: nil, outcomes: []
        )
        let recent = SportsLotteryMatch(
            id: 2, league: .premierLeague, leagueName: "英格兰超级联赛",
            homeTeam: "C", awayTeam: "D", matchNumber: "周一002",
            date: Date(timeIntervalSince1970: 20), score: "1:0", outcomes: []
        )
        let snapshot = SportsLotterySnapshot(fetchedAt: Date(), matches: [recent, old])
        #expect(snapshot.matchesByLeague[.premierLeague]?.map(\.id) == [2, 1])
    }

    @Test func sameTimeMatchesAreSortedByMatchNumberDescending() {
        let date = Date(timeIntervalSince1970: 20)
        let match006 = SportsLotteryMatch(
            id: 6, league: .premierLeague, leagueName: "英格兰超级联赛",
            homeTeam: "A", awayTeam: "B", matchNumber: "周二006",
            date: date, score: nil, outcomes: []
        )
        let match007 = SportsLotteryMatch(
            id: 7, league: .premierLeague, leagueName: "英格兰超级联赛",
            homeTeam: "C", awayTeam: "D", matchNumber: "周二007",
            date: date, score: nil, outcomes: []
        )
        let snapshot = SportsLotterySnapshot(fetchedAt: Date(), matches: [match006, match007])
        #expect(snapshot.matchesByLeague[.premierLeague]?.map(\.matchNumber) == ["周二007", "周二006"])
    }

    @Test func scheduledScoreRemainsVisibleButDoesNotCountAsFinal() {
        let match = SportsLotteryMatch(
            id: 3, league: .premierLeague, leagueName: "英格兰超级联赛",
            homeTeam: "A", awayTeam: "B", matchNumber: "周一003",
            date: Date(), score: " -1:-1 ", outcomes: []
        )
        #expect(match.displayScore == "-1:-1")
        #expect(!match.hasFinalScore)
        #expect(!match.hasCompleteResult)
        #expect(match.officialResultURL?.absoluteString == "https://www.sporttery.cn/jc/zqdz/index.html?showType=2&mid=3")

        let alternatePlaceholder = SportsLotteryMatch(
            id: 4, league: .premierLeague, leagueName: "英格兰超级联赛",
            homeTeam: "A", awayTeam: "B", matchNumber: "周一004",
            date: Date(), score: "-1 -1", outcomes: []
        )
        #expect(alternatePlaceholder.displayScore == "-1 -1")
        #expect(!alternatePlaceholder.hasFinalScore)
    }

    @Test func automaticRefreshUsesTenAndTwentyTwoShanghaiTimeSlots() throws {
        let nine = try Self.shanghaiDate("2026-08-13 09:00:00")
        let ten = try Self.shanghaiDate("2026-08-13 10:00:00")
        let fifteen = try Self.shanghaiDate("2026-08-13 15:00:00")
        let twentyTwo = try Self.shanghaiDate("2026-08-13 22:00:00")
        let twentyThree = try Self.shanghaiDate("2026-08-13 23:00:00")

        #expect(Self.shanghaiString(SportsLotteryService.automaticRefreshSlot(for: nine)) == "2026-08-12 22:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.automaticRefreshSlot(for: ten)) == "2026-08-13 10:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.automaticRefreshSlot(for: fifteen)) == "2026-08-13 10:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.automaticRefreshSlot(for: twentyTwo)) == "2026-08-13 22:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.automaticRefreshSlot(for: twentyThree)) == "2026-08-13 22:00:00")

        #expect(Self.shanghaiString(SportsLotteryService.nextAutomaticRefreshDate(after: nine)) == "2026-08-13 10:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.nextAutomaticRefreshDate(after: ten)) == "2026-08-13 22:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.nextAutomaticRefreshDate(after: fifteen)) == "2026-08-13 22:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.nextAutomaticRefreshDate(after: twentyTwo)) == "2026-08-14 10:00:00")
        #expect(Self.shanghaiString(SportsLotteryService.nextAutomaticRefreshDate(after: twentyThree)) == "2026-08-14 10:00:00")
    }

    @Test func serviceFetchesResultsByLeagueIDAndEnrichesMatch() async throws {
        let client = SportsLotteryHTTPClientStub { request in
            let url = try #require(request.url)
            let body: String
            if url.path.contains("getUniformMatchResultV1") {
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(components.queryItems?.first(where: { $0.name == "leagueId" })?.value == "69")
                body = """
                {"errorCode":"0","value":{"pages":1,"leagueList":[{"leagueAbbName":"欧冠","leagueId":69,"leagueAllName":"欧洲冠军联赛"}],"matchResult":[{"awayTeam":"布斯巴达","homeTeam":"里昂","leagueId":69,"leagueName":"欧洲冠军联赛","leagueNameAbbr":"欧冠","matchDate":"2026-08-12","matchId":2040817,"matchNumStr":"周二009","sectionsNo999":"3:0"}]}}
                """
            } else if url.path.contains("getMatchHeadV1") {
                body = """
                {"errorCode":"0","value":{"tournamentCnName":"欧洲冠军联赛","homeTeamShortName":"里昂","awayTeamShortName":"布斯巴达","matchNum":"周二009","matchDateTime":"2026-08-12 21:00:00","fullCourtGoal":"3:0"}}
                """
            } else {
                body = """
                {"errorCode":"0","value":{"matchResultList":[{"code":"HAD","combinationDesc":"胜","odds":"1.27"}]}}
                """
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data(body.utf8), response)
        }
        let cacheURL = Self.temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let service = SportsLotteryService(httpClient: client, cacheFileURL: cacheURL)

        let snapshot = try await service.fetchSnapshot(leagues: [.championsLeague], forceRefresh: true)
        let match = try #require(snapshot.matches.first)
        #expect(snapshot.matches.count == 1)
        #expect(match.league == .championsLeague)
        #expect(match.displayScore == "3:0")
        #expect(match.outcome(for: .had)?.value == "胜")
        #expect(match.outcome(for: .had)?.odds == "1.27")

        let requestedURLs = await client.requestedURLs()
        #expect(requestedURLs.contains { $0.path.contains("getUniformMatchResultV1") })
        #expect(requestedURLs.contains { $0.path.contains("getMatchHeadV1") })
        #expect(requestedURLs.contains { $0.path.contains("getFixedBonusV1") })
    }

    @Test func servicePersistsSnapshotAndSkipsDuplicateAutomaticRefresh() async throws {
        let cacheURL = Self.temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let initialClient = SportsLotteryHTTPClientStub { request in
            let url = try #require(request.url)
            let body: String
            if url.path.contains("getUniformMatchResultV1") {
                body = """
                {"errorCode":"0","value":{"pages":1,"leagueList":[],"matchResult":[{"awayTeam":"布斯巴达","homeTeam":"里昂","leagueId":69,"leagueName":"欧洲冠军联赛","leagueNameAbbr":"欧冠","matchDate":"2026-08-12","matchId":2040817,"matchNumStr":"周二009","sectionsNo999":"3:0"}]}}
                """
            } else if url.path.contains("getMatchHeadV1") {
                body = """
                {"errorCode":"0","value":{"tournamentCnName":"欧洲冠军联赛","homeTeamShortName":"里昂","awayTeamShortName":"布斯巴达","matchNum":"周二009","matchDateTime":"2026-08-12 21:00:00","fullCourtGoal":"3:0"}}
                """
            } else {
                body = """
                {"errorCode":"0","value":{"matchResultList":[{"code":"HAD","combinationDesc":"胜","odds":"1.27"},{"code":"HHAD","combinationDesc":"让胜","odds":"1.50"},{"code":"HAFU","combinationDesc":"胜胜","odds":"2.30"},{"code":"TTG","combinationDesc":"3","odds":"3.10"},{"code":"CRS","combinationDesc":"3:0","odds":"8.00"}]}}
                """
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(body.utf8), response)
        }
        let firstService = SportsLotteryService(
            httpClient: initialClient,
            cacheFileURL: cacheURL
        )

        let fetched = try await firstService.fetchSnapshot(
            leagues: [.championsLeague],
            forceRefresh: true
        )
        #expect(fetched.matches.count == 1)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        let cachedOnlyClient = SportsLotteryHTTPClientStub { _ in
            throw URLError(.resourceUnavailable)
        }
        let secondService = SportsLotteryService(
            httpClient: cachedOnlyClient,
            cacheFileURL: cacheURL
        )
        let restored = try #require(await secondService.cachedSnapshot(leagues: [.championsLeague]))
        #expect(restored.matches == fetched.matches)

        let sameSlot = try await secondService.fetchSnapshot(
            leagues: [.championsLeague],
            forceRefresh: false
        )
        #expect(sameSlot.matches == fetched.matches)
        #expect(await cachedOnlyClient.requestedURLs().isEmpty)
    }

    @Test func serviceFindsLeagueByOfficialNameOrAbbreviation() async throws {
        let client = SportsLotteryHTTPClientStub { request in
            let url = try #require(request.url)
            let body = """
            {"errorCode":"0","value":{"pages":1,"leagueList":[{"leagueAbbName":"欧冠","leagueId":69,"leagueAllName":"欧洲冠军联赛"}],"matchResult":[]}}
            """
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(body.utf8), response)
        }
        let cacheURL = Self.temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let service = SportsLotteryService(httpClient: client, cacheFileURL: cacheURL)

        #expect(try await service.findLeague(named: "欧冠") == .championsLeague)
        #expect(try await service.findLeague(named: "欧洲冠军联赛") == .championsLeague)
        #expect(try await service.findLeague(named: "不存在的赛事") == nil)
    }

    private static func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sports-lottery-\(UUID().uuidString).json")
    }

    private static func shanghaiDate(_ value: String) throws -> Date {
        try #require(shanghaiFormatter.date(from: value))
    }

    private static func shanghaiString(_ date: Date) -> String {
        shanghaiFormatter.string(from: date)
    }

    private static let shanghaiFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private actor SportsLotteryHTTPClientStub: SportsLotteryHTTPClient {
    private let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)
    private var requests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try handler(request)
    }

    func requestedURLs() -> [URL] {
        requests.compactMap(\.url)
    }
}
#endif
