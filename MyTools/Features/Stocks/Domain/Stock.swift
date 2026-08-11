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

struct StockTransaction: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var type: StockTransactionType = .buy
    var tradedAt = Date()
    var dayOrder: Int?
    var quantity: Decimal = 0
    var unitPrice: Decimal = 0
    var fees: Decimal = 0

    static func normalizedDate(_ date: Date) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .hour, value: 12, to: startOfDay) ?? startOfDay
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

    var hasConfiguredSymbol: Bool {
        !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private static func orderedTransactions(_ transactions: [StockTransaction]) -> [StockTransaction] {
        transactions.sorted {
            if !StockTransaction.isSameDay($0.tradedAt, $1.tradedAt) {
                return $0.tradedAt < $1.tradedAt
            }
            if let lhsOrder = $0.dayOrder,
               let rhsOrder = $1.dayOrder,
               lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if $0.tradedAt != $1.tradedAt {
                return $0.tradedAt < $1.tradedAt
            }
            return $0.id.uuidString < $1.id.uuidString
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

#endif
