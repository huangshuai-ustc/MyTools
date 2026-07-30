import Foundation

enum StockMarket: String, Codable, CaseIterable, Identifiable, Sendable {
    case aShare
    case hongKong
    case unitedStates

    var id: Self { self }

    var title: String {
        switch self {
        case .aShare: return "A 股"
        case .hongKong: return "港股"
        case .unitedStates: return "美股"
        }
    }

    var currencyCode: String {
        switch self {
        case .aShare: return "CNY"
        case .hongKong: return "HKD"
        case .unitedStates: return "USD"
        }
    }

    static var displayOrder: [Self] {
        ordered([.unitedStates, .aShare, .hongKong])
    }

    static var topLevelOrder: [Self] {
        allCases
    }

    private static func ordered(_ preferred: [Self]) -> [Self] {
        let preferredSet = Set(preferred)
        let remaining = allCases
            .filter { !preferredSet.contains($0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return preferred + remaining
    }
}

enum StockMarketTradingCalendar {
    static func isOpen(_ market: StockMarket, at date: Date = Date()) -> Bool {
        switch market {
        case .aShare:
            return isOpen(
                date,
                timeZone: "Asia/Shanghai",
                sessions: [(570, 690), (780, 900)],
                holiday: isAShareHoliday
            )
        case .hongKong:
            return isOpen(
                date,
                timeZone: "Asia/Hong_Kong",
                sessions: [(570, 720), (780, 960)],
                holiday: isHongKongHoliday
            )
        case .unitedStates:
            return isOpen(
                date,
                timeZone: "America/New_York",
                sessions: [(570, 960)],
                holiday: isUnitedStatesHoliday
            )
        }
    }

    private static func isOpen(
        _ date: Date,
        timeZone identifier: String,
        sessions: [(start: Int, end: Int)],
        holiday: (Date, Calendar) -> Bool
    ) -> Bool {
        let calendar = calendar(timeZone: identifier)
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              (2...6).contains(weekday),
              let hour = components.hour,
              let minute = components.minute else {
            return false
        }
        guard !holiday(date, calendar) else { return false }
        let localMinutes = hour * 60 + minute
        return sessions.contains { localMinutes >= $0.start && localMinutes < $0.end }
    }

    private static func calendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        return calendar
    }

    private static func isAShareHoliday(_ date: Date, _ calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return true }

        if month == 1, day == 1 {
            return true
        }
        if month == 5, (1...5).contains(day) {
            return true
        }
        if month == 10, (1...7).contains(day) {
            return true
        }
        if day == qingmingDay(in: year), month == 4 {
            return true
        }

        let lunar = lunarComponents(for: date, timeZone: calendar.timeZone)
        if lunar.month == 12, lunar.day >= 29 {
            return true
        }
        if lunar.month == 1, (1...7).contains(lunar.day) {
            return true
        }
        if lunar.month == 5, lunar.day == 5 {
            return true
        }
        if lunar.month == 8, lunar.day == 15 {
            return true
        }
        return false
    }

    private static func isHongKongHoliday(_ date: Date, _ calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return true }

        for fixedDate in [(1, 1), (5, 1), (7, 1), (10, 1), (12, 25), (12, 26)] {
            if isObservedFixedHoliday(
                date,
                month: fixedDate.0,
                day: fixedDate.1,
                calendar: calendar
            ) {
                return true
            }
        }
        if day == qingmingDay(in: year), month == 4 {
            return true
        }
        let lunar = lunarComponents(for: date, timeZone: calendar.timeZone)
        if lunar.month == 1, (1...3).contains(lunar.day) {
            return true
        }
        if lunar.month == 4, lunar.day == 8 {
            return true
        }
        if lunar.month == 5, lunar.day == 5 {
            return true
        }
        if lunar.month == 8, lunar.day == 16 {
            return true
        }
        if lunar.month == 9, lunar.day == 9 {
            return true
        }

        guard let easter = easterSunday(year: year, calendar: calendar) else { return false }
        let goodFriday = calendar.date(byAdding: .day, value: -2, to: easter)
        let easterMonday = calendar.date(byAdding: .day, value: 1, to: easter)
        return [goodFriday, easterMonday].contains {
            guard let holiday = $0 else { return false }
            return sameDay(date, holiday, calendar: calendar)
        }
    }

    private static func isUnitedStatesHoliday(_ date: Date, _ calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year else { return true }

        if isObservedFixedHoliday(date, month: 1, day: 1, calendar: calendar)
            || isObservedFixedHoliday(date, month: 6, day: 19, calendar: calendar)
            || isObservedFixedHoliday(date, month: 7, day: 4, calendar: calendar)
            || isObservedFixedHoliday(date, month: 12, day: 25, calendar: calendar) {
            return true
        }
        if isNthWeekday(date, month: 1, weekday: 2, occurrence: 3, calendar: calendar)
            || isNthWeekday(date, month: 2, weekday: 2, occurrence: 3, calendar: calendar)
            || isNthWeekday(date, month: 9, weekday: 2, occurrence: 1, calendar: calendar)
            || isLastWeekday(date, month: 5, weekday: 2, calendar: calendar)
            || isNthWeekday(date, month: 11, weekday: 5, occurrence: 4, calendar: calendar) {
            return true
        }

        guard let easter = easterSunday(year: year, calendar: calendar),
              let goodFriday = calendar.date(byAdding: .day, value: -2, to: easter) else {
            return false
        }
        return sameDay(date, goodFriday, calendar: calendar)
    }

    private static func lunarComponents(
        for date: Date,
        timeZone: TimeZone
    ) -> (month: Int, day: Int) {
        var calendar = Calendar(identifier: .chinese)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.month, .day], from: date)
        return (components.month ?? 0, components.day ?? 0)
    }

    private static func qingmingDay(in year: Int) -> Int {
        let shortYear = year % 100
        return Int(floor(Double(shortYear) * 0.2422 + 4.81)) - shortYear / 4
    }

    private static func isObservedFixedHoliday(
        _ date: Date,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Bool {
        let year = calendar.component(.year, from: date)
        for candidateYear in (year - 1)...(year + 1) {
            guard let holiday = makeDate(
                year: candidateYear,
                month: month,
                day: day,
                calendar: calendar
            ) else { continue }
            let weekday = calendar.component(.weekday, from: holiday)
            let offset: Int
            switch weekday {
            case 7: offset = -1
            case 1: offset = 1
            default: offset = 0
            }
            guard let observed = calendar.date(byAdding: .day, value: offset, to: holiday) else { continue }
            if sameDay(date, observed, calendar: calendar) { return true }
        }
        return false
    }

    private static func isNthWeekday(
        _ date: Date,
        month: Int,
        weekday: Int,
        occurrence: Int,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.month == month,
              let year = components.year,
              let first = makeDate(year: year, month: month, day: 1, calendar: calendar) else {
            return false
        }
        let firstWeekday = calendar.component(.weekday, from: first)
        let offset = (weekday - firstWeekday + 7) % 7
        let targetDay = 1 + offset + (occurrence - 1) * 7
        return components.day == targetDay
    }

    private static func isLastWeekday(
        _ date: Date,
        month: Int,
        weekday: Int,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.month == month,
              let year = components.year,
              let range = calendar.range(of: .day, in: .month, for: date),
              let last = makeDate(year: year, month: month, day: range.count, calendar: calendar) else {
            return false
        }
        return components.day == range.count && calendar.component(.weekday, from: last) == weekday
    }

    private static func easterSunday(year: Int, calendar: Calendar) -> Date? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return makeDate(year: year, month: month, day: day, calendar: calendar)
    }

    private static func makeDate(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Date? {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }

    private static func sameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

enum StockRiseFallColorScheme: String, CaseIterable, Identifiable {
    case redRiseGreenFall
    case greenRiseRedFall

    var id: Self { self }

    var title: String {
        switch self {
        case .redRiseGreenFall: return "红涨绿跌"
        case .greenRiseRedFall: return "绿涨红跌"
        }
    }

    static func defaultScheme(for market: StockMarket) -> Self {
        switch market {
        case .aShare, .hongKong: return .redRiseGreenFall
        case .unitedStates: return .greenRiseRedFall
        }
    }
}

enum StockTransactionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case buy
    case sell

    var id: Self { self }

    var title: String {
        switch self {
        case .buy: return "买入"
        case .sell: return "卖出"
        }
    }

    var shareMultiplier: Decimal {
        self == .buy ? 1 : -1
    }
}

struct StockTransaction: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var type: StockTransactionType = .buy
    var tradedAt = Date()
    var quantity: Decimal = 0
    var unitPrice: Decimal = 0
    var fees: Decimal = 0

    var signedShares: Decimal {
        quantity * type.shareMultiplier
    }

    var grossAmount: Decimal {
        quantity * unitPrice
    }

    var cashFlow: Decimal {
        switch type {
        case .buy:
            return grossAmount + fees
        case .sell:
            return -(grossAmount - fees)
        }
    }
}

struct StockDividend: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var receivedAt = Date()
    var quantity: Decimal = 0
    var dividendPerShare: Decimal = 0
    var grossAmount: Decimal = 0
    var withholdingTax: Decimal = 0
    var fees: Decimal = 0
    var note = ""

    var hasPerShareBreakdown: Bool {
        quantity > 0 && dividendPerShare > 0
    }

    var totalDeductions: Decimal {
        withholdingTax + fees
    }

    var netAmount: Decimal {
        grossAmount - totalDeductions
    }
}

struct StockHolding: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var market: StockMarket = .aShare
    var symbol = ""
    var name = ""
    var transactions: [StockTransaction] = []
    var dividends: [StockDividend] = []
    var latestPrice: Decimal?
    var previousClose: Decimal?
    var changePercent: Decimal?
    var quoteName = ""
    var lastQuoteAt: Date?

    var displayName: String {
        let preferredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredName.isEmpty { return preferredName }
        let syncedName = quoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return syncedName.isEmpty ? symbol : syncedName
    }

    var currentShares: Decimal {
        transactions.reduce(Decimal.zero) { $0 + $1.signedShares }
    }

    var firstPurchasedAt: Date? {
        transactions.lazy
            .filter { $0.type == .buy }
            .map(\.tradedAt)
            .min()
    }

    var hasPurchaseRecord: Bool {
        transactions.contains { $0.type == .buy }
    }

    var totalBuyCost: Decimal {
        transactions.lazy
            .filter { $0.type == .buy }
            .reduce(Decimal.zero) { $0 + $1.grossAmount + $1.fees }
    }

    var netDividendIncome: Decimal {
        dividends.reduce(Decimal.zero) { $0 + $1.netAmount }
    }

    /// The cost of the shares that remain held, calculated with a moving
    /// weighted-average cost after each buy or sell.
    var holdingCost: Decimal {
        transactionPerformance.holdingCost
    }

    var averageHoldingCost: Decimal? {
        guard currentShares > 0 else { return nil }
        return holdingCost / currentShares
    }

    /// Realized trading profit plus net dividends already received. Later buys
    /// affect only the current holding cost and do not change this value.
    var realizedProfitLoss: Decimal {
        transactionPerformance.realizedProfitLoss + netDividendIncome
    }

    var marketValue: Decimal? {
        guard currentShares > 0, let latestPrice else {
            return currentShares == 0 ? 0 : nil
        }
        return currentShares * latestPrice
    }

    /// Profit or loss for shares that are still held right now.
    var holdingProfitLoss: Decimal? {
        guard let marketValue else { return nil }
        return marketValue - holdingCost
    }

    /// Lifetime result: current holding profit plus realized profit.
    var totalProfitLoss: Decimal? {
        guard let holdingProfitLoss else { return nil }
        return holdingProfitLoss + realizedProfitLoss
    }

    func canApply(_ transaction: StockTransaction) -> Bool {
        guard transaction.quantity > 0,
              transaction.unitPrice > 0,
              transaction.fees >= 0 else { return false }
        var updatedTransactions = transactions.filter { $0.id != transaction.id }
        updatedTransactions.append(transaction)
        return Self.hasValidTransactionOrder(updatedTransactions)
    }

    /// A sale must have an earlier purchase available at its trade date.
    /// This prevents out-of-order historical entries from being silently ignored
    /// by the moving-average performance calculation.
    var hasValidTransactionOrder: Bool {
        Self.hasValidTransactionOrder(transactions)
    }

    private static func hasValidTransactionOrder(_ transactions: [StockTransaction]) -> Bool {
        var shares = Decimal.zero
        for transaction in orderedTransactions(transactions) {
            guard transaction.quantity > 0,
                  transaction.unitPrice > 0,
                  transaction.fees >= 0 else { return false }
            shares += transaction.signedShares
            if shares < 0 { return false }
        }
        return true
    }

    private static func orderedTransactions(_ transactions: [StockTransaction]) -> [StockTransaction] {
        transactions.sorted {
            if $0.tradedAt == $1.tradedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.tradedAt < $1.tradedAt
        }
    }

    private var transactionPerformance: (holdingCost: Decimal, realizedProfitLoss: Decimal) {
        var shares = Decimal.zero
        var cost = Decimal.zero
        var realized = Decimal.zero

        for transaction in Self.orderedTransactions(transactions) where transaction.quantity > 0 {
            switch transaction.type {
            case .buy:
                shares += transaction.quantity
                cost += transaction.grossAmount + transaction.fees
            case .sell:
                guard shares > 0 else { continue }
                let soldShares = min(transaction.quantity, shares)
                let averageCost = cost / shares
                let soldCost = averageCost * soldShares
                let feeRatio = soldShares / transaction.quantity
                let soldProceeds = soldShares * transaction.unitPrice - transaction.fees * feeRatio
                realized += soldProceeds - soldCost
                shares -= soldShares
                cost -= soldCost
                if shares == 0 { cost = 0 }
            }
        }

        return (cost, realized)
    }

    static func normalizedSymbol(_ symbol: String, market: StockMarket) -> String {
        var normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")

        guard market == .aShare else {
            if market == .hongKong {
                for prefix in ["HK"] where normalized.hasPrefix(prefix) {
                    normalized.removeFirst(prefix.count)
                }
                for suffix in [".HK"] where normalized.hasSuffix(suffix) {
                    normalized.removeLast(suffix.count)
                }
                if normalized.allSatisfy(\.isNumber), normalized.count < 5 {
                    return String(repeating: "0", count: 5 - normalized.count) + normalized
                }
            }
            return normalized
        }
        for prefix in ["SH", "SZ", "BJ"] where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
        }
        for suffix in [".SH", ".SS", ".SZ", ".BJ"] where normalized.hasSuffix(suffix) {
            normalized.removeLast(suffix.count)
        }
        return normalized
    }
}

struct StockPortfolioSummary {
    let market: StockMarket
    let stockCount: Int
    let openPositionCount: Int
    let holdingCost: Decimal
    let netDividendIncome: Decimal
    let realizedProfitLoss: Decimal
    let knownMarketValue: Decimal
    let profitLoss: Decimal?
    let hasMissingQuotes: Bool

    var totalProfitLoss: Decimal? {
        profitLoss.map { $0 + realizedProfitLoss }
    }

    init(market: StockMarket, stocks: [StockHolding]) {
        self.market = market
        let marketStocks = stocks.filter { $0.market == market }
        stockCount = marketStocks.count
        openPositionCount = marketStocks.lazy.filter { $0.currentShares > 0 }.count
        holdingCost = marketStocks.reduce(Decimal.zero) { $0 + $1.holdingCost }
        netDividendIncome = marketStocks.reduce(Decimal.zero) { $0 + $1.netDividendIncome }
        realizedProfitLoss = marketStocks.reduce(Decimal.zero) { $0 + $1.realizedProfitLoss }
        knownMarketValue = marketStocks.reduce(Decimal.zero) { result, stock in
            result + (stock.marketValue ?? 0)
        }
        hasMissingQuotes = marketStocks.contains { $0.currentShares > 0 && $0.latestPrice == nil }
        profitLoss = hasMissingQuotes ? nil : knownMarketValue - holdingCost
    }
}

struct StockAllocationSnapshot {
    private let holdingShares: [UUID: Decimal]
    private let marketShares: [StockMarket: Decimal]
    let isComplete: Bool

    init(stocks: [StockHolding], marketValueMultipliers: [StockMarket: Decimal]) {
        var valuesByHolding: [UUID: Decimal] = [:]
        var valuesByMarket = Dictionary(
            uniqueKeysWithValues: StockMarket.allCases.map { ($0, Decimal.zero) }
        )
        var total = Decimal.zero
        var complete = true

        for stock in stocks {
            guard let marketValue = stock.marketValue else {
                complete = false
                break
            }
            let convertedValue: Decimal
            if marketValue == 0 {
                convertedValue = 0
            } else if let multiplier = marketValueMultipliers[stock.market] {
                convertedValue = marketValue * multiplier
            } else {
                complete = false
                break
            }
            valuesByHolding[stock.id] = convertedValue
            valuesByMarket[stock.market, default: 0] += convertedValue
            total += convertedValue
        }

        guard complete else {
            holdingShares = [:]
            marketShares = [:]
            isComplete = false
            return
        }

        if total > 0 {
            holdingShares = valuesByHolding.mapValues { $0 / total }
            marketShares = valuesByMarket.mapValues { $0 / total }
        } else {
            holdingShares = valuesByHolding.mapValues { _ in 0 }
            marketShares = valuesByMarket.mapValues { _ in 0 }
        }
        isComplete = true
    }

    func holdingShare(for stockID: UUID) -> Decimal? {
        guard isComplete else { return nil }
        return holdingShares[stockID] ?? 0
    }

    func marketShare(for market: StockMarket) -> Decimal? {
        guard isComplete else { return nil }
        return marketShares[market] ?? 0
    }
}

enum StockValueFormatter {
    static func exchangeRate(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "--"
    }

    static func money(_ value: Decimal, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "--"
    }

    static func moneyMagnitude(_ value: Decimal, currencyCode: String) -> String {
        money(value < 0 ? -value : value, currencyCode: currencyCode)
    }

    static func price(_ value: Decimal, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "--"
    }

    static func quantity(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    static func percent(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = "+"
        return formatter.string(from: value as NSDecimalNumber) ?? "0.00%"
    }

    static func allocationPercent(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "0.00%"
    }
}
