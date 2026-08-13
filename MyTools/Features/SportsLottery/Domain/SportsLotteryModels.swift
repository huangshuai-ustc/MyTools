#if MYTOOLS_FEATURE_SPORTS_LOTTERY
import Foundation

/// A league that the user has selected for result tracking.
struct SportsLotteryLeague: Codable, Equatable, Hashable, Identifiable, Sendable {
    let leagueID: Int
    let title: String
    let officialName: String

    var id: Int { leagueID }

    init(leagueID: Int, title: String, officialName: String) {
        self.leagueID = leagueID
        self.title = title
        self.officialName = officialName
    }

    var officialNames: Set<String> {
        [title, officialName]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.leagueID == rhs.leagueID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(leagueID)
    }

    static let premierLeague = Self(leagueID: 25, title: "英超", officialName: "英格兰超级联赛")
    static let laLiga = Self(leagueID: 62, title: "西甲", officialName: "西班牙甲级联赛")
    static let serieA = Self(leagueID: 40, title: "意甲", officialName: "意大利甲级联赛")
    static let bundesliga = Self(leagueID: 37, title: "德甲", officialName: "德国甲级联赛")
    static let ligue1 = Self(leagueID: 32, title: "法甲", officialName: "法国甲级联赛")
    static let championsLeague = Self(leagueID: 69, title: "欧冠", officialName: "欧洲冠军联赛")

    static let allCases: [Self] = [
        .premierLeague, .laLiga, .serieA, .bundesliga, .ligue1, .championsLeague
    ]

    static func match(for name: String) -> Self? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.officialNames.contains(normalized) }
    }
}

enum SportsLotteryLeaguePreferences {
    static let key = "sports-lottery-leagues-v2"

    static func load(from defaults: UserDefaults = .standard) -> [SportsLotteryLeague] {
        guard let data = defaults.data(forKey: key),
              let leagues = try? JSONDecoder().decode([SportsLotteryLeague].self, from: data) else {
            return SportsLotteryLeague.allCases
        }
        return unique(leagues)
    }

    static func save(_ leagues: [SportsLotteryLeague], to defaults: UserDefaults = .standard) {
        let value = unique(leagues)
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func unique(_ leagues: [SportsLotteryLeague]) -> [SportsLotteryLeague] {
        var seen = Set<Int>()
        return leagues.filter { seen.insert($0.leagueID).inserted }
    }
}

enum SportsLotteryOutcomeCode: String, CaseIterable, Codable, Identifiable, Sendable {
    case had = "HAD"
    case hhad = "HHAD"
    case hafu = "HAFU"
    case ttg = "TTG"
    case crs = "CRS"

    var id: Self { self }

    var title: String {
        switch self {
        case .had: return "胜平负"
        case .hhad: return "让球"
        case .hafu: return "半全场"
        case .ttg: return "总进球"
        case .crs: return "比分"
        }
    }
}

struct SportsLotteryOutcome: Identifiable, Codable, Equatable, Sendable {
    let code: SportsLotteryOutcomeCode
    let value: String
    let odds: String?

    var id: SportsLotteryOutcomeCode { code }
}

struct SportsLotteryMatch: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let league: SportsLotteryLeague
    let leagueName: String
    let homeTeam: String
    let awayTeam: String
    let matchNumber: String
    let date: Date
    let score: String?
    let outcomes: [SportsLotteryOutcome]

    func outcome(for code: SportsLotteryOutcomeCode) -> SportsLotteryOutcome? {
        outcomes.first { $0.code == code }
    }

    /// The official score field can be `-1:-1` or `-1 -1` before kickoff. It
    /// still identifies a scheduled match and should remain visible in the row.
    var displayScore: String? {
        guard let score = score?.trimmingCharacters(in: .whitespacesAndNewlines),
              !score.isEmpty else {
            return nil
        }
        return score
    }

    /// A real final score is required before a match can stop being refreshed.
    var hasFinalScore: Bool {
        guard let displayScore else { return false }
        return displayScore != "-1:-1"
            && displayScore != "-1 -1"
    }

    var hasCompleteResult: Bool {
        hasFinalScore
            && Set(outcomes.map(\.code)) == Set(SportsLotteryOutcomeCode.allCases)
    }

    /// Official result page. The page remains useful even when the match has
    /// not started yet, and the match ID lets the site select this game.
    var officialResultURL: URL? {
        var components = URLComponents(string: "https://www.sporttery.cn/jc/zqdz/index.html")
        components?.queryItems = [
            URLQueryItem(name: "showType", value: "2"),
            URLQueryItem(name: "mid", value: String(id))
        ]
        return components?.url
    }

    /// The numeric suffix is the official match sequence, e.g. 周二007 -> 7.
    var matchNumberSortValue: Int? {
        let digits = matchNumber.reversed().prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(String(digits.reversed()))
    }

    static func isNewer(_ lhs: Self, than rhs: Self) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        switch (lhs.matchNumberSortValue, rhs.matchNumberSortValue) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id > rhs.id
        }
    }
}

struct SportsLotterySnapshot: Equatable, Sendable {
    let fetchedAt: Date
    let matches: [SportsLotteryMatch]

    var matchesByLeague: [SportsLotteryLeague: [SportsLotteryMatch]] {
        Dictionary(grouping: matches, by: \.league).mapValues {
            $0.sorted(by: SportsLotteryMatch.isNewer)
        }
    }
}
#endif
