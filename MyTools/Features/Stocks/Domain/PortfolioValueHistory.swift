#if MYTOOLS_FEATURE_STOCKS
import Foundation

struct PortfolioValuePoint: Identifiable, Codable, Sendable {
    let date: Date
    let value: Decimal
    let open: Decimal?
    let high: Decimal?
    let low: Decimal?

    init(
        date: Date,
        value: Decimal,
        open: Decimal? = nil,
        high: Decimal? = nil,
        low: Decimal? = nil
    ) {
        self.date = date
        self.value = value
        self.open = open
        self.high = high
        self.low = low
    }

    var candleOpen: Decimal { open ?? value }
    var candleHigh: Decimal { high ?? max(candleOpen, value) }
    var candleLow: Decimal { low ?? min(candleOpen, value) }
    var id: Date { date }
}

struct PortfolioCostBasisPoint: Identifiable, Codable, Sendable {
    let date: Date
    let cost: Decimal
    var id: Date { date }
}

struct PortfolioValueSeries: Identifiable, Codable, Sendable {
    let id: String
    let label: String
    let market: StockMarket?
    let currencyCode: String
    let points: [PortfolioValuePoint]
    /// Current holding cost (moving weighted-average), expressed in `currencyCode`.
    /// Used to draw a cost reference line, mirroring the previous-close line on
    /// the single-stock chart. `nil` when the series has no current holding.
    var costBasis: Decimal? = nil
    /// Point-in-time holding cost as of each date in `points`, so a cost
    /// reference line can be drawn per-segment instead of using today's
    /// static `costBasis` for the whole visible range.
    var costBasisPoints: [PortfolioCostBasisPoint] = []
}

enum PortfolioValueHistoryBuilder {

    static func buildSeries(
        for market: StockMarket,
        stocks: [StockHolding],
        dailyPointsBySymbol: [String: [StockChartPoint]],
        todayPriceOverrides: [String: Decimal] = [:]
    ) -> PortfolioValueSeries {
        let marketStocks = stocks.filter { $0.market == market && !$0.transactions.isEmpty }

        guard !marketStocks.isEmpty else {
            return PortfolioValueSeries(
                id: market.rawValue,
                label: market.title,
                market: market,
                currencyCode: market.currencyCode,
                points: []
            )
        }

        // Collect all unique trading dates across all stocks
        var allDates = Set<Date>()
        var pricesBySymbol: [String: [Date: Decimal]] = [:]
        var dailyBarsBySymbol: [String: [Date: StockChartPoint]] = [:]

        let cal = StockChartSeriesProcessor.marketCalendar(market)

        for stock in marketStocks {
            guard let dailyPoints = dailyPointsBySymbol[stock.symbol], !dailyPoints.isEmpty else {
                continue
            }
            var prices: [Date: Decimal] = [:]
            var bars: [Date: StockChartPoint] = [:]
            for point in dailyPoints {
                let day = cal.startOfDay(for: point.date)
                prices[day] = decimalPrice(point.close)
                bars[day] = point
                allDates.insert(day)
            }
            // Inject today's live price so intraday/fiveDay ranges show the current value
            if let todayPrice = todayPriceOverrides[stock.symbol] {
                let today = cal.startOfDay(for: Date())
                prices[today] = todayPrice
                allDates.insert(today)
            }
            pricesBySymbol[stock.symbol] = prices
            dailyBarsBySymbol[stock.symbol] = bars
        }

        guard !allDates.isEmpty else {
            return PortfolioValueSeries(
                id: market.rawValue,
                label: market.title,
                market: market,
                currencyCode: market.currencyCode,
                points: []
            )
        }

        // Sort dates chronologically
        let sortedDates = allDates.sorted()

        // Find the earliest holding start date
        let earliestHoldingDate = marketStocks.compactMap(\.firstPurchasedAt).min()
        guard let startDate = earliestHoldingDate else {
            return PortfolioValueSeries(
                id: market.rawValue,
                label: market.title,
                market: market,
                currencyCode: market.currencyCode,
                points: []
            )
        }

        let startDay = cal.startOfDay(for: startDate)

        // Build carry-forward price tables
        var carryForwardPrices: [String: Decimal] = [:]
        var result: [PortfolioValuePoint] = []

        for date in sortedDates where date >= startDay {
            var totalValue: Decimal = 0
            var totalOpen: Decimal = 0
            var totalHigh: Decimal = 0
            var totalLow: Decimal = 0
            var hasAnyHolding = false

            for stock in marketStocks {
                let shares = sharesHeld(for: stock, on: date)
                guard shares > 0 else { continue }
                hasAnyHolding = true

                // Update carry-forward price
                let dailyPoint = dailyBarsBySymbol[stock.symbol]?[date]
                if let price = pricesBySymbol[stock.symbol]?[date] {
                    carryForwardPrices[stock.symbol] = price
                }

                guard let price = carryForwardPrices[stock.symbol] else { continue }
                totalValue += shares * price
                totalOpen += shares * (dailyPoint.map { decimalPrice($0.open) } ?? price)
                totalHigh += shares * (dailyPoint.map { decimalPrice($0.high) } ?? price)
                totalLow += shares * (dailyPoint.map { decimalPrice($0.low) } ?? price)
            }

            if hasAnyHolding {
                result.append(PortfolioValuePoint(
                    date: date,
                    value: totalValue,
                    open: totalOpen,
                    high: totalHigh,
                    low: totalLow
                ))
            }
        }

        return PortfolioValueSeries(
            id: market.rawValue,
            label: market.title,
            market: market,
            currencyCode: market.currencyCode,
            points: result,
            costBasis: totalHoldingCost(marketStocks),
            costBasisPoints: costBasisPoints(marketStocks, dates: result.map(\.date))
        )
    }

    static func buildMinuteSeries(
        for market: StockMarket,
        range: StockChartRange,
        stocks: [StockHolding],
        minutePointsBySymbol: [String: [StockChartPoint]]
    ) -> PortfolioValueSeries {
        let marketStocks = stocks.filter { $0.market == market && !$0.transactions.isEmpty }

        guard !marketStocks.isEmpty else {
            return PortfolioValueSeries(
                id: "\(market.rawValue)_minute",
                label: market.title,
                market: market,
                currencyCode: market.currencyCode,
                points: []
            )
        }

        // Collect session-filtered minute points per symbol, then scope to range.
        // The trading day/window is determined once from the union of all
        // symbols' points so a symbol whose data lags behind the others
        // cannot pull the merged series across more than one calendar day.
        var sessionBySymbol: [String: [StockChartPoint]] = [:]
        var unionPoints: [StockChartPoint] = []
        for stock in marketStocks {
            let raw = minutePointsBySymbol[stock.symbol] ?? []
            guard !raw.isEmpty else { continue }
            let session = StockChartSeriesProcessor.regularSessionPoints(raw, market: market)
            guard !session.isEmpty else { continue }
            sessionBySymbol[stock.symbol] = session
            unionPoints.append(contentsOf: session)
        }

        guard !unionPoints.isEmpty else {
            return PortfolioValueSeries(
                id: "\(market.rawValue)_minute",
                label: market.title,
                market: market,
                currencyCode: market.currencyCode,
                points: []
            )
        }

        let retainedTimestamps: Set<Date>
        switch range {
        case .intraday:
            retainedTimestamps = Set(
                StockChartSeriesProcessor.pointsOnLatestTradingDay(unionPoints, market: market).map(\.date)
            )
        case .fiveDays:
            retainedTimestamps = Set(
                StockChartSeriesProcessor.pointsOnLatestTradingDays(unionPoints, count: 5, market: market).map(\.date)
            )
        default:
            retainedTimestamps = Set(unionPoints.map(\.date))
        }

        var scopedBySymbol: [String: [StockChartPoint]] = [:]
        for (symbol, session) in sessionBySymbol {
            let scoped = session.filter { retainedTimestamps.contains($0.date) }
            guard !scoped.isEmpty else { continue }
            scopedBySymbol[symbol] = scoped
        }

        guard !scopedBySymbol.isEmpty else {
            return PortfolioValueSeries(
                id: "\(market.rawValue)_minute",
                label: market.title,
                market: market,
                currencyCode: market.currencyCode,
                points: []
            )
        }

        // Union of all minute timestamps
        var allTimestamps = Set<Date>()
        for pts in scopedBySymbol.values {
            for p in pts { allTimestamps.insert(p.date) }
        }
        let sortedTimestamps = allTimestamps.sorted()

        // Carry-forward price per symbol. Shares are advanced with a transaction
        // cursor below so minute charts do not rescan every transaction for every
        // timestamp.
        var priceBySymbol: [String: [Date: Decimal]] = [:]
        var barsBySymbol: [String: [Date: StockChartPoint]] = [:]
        for (sym, pts) in scopedBySymbol {
            var map: [Date: Decimal] = [:]
            var bars: [Date: StockChartPoint] = [:]
            for p in pts {
                map[p.date] = decimalPrice(p.close)
                bars[p.date] = p
            }
            priceBySymbol[sym] = map
            barsBySymbol[sym] = bars
        }

        var carryForwardPrices: [String: Decimal] = [:]
        let transactionsByStock = Dictionary(uniqueKeysWithValues: marketStocks.map { stock in
            (stock.id, stock.transactions.sorted { $0.tradedAt < $1.tradedAt })
        })
        var transactionOffsets: [UUID: Int] = [:]
        var sharesByStock: [UUID: Decimal] = [:]
        var result: [PortfolioValuePoint] = []

        for ts in sortedTimestamps {
            var totalValue: Decimal = 0
            var totalOpen: Decimal = 0
            var totalHigh: Decimal = 0
            var totalLow: Decimal = 0
            var hasAnyHolding = false

            for stock in marketStocks {
                let transactions = transactionsByStock[stock.id] ?? []
                var offset = transactionOffsets[stock.id, default: 0]
                var shares = sharesByStock[stock.id, default: 0]
                while offset < transactions.count, transactions[offset].tradedAt <= ts {
                    shares += transactions[offset].signedShares
                    offset += 1
                }
                transactionOffsets[stock.id] = offset
                sharesByStock[stock.id] = shares
                guard shares > 0 else { continue }
                hasAnyHolding = true

                if let price = priceBySymbol[stock.symbol]?[ts] {
                    carryForwardPrices[stock.symbol] = price
                }
                guard let price = carryForwardPrices[stock.symbol] else { continue }
                totalValue += shares * price
                let minutePoint = barsBySymbol[stock.symbol]?[ts]
                totalOpen += shares * (minutePoint.map { decimalPrice($0.open) } ?? price)
                totalHigh += shares * (minutePoint.map { decimalPrice($0.high) } ?? price)
                totalLow += shares * (minutePoint.map { decimalPrice($0.low) } ?? price)
            }

            if hasAnyHolding {
                result.append(PortfolioValuePoint(
                    date: ts,
                    value: totalValue,
                    open: totalOpen,
                    high: totalHigh,
                    low: totalLow
                ))
            }
        }

        return PortfolioValueSeries(
            id: "\(market.rawValue)_minute",
            label: market.title,
            market: market,
            currencyCode: market.currencyCode,
            points: result,
            costBasis: totalHoldingCost(marketStocks),
            costBasisPoints: costBasisPoints(marketStocks, dates: result.map(\.date))
        )
    }

    static func buildMinuteCNYSeries(
        from marketSeries: [PortfolioValueSeries],
        rates: [CurrencyCode: Decimal]
    ) -> PortfolioValueSeries? {
        let convertibleSeries = marketSeries.filter { series in
            guard let market = series.market, !series.points.isEmpty else { return false }
            if market == .aShare { return true }
            return rates[currencyCode(for: market)] != nil
        }
        guard !convertibleSeries.isEmpty else { return nil }

        let cnyCostBasis = convertedCostBasis(convertibleSeries, rates: rates)

        var allTimestamps = Set<Date>()
        for series in convertibleSeries {
            for point in series.points { allTimestamps.insert(point.date) }
        }
        let sortedTimestamps = allTimestamps.sorted()

        var lastPoints: [String: PortfolioValuePoint] = [:]
        var pointOffsets: [String: Int] = [:]
        var result: [PortfolioValuePoint] = []

        for ts in sortedTimestamps {
            var cnyTotal: Decimal = 0
            var cnyOpen: Decimal = 0
            var cnyHigh: Decimal = 0
            var cnyLow: Decimal = 0
            var hasAny = false

            for series in convertibleSeries {
                guard let market = series.market else { continue }
                let rate: Decimal
                if market == .aShare {
                    rate = 1
                } else if let r = rates[currencyCode(for: market)] {
                    rate = r
                } else {
                    continue
                }

                var offset = pointOffsets[series.id, default: 0]
                while offset < series.points.count, series.points[offset].date <= ts {
                    lastPoints[series.id] = series.points[offset]
                    offset += 1
                }
                pointOffsets[series.id] = offset
                if let point = lastPoints[series.id] {
                    cnyTotal += point.value * rate
                    cnyOpen += point.candleOpen * rate
                    cnyHigh += point.candleHigh * rate
                    cnyLow += point.candleLow * rate
                    hasAny = true
                }
            }

            if hasAny {
                result.append(PortfolioValuePoint(
                    date: ts,
                    value: cnyTotal,
                    open: cnyOpen,
                    high: cnyHigh,
                    low: cnyLow
                ))
            }
        }

        return PortfolioValueSeries(
            id: "cny_total_minute",
            label: "人民币合计",
            market: nil,
            currencyCode: "CNY",
            points: result,
            costBasis: cnyCostBasis,
            costBasisPoints: convertedCostBasisPoints(convertibleSeries, dates: result.map(\.date), rates: rates)
        )
    }


    static func buildCNYSeries(
        from marketSeries: [PortfolioValueSeries],
        rates: [CurrencyCode: Decimal]
    ) -> PortfolioValueSeries? {
        let convertibleSeries = marketSeries.filter { series in
            guard let market = series.market, !series.points.isEmpty else { return false }
            if market == .aShare { return true }
            let code = currencyCode(for: market)
            return rates[code] != nil
        }
        guard !convertibleSeries.isEmpty else { return nil }

        let cnyCostBasis = convertedCostBasis(convertibleSeries, rates: rates)

        // Union of all dates
        var allDates = Set<Date>()
        for series in convertibleSeries {
            for point in series.points { allDates.insert(point.date) }
        }
        let sortedDates = allDates.sorted()

        // Build last-known value per market for carry-forward on CNY series
        var lastPoints: [String: PortfolioValuePoint] = [:]
        var result: [PortfolioValuePoint] = []

        for date in sortedDates {
            var cnyTotal: Decimal = 0
            var cnyOpen: Decimal = 0
            var cnyHigh: Decimal = 0
            var cnyLow: Decimal = 0
            var hasAny = false

            for series in convertibleSeries {
                guard let market = series.market else { continue }
                let rate: Decimal
                if market == .aShare {
                    rate = 1
                } else if let r = rates[currencyCode(for: market)] {
                    rate = r
                } else {
                    continue
                }

                if let point = series.points.first(where: { $0.date == date }) {
                    lastPoints[series.id] = point
                }
                if let point = lastPoints[series.id] {
                    cnyTotal += point.value * rate
                    cnyOpen += point.candleOpen * rate
                    cnyHigh += point.candleHigh * rate
                    cnyLow += point.candleLow * rate
                    hasAny = true
                }
            }

            if hasAny {
                result.append(PortfolioValuePoint(
                    date: date,
                    value: cnyTotal,
                    open: cnyOpen,
                    high: cnyHigh,
                    low: cnyLow
                ))
            }
        }

        return PortfolioValueSeries(
            id: "cny_total",
            label: "人民币合计",
            market: nil,
            currencyCode: "CNY",
            points: result,
            costBasis: cnyCostBasis,
            costBasisPoints: convertedCostBasisPoints(convertibleSeries, dates: result.map(\.date), rates: rates)
        )
    }

    static func sharesHeld(for stock: StockHolding, on date: Date) -> Decimal {
        stock.transactions
            .filter { $0.tradedAt <= date }
            .reduce(Decimal.zero) { $0 + $1.signedShares }
    }

    /// Moving weighted-average holding cost as of `date`, mirroring
    /// `Stock.swift`'s current-day `transactionPerformance` but replaying only
    /// the transactions up to that point in time. `nil` when no shares are
    /// held as of `date`.
    static func holdingCost(for stock: StockHolding, on date: Date) -> Decimal? {
        var shares = Decimal.zero
        var cost = Decimal.zero
        let effectiveTransactions = stock.transactions.filter { $0.tradedAt <= date }
        for transaction in StockHolding.orderedTransactions(effectiveTransactions) where transaction.quantity > 0 {
            switch transaction.type {
            case .buy:
                shares += transaction.quantity
                cost += transaction.grossAmount + transaction.fees
            case .sell:
                guard shares > 0 else { continue }
                let soldShares = min(transaction.quantity, shares)
                let averageCost = cost / shares
                shares -= soldShares
                cost -= averageCost * soldShares
                if shares == 0 { cost = 0 }
            }
        }
        return shares > 0 ? cost : nil
    }

    /// Sum of each market stock's point-in-time holding cost as of `date`, in
    /// the market's own currency. `nil` when no stock is held on that date.
    static func totalHoldingCost(_ stocks: [StockHolding], on date: Date) -> Decimal? {
        let costs = stocks.compactMap { holdingCost(for: $0, on: date) }
        guard !costs.isEmpty else { return nil }
        return costs.reduce(Decimal.zero, +)
    }

    /// Builds one point-in-time total cost value per date in `dates`, so the
    /// chart can draw a cost reference that changes when transactions change
    /// the holding cost, instead of a single flat "today" value.
    private static func costBasisPoints(
        _ stocks: [StockHolding],
        dates: [Date]
    ) -> [PortfolioCostBasisPoint] {
        dates.compactMap { date in
            totalHoldingCost(stocks, on: date).map { PortfolioCostBasisPoint(date: date, cost: $0) }
        }
    }

    private static func currencyCode(for market: StockMarket) -> CurrencyCode {
        switch market {
        case .aShare: return .cny
        case .hongKong: return .hkd
        case .unitedStates: return .usd
        }
    }

    private static func decimalPrice(_ value: Double) -> Decimal {
        // Parse the shortest decimal representation at the domain boundary;
        // all subsequent position and currency calculations stay in Decimal.
        Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
            ?? Decimal(value)
    }

    /// Sum of current holding cost across stocks, in the market's own currency.
    /// Stocks with no current position (`holdingCost == 0`) contribute nothing.
    private static func totalHoldingCost(_ stocks: [StockHolding]) -> Decimal? {
        guard stocks.contains(where: { $0.currentShares > 0 }) else { return nil }
        return stocks.reduce(Decimal.zero) { $0 + $1.holdingCost }
    }

    /// Converts each per-market series' `costBasis` into CNY and sums them,
    /// mirroring the rate lookup rules used for the value series itself.
    private static func convertedCostBasis(
        _ series: [PortfolioValueSeries],
        rates: [CurrencyCode: Decimal]
    ) -> Decimal? {
        var total: Decimal = 0
        var hasAny = false
        for item in series {
            guard let market = item.market, let cost = item.costBasis else { continue }
            let rate: Decimal
            if market == .aShare {
                rate = 1
            } else if let r = rates[currencyCode(for: market)] {
                rate = r
            } else {
                continue
            }
            total += cost * rate
            hasAny = true
        }
        return hasAny ? total : nil
    }

    /// Point-in-time counterpart to `convertedCostBasis`: at each date, sums
    /// every per-market series' carried-forward `costBasisPoints` value,
    /// converted to CNY with the same rate rules.
    private static func convertedCostBasisPoints(
        _ series: [PortfolioValueSeries],
        dates: [Date],
        rates: [CurrencyCode: Decimal]
    ) -> [PortfolioCostBasisPoint] {
        var lastCosts: [String: Decimal] = [:]
        var offsets: [String: Int] = [:]
        var result: [PortfolioCostBasisPoint] = []
        for date in dates {
            var total: Decimal = 0
            var hasAny = false
            for item in series {
                guard let market = item.market else { continue }
                let rate: Decimal
                if market == .aShare {
                    rate = 1
                } else if let r = rates[currencyCode(for: market)] {
                    rate = r
                } else {
                    continue
                }
                var offset = offsets[item.id, default: 0]
                while offset < item.costBasisPoints.count, item.costBasisPoints[offset].date <= date {
                    lastCosts[item.id] = item.costBasisPoints[offset].cost
                    offset += 1
                }
                offsets[item.id] = offset
                if let cost = lastCosts[item.id] {
                    total += cost * rate
                    hasAny = true
                }
            }
            if hasAny {
                result.append(PortfolioCostBasisPoint(date: date, cost: total))
            }
        }
        return result
    }
}

#endif
