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

    var totalSellProceeds: Decimal {
        transactions.lazy
            .filter { $0.type == .sell }
            .reduce(Decimal.zero) { $0 + $1.grossAmount - $1.fees }
    }

    var netInvestment: Decimal {
        totalBuyCost - totalSellProceeds
    }

    var netDividendIncome: Decimal {
        dividends.reduce(Decimal.zero) { $0 + $1.netAmount }
    }

    var marketValue: Decimal? {
        guard currentShares > 0, let latestPrice else {
            return currentShares == 0 ? 0 : nil
        }
        return currentShares * latestPrice
    }

    var totalProfitLoss: Decimal? {
        guard let marketValue else { return nil }
        return marketValue + netDividendIncome - netInvestment
    }

    func canApply(_ transaction: StockTransaction) -> Bool {
        let otherShares = transactions.lazy
            .filter { $0.id != transaction.id }
            .reduce(Decimal.zero) { $0 + $1.signedShares }
        return otherShares + transaction.signedShares >= 0
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
    let netInvestment: Decimal
    let netDividendIncome: Decimal
    let knownMarketValue: Decimal
    let profitLoss: Decimal?
    let hasMissingQuotes: Bool

    init(market: StockMarket, stocks: [StockHolding]) {
        self.market = market
        let marketStocks = stocks.filter { $0.market == market }
        stockCount = marketStocks.count
        openPositionCount = marketStocks.lazy.filter { $0.currentShares > 0 }.count
        netInvestment = marketStocks.reduce(Decimal.zero) { $0 + $1.netInvestment }
        netDividendIncome = marketStocks.reduce(Decimal.zero) { $0 + $1.netDividendIncome }
        knownMarketValue = marketStocks.reduce(Decimal.zero) { result, stock in
            result + (stock.marketValue ?? 0)
        }
        hasMissingQuotes = marketStocks.contains { $0.currentShares > 0 && $0.latestPrice == nil }
        profitLoss = hasMissingQuotes ? nil : knownMarketValue + netDividendIncome - netInvestment
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
