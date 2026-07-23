import Foundation

enum StockMarket: String, Codable, CaseIterable, Identifiable, Sendable {
    case aShare
    case unitedStates

    var id: Self { self }

    var title: String {
        switch self {
        case .aShare: return "A 股"
        case .unitedStates: return "美股"
        }
    }

    var currencyCode: String {
        switch self {
        case .aShare: return "CNY"
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
        market == .aShare ? .redRiseGreenFall : .greenRiseRedFall
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

struct StockHolding: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var market: StockMarket = .aShare
    var symbol = ""
    var name = ""
    var transactions: [StockTransaction] = []
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

    var marketValue: Decimal? {
        guard currentShares > 0, let latestPrice else {
            return currentShares == 0 ? 0 : nil
        }
        return currentShares * latestPrice
    }

    var totalProfitLoss: Decimal? {
        guard let marketValue else { return nil }
        return marketValue - netInvestment
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

        guard market == .aShare else { return normalized }
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
    let knownMarketValue: Decimal
    let profitLoss: Decimal?
    let hasMissingQuotes: Bool

    init(market: StockMarket, stocks: [StockHolding]) {
        self.market = market
        let marketStocks = stocks.filter { $0.market == market }
        stockCount = marketStocks.count
        openPositionCount = marketStocks.lazy.filter { $0.currentShares > 0 }.count
        netInvestment = marketStocks.reduce(Decimal.zero) { $0 + $1.netInvestment }
        knownMarketValue = marketStocks.reduce(Decimal.zero) { result, stock in
            result + (stock.marketValue ?? 0)
        }
        hasMissingQuotes = marketStocks.contains { $0.currentShares > 0 && $0.latestPrice == nil }
        profitLoss = hasMissingQuotes ? nil : knownMarketValue - netInvestment
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
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: value as NSDecimalNumber) ?? "0.00"
        return (value > 0 ? "+" : "") + number + "%"
    }
}
