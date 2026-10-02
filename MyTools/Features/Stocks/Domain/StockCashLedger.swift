#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockCashFlowKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case deposit
    case withdrawal
    case transferLoss

    var id: Self { self }

    var title: String {
        switch self {
        case .deposit: return "入金"
        case .withdrawal: return "出金"
        case .transferLoss: return "资金损耗"
        }
    }
}

/// An external movement at the boundary of the aggregated investment pool.
/// Broker accounts are intentionally not represented: all brokers form one
/// pool, while exchange records remain independent facts referenced by ID.
struct StockCashFlowRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var occurredAt = Date()
    var kind: StockCashFlowKind = .deposit
    var currency: CurrencyCode = .cny
    var amount: Decimal = 0
    var linkedExchangeRecordID: UUID?
    var note = ""
}

/// Read-only projection supplied by the App composition layer. Stocks never
/// depends on CurrencyExchange's Store or concrete domain model.
struct StockExchangeRecordSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let exchangedAt: Date
    let soldCurrency: CurrencyCode
    let boughtCurrency: CurrencyCode
    let soldAmount: Decimal
    let boughtAmount: Decimal
    let fee: Decimal
}

struct StockCashLedgerSnapshot: Equatable, Sendable {
    var balances: [CurrencyCode: Decimal]
    var unresolvedExchangeRecordIDs: Set<UUID>

    var hasNegativeBalance: Bool { balances.values.contains { $0 < 0 } }
}

enum StockRenminbiValuation {
    /// 把当前时点的多币种余额按最新现汇买入价折成人民币。负余额同样需要折算：它可能
    /// 来自外币汇款手续费或资金损耗，是期末净资产的真实减项，不代表缺少历史汇率。
    static func total(
        values: [CurrencyCode: Decimal],
        buyingRates: [CurrencyCode: Decimal]
    ) -> Decimal? {
        var total = Decimal.zero
        for (currency, value) in values where value != 0 {
            if currency == .cny {
                total += value
            } else {
                guard let rate = buyingRates[currency] else { return nil }
                total += value * rate
            }
        }
        return total
    }
}

enum StockCashLedger {
    static func build(
        records: [StockCashFlowRecord],
        exchangeRecords: [StockExchangeRecordSnapshot],
        stocks: [StockHolding],
        asOf date: Date = Date()
    ) -> StockCashLedgerSnapshot {
        var balances: [CurrencyCode: Decimal] = [:]
        let exchangesByID = Dictionary(uniqueKeysWithValues: exchangeRecords.map { ($0.id, $0) })
        var appliedExchangeIDs = Set<UUID>()
        var unresolvedExchangeIDs = Set<UUID>()

        for record in records.sorted(by: recordOrder) where record.occurredAt <= date {
            switch record.kind {
            case .deposit:
                balances[record.currency, default: 0] += record.amount
            case .withdrawal, .transferLoss:
                balances[record.currency, default: 0] -= record.amount
            }

            guard record.kind == .deposit,
                  let exchangeID = record.linkedExchangeRecordID,
                  appliedExchangeIDs.insert(exchangeID).inserted else { continue }
            guard let exchange = exchangesByID[exchangeID] else {
                unresolvedExchangeIDs.insert(exchangeID)
                continue
            }
            guard exchange.exchangedAt <= date else { continue }
            balances[exchange.soldCurrency, default: 0] -= exchange.soldAmount + exchange.fee
            balances[exchange.boughtCurrency, default: 0] += exchange.boughtAmount
        }

        for stock in stocks {
            guard let currency = CurrencyCode(rawValue: stock.market.currencyCode) else { continue }
            for transaction in stock.transactions where transaction.tradedAt <= date {
                switch transaction.type {
                case .buy:
                    balances[currency, default: 0] -= transaction.buyTotalCost
                case .sell:
                    balances[currency, default: 0] += transaction.sellNetProceeds
                }
            }
            let calendar = StockChartSeriesProcessor.marketCalendar(stock.market)
            for dividend in stock.dividends where dividend.isReceived(asOf: date, calendar: calendar) {
                balances[currency, default: 0] += dividend.netAmount
            }
        }

        return StockCashLedgerSnapshot(
            balances: balances.filter { $0.value != 0 },
            unresolvedExchangeRecordIDs: unresolvedExchangeIDs
        )
    }

    private static func recordOrder(_ lhs: StockCashFlowRecord, _ rhs: StockCashFlowRecord) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct StockXIRRSnapshot: Equatable, Sendable {
    enum UnavailableReason: Equatable, Sendable {
        case noInvestment
        case missingRenminbiBasis(recordIDs: [UUID])
        case incompleteTerminalValue(
            missingQuoteSymbols: [String],
            missingRateCurrencies: [String],
            unresolvedExchangeCount: Int
        )
        case invalidCashFlow
    }

    let annualRate: Decimal?
    let investedRenminbi: Decimal
    let withdrawnRenminbi: Decimal
    let terminalValueRenminbi: Decimal?
    let unavailableReason: UnavailableReason?
}

/// 账户 XIRR 只把穿过投资资金池边界的现金流纳入计算。换汇、交易、分红和汇款损耗
/// 都是池内活动；它们已经反映在期末净资产中，重复作为现金流会把收益率算两次。
enum StockXIRRCalculator {
    private struct CashFlow {
        let date: Date
        let amount: Double
    }

    static func calculate(
        records: [StockCashFlowRecord],
        exchangeRecords: [StockExchangeRecordSnapshot] = [],
        terminalValueRenminbi: Decimal?,
        terminalValueUnavailableReason: StockXIRRSnapshot.UnavailableReason = .incompleteTerminalValue(
            missingQuoteSymbols: [],
            missingRateCurrencies: [],
            unresolvedExchangeCount: 0
        ),
        asOf date: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> StockXIRRSnapshot {
        let effectiveRecords = records.filter { $0.occurredAt <= date }
        let exchangesByID = Dictionary(uniqueKeysWithValues: exchangeRecords.map { ($0.id, $0) })
        let unsupported = effectiveRecords.filter {
            guard $0.kind == .deposit || $0.kind == .withdrawal else { return false }
            return renminbiAmount(for: $0, exchangesByID: exchangesByID) == nil
        }
        guard unsupported.isEmpty else {
            return StockXIRRSnapshot(
                annualRate: nil,
                investedRenminbi: renminbiTotal(
                    in: effectiveRecords,
                    kind: .deposit,
                    exchangesByID: exchangesByID
                ),
                withdrawnRenminbi: renminbiTotal(
                    in: effectiveRecords,
                    kind: .withdrawal,
                    exchangesByID: exchangesByID
                ),
                terminalValueRenminbi: terminalValueRenminbi,
                unavailableReason: .missingRenminbiBasis(recordIDs: unsupported.map(\.id))
            )
        }

        let invested = renminbiTotal(
            in: effectiveRecords,
            kind: .deposit,
            exchangesByID: exchangesByID
        )
        let withdrawn = renminbiTotal(
            in: effectiveRecords,
            kind: .withdrawal,
            exchangesByID: exchangesByID
        )
        guard invested > 0 else {
            return StockXIRRSnapshot(
                annualRate: nil,
                investedRenminbi: invested,
                withdrawnRenminbi: withdrawn,
                terminalValueRenminbi: terminalValueRenminbi,
                unavailableReason: .noInvestment
            )
        }
        guard let terminalValueRenminbi, terminalValueRenminbi >= 0 else {
            return StockXIRRSnapshot(
                annualRate: nil,
                investedRenminbi: invested,
                withdrawnRenminbi: withdrawn,
                terminalValueRenminbi: terminalValueRenminbi,
                unavailableReason: terminalValueUnavailableReason
            )
        }

        var flows = effectiveRecords.compactMap { record -> CashFlow? in
            guard let amount = renminbiAmount(for: record, exchangesByID: exchangesByID) else {
                return nil
            }
            switch record.kind {
            case .deposit:
                return CashFlow(date: record.occurredAt, amount: -double(amount))
            case .withdrawal:
                return CashFlow(date: record.occurredAt, amount: double(amount))
            case .transferLoss:
                return nil
            }
        }
        flows.append(CashFlow(date: date, amount: double(terminalValueRenminbi)))
        flows = aggregateByDay(flows, calendar: calendar)

        guard flows.contains(where: { $0.amount < 0 }),
              flows.contains(where: { $0.amount > 0 }),
              let annualRate = solve(flows: flows, calendar: calendar) else {
            return StockXIRRSnapshot(
                annualRate: nil,
                investedRenminbi: invested,
                withdrawnRenminbi: withdrawn,
                terminalValueRenminbi: terminalValueRenminbi,
                unavailableReason: .invalidCashFlow
            )
        }
        return StockXIRRSnapshot(
            annualRate: Decimal(annualRate),
            investedRenminbi: invested,
            withdrawnRenminbi: withdrawn,
            terminalValueRenminbi: terminalValueRenminbi,
            unavailableReason: nil
        )
    }

    private static func renminbiTotal(
        in records: [StockCashFlowRecord],
        kind: StockCashFlowKind,
        exchangesByID: [UUID: StockExchangeRecordSnapshot]
    ) -> Decimal {
        records.reduce(into: Decimal.zero) { result, record in
            guard record.kind == kind,
                  let amount = renminbiAmount(for: record, exchangesByID: exchangesByID) else { return }
            result += amount
        }
    }

    private static func renminbiAmount(
        for record: StockCashFlowRecord,
        exchangesByID: [UUID: StockExchangeRecordSnapshot]
    ) -> Decimal? {
        if record.currency == .cny { return record.amount }
        guard record.kind == .deposit,
              let exchangeID = record.linkedExchangeRecordID,
              let exchange = exchangesByID[exchangeID],
              exchange.soldCurrency == .cny else { return nil }
        // 兼容早期把关联入金保存成买入币种的记录；真实人民币投入始终来自换汇原始事实。
        return exchange.soldAmount + exchange.fee
    }

    private static func aggregateByDay(_ flows: [CashFlow], calendar: Calendar) -> [CashFlow] {
        Dictionary(grouping: flows) { calendar.startOfDay(for: $0.date) }
            .map { CashFlow(date: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
            .filter { abs($0.amount) > 0.000_000_1 }
            .sorted { $0.date < $1.date }
    }

    private static func solve(flows: [CashFlow], calendar: Calendar) -> Double? {
        guard let firstDate = flows.first?.date,
              let lastDate = flows.last?.date,
              lastDate > firstDate else { return nil }
        let years = flows.map {
            max(0, $0.date.timeIntervalSince(firstDate) / (365 * 24 * 60 * 60))
        }
        func npv(_ rate: Double) -> Double {
            guard rate > -1 else { return .nan }
            return zip(flows, years).reduce(0) { partial, pair in
                partial + pair.0.amount / pow(1 + rate, pair.1)
            }
        }

        // Typical investment cash flows are monotonic. Bracketing plus bisection is deliberately
        // used instead of Newton alone so a valid result is not lost near -100% or at high returns.
        var lower = -0.999_999
        var upper = 1.0
        var lowerValue = npv(lower)
        var upperValue = npv(upper)
        while lowerValue.isFinite, upperValue.isFinite,
              lowerValue.sign == upperValue.sign, upper < 1_000_000 {
            upper = upper * 2 + 1
            upperValue = npv(upper)
        }
        guard lowerValue.isFinite, upperValue.isFinite,
              lowerValue.sign != upperValue.sign else { return nil }

        for _ in 0..<160 {
            let middle = (lower + upper) / 2
            let middleValue = npv(middle)
            guard middleValue.isFinite else { return nil }
            if abs(middleValue) < 0.000_001 { return middle }
            if middleValue.sign == lowerValue.sign {
                lower = middle
                lowerValue = middleValue
            } else {
                upper = middle
                upperValue = middleValue
            }
        }
        return (lower + upper) / 2
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
#endif
