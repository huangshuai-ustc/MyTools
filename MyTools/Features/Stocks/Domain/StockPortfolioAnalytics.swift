#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct StockPortfolioSummary {
    let market: StockMarket
    let stockCount: Int
    let openPositionCount: Int
    let holdingCost: Decimal
    let netDividendIncome: Decimal
    let realizedProfitLoss: Decimal
    let knownMarketValue: Decimal
    let todayProfitLoss: Decimal?
    let profitLoss: Decimal?
    let hasMissingQuotes: Bool

    var totalProfitLoss: Decimal? {
        profitLoss.map { $0 + realizedProfitLoss }
    }

    /// Unrealized return for all currently held positions in this market.
    /// Both operands use the market's native currency, so no conversion is
    /// needed until summaries from different markets are combined.
    var holdingProfitRate: Decimal? {
        guard holdingCost != 0, let profitLoss else { return nil }
        return profitLoss / holdingCost
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
        let hasMissingDailyChange = marketStocks.contains {
            $0.currentShares > 0 && $0.todayProfitLoss == nil
        }
        todayProfitLoss = hasMissingDailyChange
            ? nil
            : marketStocks.reduce(Decimal.zero) { $0 + ($1.todayProfitLoss ?? 0) }
        hasMissingQuotes = marketStocks.contains { $0.currentShares > 0 && $0.latestPrice == nil }
        profitLoss = hasMissingQuotes ? nil : knownMarketValue - holdingCost
    }
}

struct StockConvertedPortfolioSummary {
    let marketValue: Decimal?
    let todayProfitLoss: Decimal?
    let holdingProfitLoss: Decimal?
    let totalProfitLoss: Decimal?

    init(stocks: [StockHolding], multipliers: [StockMarket: Decimal]) {
        var value = Decimal.zero
        var daily = Decimal.zero
        var holding = Decimal.zero
        var realized = Decimal.zero
        var canCalculateValue = true
        var canCalculateDaily = true

        for stock in stocks where stock.hasPurchaseRecord {
            guard let multiplier = multipliers[stock.market] else {
                canCalculateValue = false
                canCalculateDaily = false
                continue
            }
            realized += stock.realizedProfitLoss * multiplier
            if stock.currentShares > 0 {
                if let marketValue = stock.marketValue,
                   let holdingProfitLoss = stock.holdingProfitLoss {
                    value += marketValue * multiplier
                    holding += holdingProfitLoss * multiplier
                } else {
                    canCalculateValue = false
                }
                if let todayProfitLoss = stock.todayProfitLoss {
                    daily += todayProfitLoss * multiplier
                } else {
                    canCalculateDaily = false
                }
            }
        }

        marketValue = canCalculateValue ? value : nil
        todayProfitLoss = canCalculateDaily ? daily : nil
        holdingProfitLoss = canCalculateValue ? holding : nil
        totalProfitLoss = canCalculateValue ? holding + realized : nil
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

/// Cost-basis allocation for the currently held positions. Unlike market-value
/// allocation, this remains available when a quote is missing; only the
/// exchange-rate inputs needed to compare different currencies are required.
struct StockCostAllocationSnapshot {
    private let holdingShares: [UUID: Decimal]
    let isComplete: Bool

    init(stocks: [StockHolding], costMultipliers: [StockMarket: Decimal]) {
        var valuesByHolding: [UUID: Decimal] = [:]
        var total = Decimal.zero

        for stock in stocks where stock.currentShares > 0 && stock.holdingCost > 0 {
            guard let multiplier = costMultipliers[stock.market] else {
                holdingShares = [:]
                isComplete = false
                return
            }
            let convertedCost = stock.holdingCost * multiplier
            valuesByHolding[stock.id] = convertedCost
            total += convertedCost
        }

        if total > 0 {
            holdingShares = valuesByHolding.mapValues { $0 / total }
        } else {
            holdingShares = valuesByHolding.mapValues { _ in 0 }
        }
        isComplete = true
    }

    func holdingShare(for stockID: UUID) -> Decimal? {
        guard isComplete else { return nil }
        return holdingShares[stockID]
    }
}

#endif
