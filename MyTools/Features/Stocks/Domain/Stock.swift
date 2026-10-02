#if MYTOOLS_FEATURE_STOCKS
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

    /// Only US providers currently expose continuous extended-hours bars that
    /// can be rendered as chart sessions. A-share and HK auction phases are not
    /// equivalent to a continuous pre-market/post-market price series.
    var supportsExtendedHoursChart: Bool {
        self == .unitedStates
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

enum StockRiseFallColorScheme: String, CaseIterable, Codable, Identifiable, Sendable {
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

enum StockListState: Sendable {
    case holding
    case watchlist
    case archived
}

struct StockTransaction: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var type: StockTransactionType = .buy
    var tradedAt = Date()
    var dayOrder: Int?
    /// The user-confirmed execution instant. `nil` means that only the trading
    /// day is known and intraday consumers must use the shared inference rule.
    /// Keeping this separate from `tradedAt` preserves the latter's historical
    /// date-only semantics and makes the additive field safe for older data.
    var executedAt: Date?
    var quantity: Decimal = 0
    var unitPrice: Decimal = 0
    var fees: Decimal = 0

    /// Converts an absolute instant into the market's business date while
    /// keeping the stored value compatible with the app's existing date-only
    /// transaction model. For example, 2026-09-29 01:00 in Shanghai is still
    /// 2026-09-28 in New York, so a newly-created US transaction defaults to
    /// September 28 in the local date picker.
    static func defaultTradingDate(
        at instant: Date = Date(),
        market: StockMarket,
        displayCalendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let marketCalendar = StockChartSeriesProcessor.marketCalendar(market)
        let components = marketCalendar.dateComponents([.year, .month, .day], from: instant)
        let calendar = displayCalendar
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12
        )) ?? normalizedDate(instant)
    }

    static func normalizedDate(_ date: Date) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .hour, value: 12, to: startOfDay) ?? startOfDay
    }

    static func normalizedExecutionInstant(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    /// Creates an absolute execution instant from the business day shown by
    /// the date picker and a wall-clock time shown in the device calendar.
    /// The resulting instant is interpreted in the selected market timezone.
    static func executionInstant(
        tradingDate: Date,
        displayedTime: Date,
        market: StockMarket,
        displayCalendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        let day = displayCalendar.dateComponents([.year, .month, .day], from: tradingDate)
        let time = displayCalendar.dateComponents([.hour, .minute], from: displayedTime)
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return StockChartSeriesProcessor.marketCalendar(market).date(from: components)
            .map(normalizedExecutionInstant)
    }

    /// Converts an absolute market instant into a device-calendar carrier used
    /// solely by a time-only DatePicker, so it displays the market wall clock.
    static func displayedExecutionTime(
        for instant: Date,
        market: StockMarket,
        displayCalendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let marketCalendar = StockChartSeriesProcessor.marketCalendar(market)
        let time = marketCalendar.dateComponents([.hour, .minute], from: instant)
        let reference = displayCalendar.dateComponents([.year, .month, .day], from: Date())
        return displayCalendar.date(from: DateComponents(
            calendar: displayCalendar,
            timeZone: displayCalendar.timeZone,
            year: reference.year,
            month: reference.month,
            day: reference.day,
            hour: time.hour,
            minute: time.minute
        )) ?? instant
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.autoupdatingCurrent.isDate(lhs, inSameDayAs: rhs)
    }

    var signedShares: Decimal {
        quantity * type.shareMultiplier
    }

    var grossAmount: Decimal {
        quantity * unitPrice
    }

    /// Cash paid for a buy, including fees capitalized into the position cost.
    var buyTotalCost: Decimal {
        grossAmount + fees
    }

    /// Cash received from a sale after its transaction fees.
    var sellNetProceeds: Decimal {
        grossAmount - fees
    }

    var cashFlow: Decimal {
        switch type {
        case .buy:
            return buyTotalCost
        case .sell:
            return -sellNetProceeds
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

    /// Dividend dates are day-level business dates. A payment scheduled for
    /// today is effective for the whole local calendar day, regardless of the
    /// time component retained by DatePicker or an older payload.
    func isReceived(
        asOf date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        calendar.startOfDay(for: receivedAt) <= calendar.startOfDay(for: date)
    }
}

/// Moving-average replay shared by current valuation and historical cost curves.
/// Decimal intermediate values are never rounded to display precision.
struct StockMovingAverageCostLedger: Sendable {
    private(set) var shares: Decimal = 0
    private(set) var cost: Decimal = 0
    private(set) var realized: Decimal = 0

    mutating func apply(_ transaction: StockTransaction) {
        guard transaction.quantity > 0 else { return }
        switch transaction.type {
        case .buy:
            let amount = transaction.grossAmount + transaction.fees
            shares += transaction.quantity
            cost += amount
        case .sell:
            let sold = min(transaction.quantity, shares)
            guard sold > 0 else { return }
            // Full liquidation consumes the exact remaining cost, including
            // any sub-cent Decimal division residue from partial sales.
            let removedCost = sold == shares ? cost : cost / shares * sold
            shares -= sold
            cost -= removedCost
            realized += sold * transaction.unitPrice - transaction.fees * sold / transaction.quantity - removedCost
            if shares == 0 {
                cost = 0
            }
        }
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
    /// User intent for zero-position stocks. A non-nil value hides the stock
    /// from the default watchlist without removing its transaction history.
    var archivedAt: Date?

    var displayName: String {
        let preferredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredName.isEmpty { return preferredName }
        let syncedName = quoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return syncedName.isEmpty ? symbol : syncedName
    }

    var currentShares: Decimal {
        sharePosition().shares
    }

    var hasHistoricalActivity: Bool {
        !transactions.isEmpty || !dividends.isEmpty
    }

    var listState: StockListState {
        if currentShares > 0 { return .holding }
        return archivedAt == nil ? .watchlist : .archived
    }

    var isArchived: Bool {
        listState == .archived
    }

    var firstPurchasedAt: Date? {
        sharePosition().firstPurchasedAt
    }

    var hasPurchaseRecord: Bool {
        sharePosition().hasPurchaseRecord
    }

    var hasConfiguredSymbol: Bool {
        !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var totalBuyCost: Decimal {
        sharePosition().totalBuyCost
    }

    var netDividendIncome: Decimal {
        netDividendIncome(asOf: Date())
    }

    func netDividendIncome(
        asOf date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Decimal {
        dividends.lazy
            .filter { $0.isReceived(asOf: date, calendar: calendar) }
            .reduce(Decimal.zero) { $0 + $1.netAmount }
    }

    /// Remaining moving-average cost, including allocated buying fees.
    var holdingCost: Decimal {
        performance().holdingCost
    }

    var averageHoldingCost: Decimal? {
        performance().averageHoldingCost
    }

    /// Realized trading profit plus net dividends already received. Later buys
    /// affect only the current holding cost and do not change this value.
    var realizedProfitLoss: Decimal {
        performance().realizedProfitLoss
    }

    var marketValue: Decimal? {
        metrics().marketValue
    }

    /// Profit or loss for shares that are still held right now.
    var holdingProfitLoss: Decimal? {
        metrics().holdingProfitLoss
    }

    var holdingProfitRate: Decimal? {
        metrics().holdingProfitRate
    }

    /// Profit or loss generated by today's regular-session move for the
    /// currently held shares. Extended-hours movement is presented separately.
    var todayProfitLoss: Decimal? {
        metrics().todayProfitLoss
    }

    /// Lifetime result: current holding profit plus realized profit.
    var totalProfitLoss: Decimal? {
        metrics().totalProfitLoss
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

    var transactionsChronologically: [StockTransaction] {
        Self.orderedTransactions(transactions)
    }

    var transactionsNewestFirst: [StockTransaction] {
        Array(transactionsChronologically.reversed())
    }

    mutating func normalizeTransactionDay(
        containing date: Date,
        appending transactionID: UUID? = nil
    ) {
        let indices = transactions.indices.filter {
            StockTransaction.isSameDay(transactions[$0].tradedAt, date)
        }
        guard !indices.isEmpty else { return }

        var orderedIDs = Self.orderedTransactions(indices.map { transactions[$0] }).map(\.id)
        if let transactionID,
           let index = orderedIDs.firstIndex(of: transactionID) {
            orderedIDs.remove(at: index)
            orderedIDs.append(transactionID)
        }

        let normalizedDate = StockTransaction.normalizedDate(date)
        for (dayOrder, transactionID) in orderedIDs.enumerated() {
            guard let index = transactions.firstIndex(where: { $0.id == transactionID }) else {
                continue
            }
            transactions[index].tradedAt = normalizedDate
            transactions[index].dayOrder = dayOrder
        }
    }

    /// 同一天的交易按 `dayOrder` 排，跨天按日期排。
    ///
    /// 排序键在排序前一次性算好，比较器里不再调 `Calendar`：原实现用
    /// `isDate(_:inSameDayAs:)` 判「同日」，一次排序就要做 O(n log n) 次日历运算（实测单次
    /// 约 1 µs），而这个排序会被 `performance(asOf:)` 及其下游属性反复触发。
    ///
    /// 顺带修掉一个真实缺陷：原比较器**不满足严格弱序**。同日记录里只要 `dayOrder` 有缺失，
    /// 就能构造出 a<b<c 却 c<a 的循环（a 有序号 5、b 无序号、c 有序号 1，b 的时间落在
    /// a 与 c 之间），`sorted(by:)` 对这种谓词的结果是未定义的。现在改成一个全序：
    /// 日 → `dayOrder` → 时间 → id。
    static func orderedTransactions(
        _ transactions: [StockTransaction],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [StockTransaction] {
        transactions
            .map { (key: TransactionSortKey($0, calendar: calendar), transaction: $0) }
            .sorted { $0.key < $1.key }
            .map(\.transaction)
    }

    private struct TransactionSortKey: Comparable {
        let day: Date
        /// 缺 `dayOrder` 的记录排在同日已标注顺序的记录之后。`normalizeTransactionDay`
        /// 会给被触碰那一天的**每一条**记录都写上序号，所以同日混合状态实际不会出现。
        let dayOrder: Int
        let tradedAt: Date
        let id: String

        init(_ transaction: StockTransaction, calendar: Calendar) {
            day = calendar.startOfDay(for: transaction.tradedAt)
            dayOrder = transaction.dayOrder ?? Int.max
            tradedAt = transaction.tradedAt
            id = transaction.id.uuidString
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.dayOrder != rhs.dayOrder { return lhs.dayOrder < rhs.dayOrder }
            if lhs.tradedAt != rhs.tradedAt { return lhs.tradedAt < rhs.tradedAt }
            return lhs.id < rhs.id
        }
    }

    /// 与顺序无关的那部分派生量：股数、累计买入、首次买入日。
    ///
    /// 单独拆出来是因为 `listState`/`isArchived`/`hasPurchaseRecord` 会被列表过滤器
    /// 反复调用（持仓页一次 body 里 `StocksView` 的几个分组属性就要各过一遍全部股票），
    /// 而它们并不需要移动平均成本，也就不需要 `performance(asOf:)` 里那次排序。
    struct SharePosition: Equatable, Sendable {
        /// 所有已生效交易的带符号股数之和，不做截断，这样超卖的历史数据仍然会暴露成
        /// 负数而不是被悄悄纠正。
        var shares: Decimal = 0
        var totalBuyCost: Decimal = 0
        var firstPurchasedAt: Date?

        var hasPurchaseRecord: Bool { firstPurchasedAt != nil }
    }

    func sharePosition(asOf now: Date = Date()) -> SharePosition {
        var result = SharePosition()
        for transaction in transactions where transaction.tradedAt <= now {
            result.shares += transaction.signedShares
            guard transaction.type == .buy else { continue }
            result.totalBuyCost += transaction.grossAmount + transaction.fees
            result.firstPurchasedAt = result.firstPurchasedAt
                .map { min($0, transaction.tradedAt) } ?? transaction.tradedAt
        }
        return result
    }

    /// 一次交易回放就能得到的全套派生金额。
    ///
    /// `currentShares`/`holdingCost`/`realizedProfitLoss`/`totalBuyCost` 这些计算属性各自
    /// 都要把全部交易过滤并重排一遍，而页面一次 body 会读十几次（详情页持仓总览 9 格里读
    /// 14 次，持仓页总览读 13 次）。导航转场中 UIKit 会反复同步布局，这个常数倍放大足以
    /// 把一次渲染推到几百毫秒。**热路径请先取一份 `performance(asOf:)` 再复用**，不要逐个
    /// 属性读；下面那些属性只是为了不破坏既有调用点而保留的便捷入口。
    struct Performance: Equatable, Sendable {
        /// 与 `currentShares` 同义。
        var shares: Decimal = 0
        var holdingCost: Decimal = 0
        var realizedTradeProfitLoss: Decimal = 0
        var netDividendIncome: Decimal = 0
        var totalBuyCost: Decimal = 0
        var firstPurchasedAt: Date?

        var hasPurchaseRecord: Bool { firstPurchasedAt != nil }

        var averageHoldingCost: Decimal? {
            guard shares > 0 else { return nil }
            return holdingCost / shares
        }

        var realizedProfitLoss: Decimal {
            realizedTradeProfitLoss + netDividendIncome
        }
    }

    /// 回放全部已生效交易，得到移动平均持仓成本与已实现盈亏。
    ///
    /// 未来日期的交易与分红一律不算，与各个同名属性的既有口径一致。
    func performance(
        asOf now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Performance {
        var result = Performance()

        // 这里没有直接调 `sharePosition(asOf:)`：同一次遍历还要把已生效的交易收集起来
        // 交给下面的排序回放，拆成两趟反而多走一遍全部交易。
        var effectiveTransactions: [StockTransaction] = []
        effectiveTransactions.reserveCapacity(transactions.count)
        for transaction in transactions where transaction.tradedAt <= now {
            effectiveTransactions.append(transaction)
            result.shares += transaction.signedShares
            guard transaction.type == .buy else { continue }
            result.totalBuyCost += transaction.grossAmount + transaction.fees
            result.firstPurchasedAt = result.firstPurchasedAt
                .map { min($0, transaction.tradedAt) } ?? transaction.tradedAt
        }

        var ledger = StockMovingAverageCostLedger()
        for transaction in Self.orderedTransactions(effectiveTransactions, calendar: calendar)
        where transaction.quantity > 0 {
            ledger.apply(transaction)
        }
        result.holdingCost = ledger.cost
        result.realizedTradeProfitLoss = ledger.realized

        // 与 `StockDividend.isReceived(asOf:calendar:)` 同一判定，只是把「今天」的
        // `startOfDay` 提到循环外算一次。
        let today = calendar.startOfDay(for: now)
        for dividend in dividends
        where calendar.startOfDay(for: dividend.receivedAt) <= today {
            result.netDividendIncome += dividend.netAmount
        }

        return result
    }

    /// 常规报价口径下的一只股票的全套金额，一次交易回放算完。
    ///
    /// 这里用的是 `latestPrice`/`previousClose`，也就是常规交易时段的报价。**跨市场聚合
    /// 与列表行禁止用它**，那些地方必须走 `StockHoldingValuation`（它会按当前所处时段挑
    /// 盘前/盘后报价）。详情页的持仓总览与编辑器属于单只股票的常规口径展示，用这个。
    struct Metrics: Equatable, Sendable {
        var performance = Performance()
        var marketValue: Decimal?
        var holdingProfitLoss: Decimal?
        var holdingProfitRate: Decimal?
        var todayProfitLoss: Decimal?
        var totalProfitLoss: Decimal?
    }

    /// 与 `performance(asOf:)` 同理：**热路径请先取一份再复用**，不要逐个读
    /// `marketValue`/`holdingProfitLoss`/`totalProfitLoss` 这些便捷属性，
    /// 它们每一次读取都会完整回放一遍交易。
    func metrics(
        asOf now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Metrics {
        metrics(performance: performance(asOf: now, calendar: calendar))
    }

    func metrics(performance: Performance) -> Metrics {
        var result = Metrics(performance: performance)
        let shares = performance.shares

        if shares == 0 {
            result.marketValue = 0
        } else if shares > 0, let latestPrice {
            result.marketValue = shares * latestPrice
        }

        if let marketValue = result.marketValue {
            let holdingProfitLoss = marketValue - performance.holdingCost
            result.holdingProfitLoss = holdingProfitLoss
            if performance.holdingCost > 0 {
                result.holdingProfitRate = holdingProfitLoss / performance.holdingCost
            }
            result.totalProfitLoss = holdingProfitLoss + performance.realizedProfitLoss
        }

        if shares > 0, let latestPrice, let previousClose {
            result.todayProfitLoss = shares * (latestPrice - previousClose)
        }

        return result
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

#endif
