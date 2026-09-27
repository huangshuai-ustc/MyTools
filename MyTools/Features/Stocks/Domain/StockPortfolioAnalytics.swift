#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockHoldingsExportScope: String, CaseIterable, Identifiable, Sendable {
    case current, all
    var id: Self { self }
    var title: String { self == .current ? "当前持仓" : "全部持仓" }
}

/// Read-only report of a captured portfolio, in each market's native currency.
/// It is not a Vault backup and does not change persisted business data.
enum StockHoldingsCSVExport {
    static func data(
        stocks: [StockHolding], scope: StockHoldingsExportScope,
        extendedHours: [UUID: StockExtendedHoursPerformance], at date: Date
    ) -> Data {
        let timestamp = ISO8601DateFormatter()
        func number(_ value: Decimal?) -> String {
            value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        }
        // Quote every field, preserve line breaks, and neutralize spreadsheet
        // formulas only for untrusted text, never for negative numeric values.
        func text(_ value: String) -> String {
            let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            return first.map { "=+-@".contains($0) } == true ? "'" + value : value
        }
        func row(_ fields: [String]) -> String {
            fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        var lines = [row(["市场", "股票代码", "名称", "状态", "币种", "持仓股数", "持仓成本", "单股成本", "最新价", "报价时段", "持仓市值", "当日盈亏", "持仓盈亏", "持仓盈亏率(%)", "累计买入成本", "已实现交易收益", "净分红", "已实现收益(含分红)", "累计总收益", "常规报价时间", "导出时间", "成本算法"])]
        let ordered = stocks.sorted {
            if $0.market.rawValue != $1.market.rawValue { return $0.market.rawValue < $1.market.rawValue }
            if $0.symbol != $1.symbol { return $0.symbol < $1.symbol }
            return $0.id.uuidString < $1.id.uuidString
        }
        for stock in ordered {
            let performance = stock.performance(asOf: date)
            guard scope == .current ? performance.shares > 0 : performance.hasPurchaseRecord else { continue }
            let quote = StockActiveQuote.make(stock: stock, extendedHours: extendedHours[stock.id], at: date)
            let valuation = StockHoldingValuation(stock: stock, quote: quote, performance: performance)
            let rate = performance.holdingCost > 0
                ? valuation.holdingProfitLoss.map { $0 / performance.holdingCost * 100 } : nil
            lines.append(row([
                stock.market.title, text(stock.symbol), text(stock.displayName),
                performance.shares > 0 ? "持有" : stock.archivedAt != nil ? "已存档" : "已清仓",
                stock.market.currencyCode, number(performance.shares), number(performance.holdingCost),
                number(performance.averageHoldingCost), number(quote.price), quote.sessionTitle,
                number(valuation.marketValue), number(valuation.todayProfitLoss), number(valuation.holdingProfitLoss),
                number(rate), number(performance.totalBuyCost), number(performance.realizedTradeProfitLoss),
                number(performance.netDividendIncome), number(performance.realizedProfitLoss),
                number(valuation.holdingProfitLoss.map { $0 + performance.realizedProfitLoss }),
                stock.lastQuoteAt.map(timestamp.string(from:)) ?? "", timestamp.string(from: date), "移动加权平均"
            ]))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

/// A quote tick does not change the transaction ledger. Cache only the replay;
/// valuation remains cheap and uses the current quote and session.
struct StockPerformanceCache {
    private struct Entry {
        let transactions: [StockTransaction]
        let dividends: [StockDividend]
        let calendar: Calendar
        let computedAt: Date
        let validUntil: Date
        let performance: StockHolding.Performance
    }
    private var entries: [UUID: Entry] = [:]
    private(set) var replayCount = 0

    mutating func performance(for stock: StockHolding, at now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> StockHolding.Performance {
        if let entry = entries[stock.id],
           entry.transactions == stock.transactions, entry.dividends == stock.dividends,
           entry.calendar == calendar, now >= entry.computedAt, now < entry.validUntil {
            return entry.performance
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let nextTransaction = stock.transactions.lazy.map(\.tradedAt).filter { $0 > now }.min() ?? nextDay
        let performance = stock.performance(asOf: now, calendar: calendar)
        entries[stock.id] = Entry(transactions: stock.transactions, dividends: stock.dividends,
                                  calendar: calendar, computedAt: now, validUntil: min(nextDay, nextTransaction),
                                  performance: performance)
        replayCount += 1
        return performance
    }

    mutating func retain(_ ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}

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

    /// `performance` 传入已算好的交易回放结果可避免重复回放；不传就自己算一份。聚合场景
    /// **务必**传，否则每构造一个估值就要把这只股票的全部交易重排一遍（见
    /// `StockHolding.performance(asOf:)` 的说明）。
    init(
        stock: StockHolding,
        quote: StockActiveQuote,
        performance: StockHolding.Performance? = nil
    ) {
        let performance = performance ?? stock.performance()
        let shares = performance.shares
        guard shares > 0 else {
            marketValue = 0
            previousMarketValue = 0
            todayProfitLoss = nil
            holdingProfitLoss = -performance.holdingCost
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
        holdingProfitLoss = value - performance.holdingCost
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
        at now: Date = Date(),
        performance: StockHolding.Performance? = nil
    ) {
        self.init(
            stock: stock,
            quote: StockActiveQuote.make(stock: stock, extendedHours: extendedHours, at: now),
            performance: performance
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
        at now: Date = Date(),
        performances: [UUID: StockHolding.Performance] = [:]
    ) {
        self.market = market
        let marketStocks = stocks.filter { $0.market == market }
        stockCount = marketStocks.count

        // 每只股票只回放一次交易，下面所有小计都从同一份快照里取。原实现对
        // `currentShares`/`holdingCost`/`realizedProfitLoss` 各做一次 `reduce`，再为估值
        // 读两次、为两个 `contains` 各读一次，合计每只股票 7 次完整回放。
        let entries = marketStocks.map { stock -> (
            performance: StockHolding.Performance,
            valuation: StockHoldingValuation
        ) in
            let performance = performances[stock.id] ?? stock.performance(asOf: now)
            return (
                performance: performance,
                // 与持仓行同一个判定入口，所以「市值 = 各行市值之和」是构造上成立的。
                valuation: StockHoldingValuation(
                    stock: stock,
                    extendedHours: extendedHours[stock.id],
                    at: now,
                    performance: performance
                )
            )
        }

        var openPositions = 0
        var cost = Decimal.zero
        var dividends = Decimal.zero
        var realized = Decimal.zero
        var value = Decimal.zero
        var daily = Decimal.zero
        var missingDailyChange = false
        var missingQuotes = false
        for entry in entries {
            let isOpenPosition = entry.performance.shares > 0
            if isOpenPosition { openPositions += 1 }
            cost += entry.performance.holdingCost
            dividends += entry.performance.netDividendIncome
            realized += entry.performance.realizedProfitLoss
            value += entry.valuation.marketValue ?? 0
            daily += entry.valuation.todayProfitLoss ?? 0
            guard isOpenPosition else { continue }
            if entry.valuation.todayProfitLoss == nil { missingDailyChange = true }
            if entry.valuation.marketValue == nil { missingQuotes = true }
        }

        openPositionCount = openPositions
        holdingCost = cost
        netDividendIncome = dividends
        realizedProfitLoss = realized
        knownMarketValue = value
        todayProfitLoss = missingDailyChange ? nil : daily
        hasMissingQuotes = missingQuotes
        profitLoss = missingQuotes ? nil : value - cost
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
        at now: Date = Date(),
        performances: [UUID: StockHolding.Performance] = [:]
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

        for stock in stocks {
            // 每只股票一次回放：原实现为 `hasPurchaseRecord`、`realizedProfitLoss`、
            // `currentShares` 与估值各读一遍，合计 5 次。
            let performance = performances[stock.id] ?? stock.performance(asOf: now)
            guard performance.hasPurchaseRecord else { continue }
            guard let multiplier = multipliers[stock.market] else {
                canConvertCurrencies = false
                canCalculateValue = false
                canCalculateDaily = false
                continue
            }
            realized += performance.realizedProfitLoss * multiplier
            if performance.shares > 0 {
                let valuation = StockHoldingValuation(
                    stock: stock,
                    extendedHours: extendedHours[stock.id],
                    at: now,
                    performance: performance
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
        at now: Date = Date(),
        performances: [UUID: StockHolding.Performance] = [:]
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
                at: now,
                performance: performances[stock.id] ?? stock.performance(asOf: now)
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

    init(stocks: [StockHolding], costMultipliers: [StockMarket: Decimal], performances: [UUID: StockHolding.Performance] = [:]) {
        var valuesByHolding: [UUID: Decimal] = [:]
        var total = Decimal.zero

        for stock in stocks {
            // 一次回放取代 `currentShares` + `holdingCost` × 2 三次。
            let performance = performances[stock.id] ?? stock.performance()
            guard performance.shares > 0, performance.holdingCost > 0 else { continue }
            guard let multiplier = costMultipliers[stock.market] else {
                holdingShares = [:]
                isComplete = false
                return
            }
            let convertedCost = performance.holdingCost * multiplier
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
