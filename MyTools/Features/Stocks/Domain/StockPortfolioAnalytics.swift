#if MYTOOLS_FEATURE_STOCKS
import Foundation

/// The quote actually in effect for a holding right now.
///
/// 这是整个股票模块**唯一**的报价判定入口：持仓行、看盘行、市场概况和顶部总览都必须
/// 经过它，任何一处自己去读 `latestPrice`/`previousClose` 就会重新引入「上面按昨收、
/// 下面按盘前」的分裂。
///
/// 只有美股有盘前盘后。价格、涨跌额、涨跌幅永远同源：常规报价三者都取行情源的
/// `latestPrice`/`previousClose`/`changePercent`，扩展时段三者都取
/// `StockExtendedHoursPerformance`（其金额与百分比由 `StockChartPresentation` 的同一
/// 基准派生）。混用两边（用行情源的 `previousClose` 算金额、用图表基准算百分比）正是
/// 「-$1.59（+0.45%）」的来源，所以扩展时段缺任意一项就整组回退到常规报价，绝不拼接。
struct StockActiveQuote {
    /// 这组数字属于哪个时段。行内不再画角标——看盘页顶部的时段条和持仓页总览已经
    /// 说明了当前时段——所以它只用于无障碍朗读。
    let sessionTitle: String
    let price: Decimal?
    let changeAmount: Decimal?
    let percent: Decimal?

    static func make(
        stock: StockHolding,
        extendedHours: StockExtendedHoursPerformance?,
        at now: Date = Date()
    ) -> StockActiveQuote {
        let regular = StockActiveQuote(
            sessionTitle: "当前价格",
            price: stock.latestPrice,
            changeAmount: difference(stock.latestPrice, stock.previousClose),
            percent: stock.changePercent
        )
        guard stock.market == .unitedStates else { return regular }
        switch StockMarketTradingCalendar.session(for: stock.market, at: now) {
        case .preMarket:
            // 价格、涨跌额、涨跌幅必须整套齐备才切到盘前：缺一个就说明这份缓存不属于
            // 当前交易日（`StockChartPresentation.preMarketPerformance` 会按当天校验），
            // 此时整行回退到常规报价，迷你图也跟着画同一段。
            guard let extendedHours,
                  let price = extendedHours.preMarketPrice,
                  let change = extendedHours.preMarketChange,
                  let percent = extendedHours.preMarketPercent else { return regular }
            return StockActiveQuote(
                sessionTitle: "盘前",
                price: price,
                changeAmount: change,
                percent: percent
            )
        case .postMarket:
            guard let extendedHours,
                  let price = extendedHours.postMarketPrice,
                  let change = extendedHours.postMarketChange,
                  let percent = extendedHours.postMarketPercent else { return regular }
            return StockActiveQuote(
                sessionTitle: "盘后",
                price: price,
                changeAmount: change,
                percent: percent
            )
        case .regular, .closed:
            return regular
        }
    }

    private static func difference(_ price: Decimal?, _ reference: Decimal?) -> Decimal? {
        guard let price, let reference else { return nil }
        return price - reference
    }
}

/// 一只股票在当前时段的全部派生金额，全部由同一个 `StockActiveQuote` 算出。
///
/// 持仓行、市场概况和顶部总览都用它，所以「总览 = 各行之和」是**构造上成立**的，而不是
/// 两条链路碰巧一致。`StockHolding` 上同名的 `marketValue`/`todayProfitLoss`/
/// `holdingProfitLoss` 只看常规报价，聚合时不要再直接用它们。
///
/// 语义与 `StockHolding` 的同名属性对齐：清仓后市值确定为 0、当日盈亏为 nil（没有敞口
/// 就没有当日涨跌）；持有中缺价格时全部为 nil，缺涨跌额时只有当日两项为 nil。
struct StockHoldingValuation {
    let marketValue: Decimal?
    /// 上一个基准时刻的持仓市值，即 `todayChangeRate` 的分母。基准跟着报价走：常规时段
    /// 是昨收，盘前是上一个已结算收盘，盘后是当日盘中收盘。
    let previousMarketValue: Decimal?
    let todayProfitLoss: Decimal?
    let holdingProfitLoss: Decimal?

    init(stock: StockHolding, quote: StockActiveQuote) {
        let shares = stock.currentShares
        guard shares > 0 else {
            marketValue = 0
            previousMarketValue = 0
            todayProfitLoss = nil
            holdingProfitLoss = -stock.holdingCost
            return
        }
        guard let price = quote.price else {
            marketValue = nil
            previousMarketValue = nil
            todayProfitLoss = nil
            holdingProfitLoss = nil
            return
        }
        let value = shares * price
        marketValue = value
        holdingProfitLoss = value - stock.holdingCost
        guard let change = quote.changeAmount else {
            previousMarketValue = nil
            todayProfitLoss = nil
            return
        }
        todayProfitLoss = shares * change
        previousMarketValue = shares * (price - change)
    }

    init(
        stock: StockHolding,
        extendedHours: StockExtendedHoursPerformance?,
        at now: Date = Date()
    ) {
        self.init(
            stock: stock,
            quote: StockActiveQuote.make(stock: stock, extendedHours: extendedHours, at: now)
        )
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

    /// 传入 `extendedHours` 才能让市场概况与持仓行在美股盘前/盘后保持同口径；默认空表
    /// 等价于「只看常规报价」，老调用点与测试无需改动。
    init(
        market: StockMarket,
        stocks: [StockHolding],
        extendedHours: [UUID: StockExtendedHoursPerformance] = [:],
        at now: Date = Date()
    ) {
        self.market = market
        let marketStocks = stocks.filter { $0.market == market }
        stockCount = marketStocks.count
        openPositionCount = marketStocks.lazy.filter { $0.currentShares > 0 }.count
        holdingCost = marketStocks.reduce(Decimal.zero) { $0 + $1.holdingCost }
        netDividendIncome = marketStocks.reduce(Decimal.zero) { $0 + $1.netDividendIncome }
        realizedProfitLoss = marketStocks.reduce(Decimal.zero) { $0 + $1.realizedProfitLoss }
        // 与持仓行同一个判定入口，所以「市值 = 各行市值之和」是构造上成立的。
        let valuations = marketStocks.map { stock in
            (
                stock: stock,
                valuation: StockHoldingValuation(
                    stock: stock,
                    extendedHours: extendedHours[stock.id],
                    at: now
                )
            )
        }
        knownMarketValue = valuations.reduce(Decimal.zero) { result, entry in
            result + (entry.valuation.marketValue ?? 0)
        }
        let hasMissingDailyChange = valuations.contains {
            $0.stock.currentShares > 0 && $0.valuation.todayProfitLoss == nil
        }
        todayProfitLoss = hasMissingDailyChange
            ? nil
            : valuations.reduce(Decimal.zero) { $0 + ($1.valuation.todayProfitLoss ?? 0) }
        hasMissingQuotes = valuations.contains {
            $0.stock.currentShares > 0 && $0.valuation.marketValue == nil
        }
        profitLoss = hasMissingQuotes ? nil : knownMarketValue - holdingCost
    }
}

struct StockConvertedPortfolioSummary {
    let marketValue: Decimal?
    let todayProfitLoss: Decimal?
    let holdingProfitLoss: Decimal?
    /// 已落袋的部分：卖出实现的盈亏加净分红（`StockHolding.realizedProfitLoss`
    /// 的定义）。它不依赖行情，只要每个市场都有汇率就能算，所以缺行情时仍然可用，
    /// 与 `holdingProfitLoss` 的可用条件不同。
    let realizedProfitLoss: Decimal?
    let totalProfitLoss: Decimal?
    /// Yesterday's closing value of the shares still held, converted with the
    /// same multipliers. This is the denominator `todayChangeRate` needs; it is
    /// nil whenever any held position is missing a quote or an exchange rate.
    let previousMarketValue: Decimal?

    /// Today's move as a rate of yesterday's closing value.
    var todayChangeRate: Decimal? {
        guard let todayProfitLoss,
              let previousMarketValue,
              previousMarketValue > 0 else { return nil }
        return todayProfitLoss / previousMarketValue
    }

    /// `extendedHours` 与持仓行用的是同一份 `StockStore.extendedHoursPerformance`，所以
    /// 顶部大字在美股盘前/盘后与下面每一行同口径。代价是盘前流动性稀薄时大字会跟着跳，
    /// 这是刻意接受的：宁可一起动，也不要上下两个口径。
    init(
        stocks: [StockHolding],
        multipliers: [StockMarket: Decimal],
        extendedHours: [UUID: StockExtendedHoursPerformance] = [:],
        at now: Date = Date()
    ) {
        var value = Decimal.zero
        var daily = Decimal.zero
        var previousValue = Decimal.zero
        var holding = Decimal.zero
        var realized = Decimal.zero
        var canCalculateValue = true
        var canCalculateDaily = true
        /// 已实现收益只需要汇率，不需要行情。
        var canConvertCurrencies = true

        for stock in stocks where stock.hasPurchaseRecord {
            guard let multiplier = multipliers[stock.market] else {
                canConvertCurrencies = false
                canCalculateValue = false
                canCalculateDaily = false
                continue
            }
            realized += stock.realizedProfitLoss * multiplier
            if stock.currentShares > 0 {
                let valuation = StockHoldingValuation(
                    stock: stock,
                    extendedHours: extendedHours[stock.id],
                    at: now
                )
                if let marketValue = valuation.marketValue,
                   let holdingProfitLoss = valuation.holdingProfitLoss {
                    value += marketValue * multiplier
                    holding += holdingProfitLoss * multiplier
                } else {
                    canCalculateValue = false
                }
                // 分母跟着报价走：`previousMarketValue` 是本行百分比的基准市值，不再
                // 单独去读 `previousClose`（盘前那是前一天的收盘，与大字口径打架）。
                if let todayProfitLoss = valuation.todayProfitLoss,
                   let previousMarketValue = valuation.previousMarketValue {
                    daily += todayProfitLoss * multiplier
                    previousValue += previousMarketValue * multiplier
                } else {
                    canCalculateDaily = false
                }
            }
        }

        marketValue = canCalculateValue ? value : nil
        todayProfitLoss = canCalculateDaily ? daily : nil
        previousMarketValue = canCalculateDaily ? previousValue : nil
        holdingProfitLoss = canCalculateValue ? holding : nil
        realizedProfitLoss = canConvertCurrencies ? realized : nil
        totalProfitLoss = canCalculateValue ? holding + realized : nil
    }
}

struct StockAllocationSnapshot {
    private let holdingShares: [UUID: Decimal]
    private let marketShares: [StockMarket: Decimal]
    let isComplete: Bool

    init(
        stocks: [StockHolding],
        marketValueMultipliers: [StockMarket: Decimal],
        extendedHours: [UUID: StockExtendedHoursPerformance] = [:],
        at now: Date = Date()
    ) {
        var valuesByHolding: [UUID: Decimal] = [:]
        var valuesByMarket = Dictionary(
            uniqueKeysWithValues: StockMarket.allCases.map { ($0, Decimal.zero) }
        )
        var total = Decimal.zero
        var complete = true

        for stock in stocks {
            // 占比的分子分母都用与持仓行相同的报价，否则盘前的占比会和行内市值不匹配。
            let valuation = StockHoldingValuation(
                stock: stock,
                extendedHours: extendedHours[stock.id],
                at: now
            )
            guard let marketValue = valuation.marketValue else {
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
