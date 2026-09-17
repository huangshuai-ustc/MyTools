#if MYTOOLS_FEATURE_PARTNERSHIP
import Foundation

enum PartnershipBookType: String, Codable, CaseIterable, Identifiable, Sendable {
    case stockInvestment
    var id: Self { self }
    var title: String { "股票投资" }
}

/// The book is USD-only for now. The enum keeps A 股 / 港股 cases so historical
/// data still decodes and the market dimension can be reopened later, but only
/// `unitedStates` is offered in the UI.
enum PartnershipStockMarket: String, Codable, CaseIterable, Identifiable, Sendable {
    case unitedStates, aShare, hongKong
    var id: Self { self }
    var title: String {
        switch self {
        case .unitedStates: "美股"
        case .aShare: "A 股"
        case .hongKong: "港股"
        }
    }
    /// Markets currently offered when creating records. USD-only today.
    static var selectableCases: [Self] { [.unitedStates] }
}

/// Every monetary value in a book is recorded in this single currency.
let partnershipCurrency: CurrencyCode = .usd

struct PartnershipMember: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isManager = false
}

struct PartnershipAllocation: Codable, Equatable, Sendable {
    var memberID: UUID
    var base: Decimal
    var adjustment: Decimal
    var actual: Decimal
}

/// Cash direction of a record, used for list presentation (点1: 收入 / 支出).
enum PartnershipCashDirection: String, Codable, Sendable {
    case income      // 增加账户资金
    case expense     // 消耗账户资金
    case `internal`  // 账户内部转移（清账重投）
}
/// The single record type. A fat struct with a `kind` discriminator keeps
/// Codable stable and lets old three-stream data migrate into one array.
enum PartnershipRecordKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case contribution   // 注资
    case withdrawal     // 个人取出
    case buy            // 买入
    case sell           // 卖出
    case dividend       // 股息
    case settlement     // 清账（分配收益池）

    var id: Self { self }
    var title: String {
        switch self {
        case .contribution: "注资"
        case .withdrawal: "个人取出"
        case .buy: "买入"
        case .sell: "卖出"
        case .dividend: "股息"
        case .settlement: "清账"
        }
    }
    /// The cash direction for simple kinds. `settlement` is mixed per member and
    /// is presented separately.
    var direction: PartnershipCashDirection {
        switch self {
        case .contribution, .sell, .dividend: .income
        case .withdrawal, .buy: .expense
        case .settlement: .internal
        }
    }
}

enum PartnershipStockTradeSide: String, Codable, Sendable {
    case buy, sell
}

struct PartnershipSaleMatch: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var purchaseID: UUID
    var shares: Decimal
}

/// One member's choice when a settlement (清账) distributes their profit pool.
struct PartnershipSettlementChoice: Codable, Equatable, Sendable {
    var memberID: UUID
    /// Pool balance moved for this member. Negative means an absorbed loss.
    var amount: Decimal
    /// true → 重投 (pool → available cash); false → 取回 (pool → withdrawn).
    var reinvest: Bool
}

struct PartnershipAuditEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var action: String
    var affectedRecordID: UUID? = nil
}
struct PartnershipRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: PartnershipRecordKind
    var date = Date()
    var recordedAt: Date? = Date()
    /// Records created by one user action share an operation ID so undo is atomic.
    var operationID: UUID? = nil
    /// Headline amount (contribution/withdrawal amount; unused for computed trades).
    var amount: Decimal = 0
    var note = ""

    // Member-scoped records (contribution / withdrawal).
    var memberID: UUID? = nil

    // Trade records (buy / sell).
    /// Sell records point to their purchase, mirroring a follow-up hierarchy.
    var parentRecordID: UUID? = nil
    var market: PartnershipStockMarket? = nil
    var symbol: String = ""
    var name: String = ""
    var shares: Decimal = 0
    var price: Decimal = 0
    var fee: Decimal = 0
    var saleMatches: [PartnershipSaleMatch] = []

    // Dividend records.
    var grossAmount: Decimal = 0
    var withholdingTax: Decimal = 0

    /// Frozen member shares:
    ///  - buy: cost shares (actual sums to `cashAmount`)
    ///  - sell: profit-pool shares after the manager 5% adjustment
    ///  - dividend: net ownership shares
    var allocations: [PartnershipAllocation] = []

    // Settlement (清账) records.
    var settlementChoices: [PartnershipSettlementChoice] = []

    var effectiveMarket: PartnershipStockMarket { market ?? .unitedStates }
    var isPurchase: Bool { kind == .buy && parentRecordID == nil }
    var isSale: Bool { kind == .sell }

    /// All cash movements reuse the same cent-rounded amount frozen in member
    /// allocations. Shares may be fractional, but cash must reconcile.
    var tradeGross: Decimal { PartnershipCalculator.money(shares * price) }
    var cashAmount: Decimal {
        PartnershipCalculator.money(kind == .buy ? tradeGross + fee : tradeGross - fee)
    }
    var dividendNet: Decimal { PartnershipCalculator.money(grossAmount - withholdingTax - fee) }
}
/// One ledger is the atomic persistence / cloud record, including its frozen
/// allocations and its append-only audit log.
struct PartnershipBook: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var type: PartnershipBookType = .stockInvestment
    var adjustmentRate: Decimal = Decimal(5) / 100
    var members: [PartnershipMember]
    var records: [PartnershipRecord] = []
    var auditLog: [PartnershipAuditEntry] = []

    var currency: CurrencyCode { partnershipCurrency }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, adjustmentRate, members, records, auditLog
    }

    init(
        id: UUID = UUID(),
        name: String,
        type: PartnershipBookType = .stockInvestment,
        adjustmentRate: Decimal = Decimal(5) / 100,
        members: [PartnershipMember],
        records: [PartnershipRecord] = [],
        auditLog: [PartnershipAuditEntry] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.adjustmentRate = adjustmentRate
        self.members = members
        self.records = records
        self.auditLog = auditLog
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(PartnershipBookType.self, forKey: .type) ?? .stockInvestment
        adjustmentRate = try container.decodeIfPresent(Decimal.self, forKey: .adjustmentRate) ?? Decimal(5) / 100
        members = try container.decode([PartnershipMember].self, forKey: .members)
        auditLog = try container.decodeIfPresent([PartnershipAuditEntry].self, forKey: .auditLog) ?? []
        if let records = try container.decodeIfPresent([PartnershipRecord].self, forKey: .records) {
            self.records = records
        } else {
            self.records = try PartnershipLegacyMigration.records(from: decoder)
        }
    }
}
/// Decodes the pre-unification three streams (entries / stockTrades / dividends)
/// into one ordered `records` array. Contribution, withdrawal, buy, sell and
/// dividend map directly; the old net-value bookkeeping kinds (settlement /
/// valuation) are dropped, and the old profit-settlement maps to a reinvesting
/// 清账 record. This feature shipped hidden with no production data, so the
/// migration exists to decode old JSON without loss of the surviving flows.
enum PartnershipLegacyMigration {
    private enum LegacyKeys: String, CodingKey {
        case entries, stockTrades, dividends
    }
    private struct LegacyAllocation: Decodable {
        var memberID: UUID
        var base: Decimal
        var adjustment: Decimal
        var actual: Decimal
    }
    private struct LegacyEntry: Decodable {
        var id: UUID?
        var kind: String
        var date: Date?
        var recordedAt: Date?
        var amount: Decimal
        var memberID: UUID?
        var note: String?
        var allocations: [LegacyAllocation]?
    }
    private struct LegacyTrade: Decodable {
        var id: UUID?
        var parentRecordID: UUID?
        var operationID: UUID?
        var side: PartnershipStockTradeSide
        var date: Date?
        var recordedAt: Date?
        var market: PartnershipStockMarket?
        var symbol: String
        var name: String
        var shares: Decimal
        var price: Decimal
        var fee: Decimal?
        var allocations: [LegacyAllocation]?
        var saleMatches: [PartnershipSaleMatch]?
        var note: String?
    }
    private struct LegacyDividend: Decodable {
        var id: UUID?
        var date: Date?
        var recordedAt: Date?
        var market: PartnershipStockMarket
        var symbol: String
        var name: String
        var grossAmount: Decimal
        var withholdingTax: Decimal?
        var fee: Decimal?
        var allocations: [LegacyAllocation]?
        var note: String?
    }

    private static func map(_ allocations: [LegacyAllocation]?) -> [PartnershipAllocation] {
        (allocations ?? []).map { .init(memberID: $0.memberID, base: $0.base, adjustment: $0.adjustment, actual: $0.actual) }
    }

    static func records(from decoder: Decoder) throws -> [PartnershipRecord] {
        let container = try decoder.container(keyedBy: LegacyKeys.self)
        let entries = try container.decodeIfPresent([LegacyEntry].self, forKey: .entries) ?? []
        let trades = try container.decodeIfPresent([LegacyTrade].self, forKey: .stockTrades) ?? []
        let dividends = try container.decodeIfPresent([LegacyDividend].self, forKey: .dividends) ?? []
        var result: [(sort: Date, record: PartnershipRecord)] = []

        for entry in entries {
            let date = entry.date ?? Date(timeIntervalSince1970: 0)
            let sort = entry.recordedAt ?? date
            switch entry.kind {
            case "contribution", "withdrawal":
                result.append((sort, PartnershipRecord(
                    id: entry.id ?? UUID(),
                    kind: entry.kind == "contribution" ? .contribution : .withdrawal,
                    date: date, recordedAt: entry.recordedAt, amount: entry.amount,
                    note: entry.note ?? "", memberID: entry.memberID
                )))
            case "profitSettlement":
                result.append((sort, PartnershipRecord(
                    id: entry.id ?? UUID(), kind: .settlement, date: date, recordedAt: entry.recordedAt,
                    note: entry.note ?? "",
                    settlementChoices: map(entry.allocations).map {
                        .init(memberID: $0.memberID, amount: $0.actual, reinvest: true)
                    }
                )))
            default:
                break // settlement / valuation net-value bookkeeping is removed
            }
        }
        for trade in trades {
            let date = trade.date ?? Date(timeIntervalSince1970: 0)
            let sort = trade.recordedAt ?? date
            result.append((sort, PartnershipRecord(
                id: trade.id ?? UUID(), kind: trade.side == .buy ? .buy : .sell,
                date: date, recordedAt: trade.recordedAt, operationID: trade.operationID,
                note: trade.note ?? "", parentRecordID: trade.parentRecordID,
                market: trade.market, symbol: trade.symbol, name: trade.name,
                shares: trade.shares, price: trade.price, fee: trade.fee ?? 0,
                saleMatches: trade.saleMatches ?? [], allocations: map(trade.allocations)
            )))
        }
        for dividend in dividends {
            let date = dividend.date ?? Date(timeIntervalSince1970: 0)
            let sort = dividend.recordedAt ?? date
            result.append((sort, PartnershipRecord(
                id: dividend.id ?? UUID(), kind: .dividend, date: date, recordedAt: dividend.recordedAt,
                note: dividend.note ?? "", market: dividend.market, symbol: dividend.symbol,
                name: dividend.name, fee: dividend.fee ?? 0, grossAmount: dividend.grossAmount,
                withholdingTax: dividend.withholdingTax ?? 0, allocations: map(dividend.allocations)
            )))
        }
        return result.sorted { $0.sort < $1.sort }.map(\.record)
    }
}
struct PartnershipStockPosition: Identifiable, Equatable {
    var id: String { symbol }
    var symbol: String
    var name: String
    var shares: Decimal
    var cost: Decimal
    var currency: CurrencyCode { partnershipCurrency }
}

struct PartnershipStockSummary: Equatable {
    /// Investable available cash (excludes the undistributed profit pool).
    var cash: Decimal
    var positions: [PartnershipStockPosition]
    var realizedProfit: Decimal
    /// Current available cash by member.
    var memberAvailableCash: [PartnershipAllocation]
    /// Undistributed profit pool by member (drives the 盈利分成 chart).
    var memberProfits: [PartnershipAllocation]
}

struct PartnershipPosition: Identifiable, Equatable {
    var id: UUID
    var name: String
    var isManager: Bool
    /// Member available cash.
    var capital: Decimal = 0
    /// Member profit pool (may be negative for an absorbed loss).
    var profit: Decimal = 0
    var equity: Decimal { capital + profit }
}

struct PartnershipSummary {
    var positions: [PartnershipPosition]
    var contributed: Decimal = 0
    var withdrawn: Decimal = 0
    var totalCapital: Decimal { positions.reduce(0) { $0 + $1.capital } }
    var pendingProfit: Decimal { positions.reduce(0) { $0 + $1.profit } }
}

enum PartnershipError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}
enum PartnershipCalculator {
    static func money(_ value: Decimal) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, 2, .bankers)
        return result
    }

    /// Replays every member's investable available cash. Contributions add;
    /// withdrawals subtract; buys freeze cost by available-cash ratio; sells
    /// return only the matched purchase **principal** (profit goes to the pool);
    /// settlement reinvestment moves pool money into available cash.
    static func memberAvailableCash(_ book: PartnershipBook) -> [PartnershipAllocation] {
        var balances = Dictionary(uniqueKeysWithValues: book.members.map { ($0.id, Decimal.zero) })
        for record in book.records {
            switch record.kind {
            case .contribution:
                if let memberID = record.memberID { balances[memberID, default: 0] += record.amount }
            case .withdrawal:
                if let memberID = record.memberID { balances[memberID, default: 0] -= record.amount }
            case .buy:
                for allocation in record.allocations {
                    balances[allocation.memberID, default: 0] -= allocation.actual
                }
            case .sell:
                for match in record.saleMatches {
                    guard let purchase = book.records.first(where: { $0.id == match.purchaseID }),
                          purchase.shares > 0 else { continue }
                    let ratio = match.shares / purchase.shares
                    for allocation in purchase.allocations {
                        // Frozen cost basis of the matched shares returns to available cash.
                        balances[allocation.memberID, default: 0] += allocation.actual * ratio
                    }
                }
            case .dividend:
                break // net dividend accrues to the profit pool, not available cash
            case .settlement:
                for choice in record.settlementChoices where choice.reinvest {
                    balances[choice.memberID, default: 0] += choice.amount
                }
            }
        }
        return book.members.map { member in
            let amount = money(balances[member.id, default: 0])
            return PartnershipAllocation(memberID: member.id, base: amount, adjustment: 0, actual: amount)
        }
    }

    /// Undistributed realized profit by member: realized sale profit + net
    /// dividends, minus whatever a settlement already distributed.
    static func memberProfitPool(_ book: PartnershipBook) -> [PartnershipAllocation] {
        var pool = Dictionary(uniqueKeysWithValues: book.members.map { ($0.id, Decimal.zero) })
        for record in book.records {
            switch record.kind {
            case .sell, .dividend:
                for allocation in record.allocations { pool[allocation.memberID, default: 0] += allocation.actual }
            case .settlement:
                for choice in record.settlementChoices { pool[choice.memberID, default: 0] -= choice.amount }
            case .contribution, .withdrawal, .buy:
                break
            }
        }
        return book.members.map { member in
            let amount = money(pool[member.id, default: 0])
            return PartnershipAllocation(memberID: member.id, base: amount, adjustment: 0, actual: amount)
        }
    }
    static func summary(_ book: PartnershipBook) -> PartnershipSummary {
        let available = memberAvailableCash(book)
        let pool = memberProfitPool(book)
        let positions = book.members.map { member in
            PartnershipPosition(
                id: member.id,
                name: member.name,
                isManager: member.isManager,
                capital: available.first { $0.memberID == member.id }?.actual ?? 0,
                profit: pool.first { $0.memberID == member.id }?.actual ?? 0
            )
        }
        let contributed = book.records.lazy.filter { $0.kind == .contribution }.reduce(Decimal.zero) { $0 + $1.amount }
        let withdrawn = book.records.lazy.filter { $0.kind == .withdrawal }.reduce(Decimal.zero) { $0 + $1.amount }
        return PartnershipSummary(positions: positions, contributed: contributed, withdrawn: withdrawn)
    }

    static func stockSummary(_ book: PartnershipBook) -> PartnershipStockSummary {
        let availableCash = memberAvailableCash(book)
        let cash = availableCash.reduce(Decimal.zero) { $0 + $1.actual }
        var positions: [String: PartnershipStockPosition] = [:]
        var realizedProfit: Decimal = 0
        for record in book.records {
            switch record.kind {
            case .buy:
                var position = positions[record.symbol] ?? .init(symbol: record.symbol, name: record.name, shares: 0, cost: 0)
                position.shares += record.shares
                position.cost += record.cashAmount
                positions[record.symbol] = position
            case .sell:
                realizedProfit += record.allocations.reduce(Decimal.zero) { $0 + $1.actual }
                for match in record.saleMatches {
                    guard let purchase = book.records.first(where: { $0.id == match.purchaseID }) else { continue }
                    var position = positions[purchase.symbol] ?? .init(symbol: purchase.symbol, name: purchase.name, shares: 0, cost: 0)
                    let ratio = purchase.shares > 0 ? match.shares / purchase.shares : 0
                    position.shares -= match.shares
                    position.cost -= purchase.cashAmount * ratio
                    positions[purchase.symbol] = position
                }
            case .dividend:
                realizedProfit += record.dividendNet
            case .contribution, .withdrawal, .settlement:
                break
            }
        }
        return .init(
            cash: money(cash),
            positions: positions.values.filter { $0.shares > 0 }.sorted { $0.symbol < $1.symbol },
            realizedProfit: money(realizedProfit),
            memberAvailableCash: availableCash,
            memberProfits: memberProfitPool(book)
        )
    }

    /// Splits `total` across members by their current available-cash ratio,
    /// rounding each share down and assigning the residual to the manager so
    /// the parts always sum to `total`. Used for proportional contributions.
    static func split(_ total: Decimal, book: PartnershipBook) throws -> [PartnershipAllocation] {
        try allocateByAvailableCash(total, book: book, message: "没有有效出资比例，请先注资。")
    }

    static func stockCostAllocations(_ total: Decimal, book: PartnershipBook) throws -> [PartnershipAllocation] {
        try allocateByAvailableCash(total, book: book, message: "没有有效资金比例，请先注资。")
    }

    private static func allocateByAvailableCash(_ total: Decimal, book: PartnershipBook, message: String) throws -> [PartnershipAllocation] {
        let availableCash = memberAvailableCash(book)
        let totalAvailableCash = availableCash.reduce(Decimal.zero) { $0 + $1.actual }
        guard totalAvailableCash > 0, let investor = book.members.first(where: \.isManager) else {
            throw PartnershipError.invalid(message)
        }
        var result: [PartnershipAllocation] = []
        var allocated: Decimal = 0
        for member in book.members where member.id != investor.id {
            let cash = availableCash.first { $0.memberID == member.id }?.actual ?? 0
            let raw = total * cash / totalAvailableCash
            var cents = raw * 100
            var whole = Decimal()
            NSDecimalRound(&whole, &cents, 0, .down)
            let amount = whole / 100
            result.append(.init(memberID: member.id, base: amount, adjustment: 0, actual: amount))
            allocated += amount
        }
        let investorAmount = total - allocated
        result.append(.init(memberID: investor.id, base: investorAmount, adjustment: 0, actual: investorAmount))
        return result
    }
    static func dividendAllocations(
        grossAmount: Decimal,
        deductions: Decimal,
        book: PartnershipBook,
        market: PartnershipStockMarket,
        symbol: String,
        date: Date
    ) throws -> [PartnershipAllocation] {
        var ownedShares = Dictionary(uniqueKeysWithValues: book.members.map { ($0.id, Decimal.zero) })
        let purchases = book.records.filter {
            $0.isPurchase && $0.effectiveMarket == market
                && $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame && $0.date <= date
        }
        for purchase in purchases {
            let sold = book.records.lazy
                .filter { $0.isSale && $0.date <= date }
                .flatMap(\.saleMatches)
                .filter { $0.purchaseID == purchase.id }
                .reduce(Decimal.zero) { $0 + $1.shares }
            let remaining = max(0, purchase.shares - sold)
            guard remaining > 0, purchase.shares > 0, purchase.cashAmount > 0 else { continue }
            for allocation in purchase.allocations {
                let ratio = allocation.actual / purchase.cashAmount
                ownedShares[allocation.memberID, default: 0] += remaining * ratio
            }
        }
        let total = ownedShares.values.reduce(Decimal.zero, +)
        guard total > 0 else { throw PartnershipError.invalid("除息日没有可分配的持仓。") }
        let recipients = book.members.filter { ownedShares[$0.id, default: 0] > 0 }
        var allocatedGross = Decimal.zero
        var allocatedDeductions = Decimal.zero
        var result: [PartnershipAllocation] = []
        for (index, member) in recipients.enumerated() {
            let isLast = index == recipients.indices.last
            let gross = isLast ? grossAmount - allocatedGross : money(grossAmount * ownedShares[member.id, default: 0] / total)
            let deduction = isLast ? deductions - allocatedDeductions : money(deductions * ownedShares[member.id, default: 0] / total)
            allocatedGross += gross
            allocatedDeductions += deduction
            result.append(.init(memberID: member.id, base: gross, adjustment: deduction, actual: gross - deduction))
        }
        return result
    }

    static func validAmount(_ amount: Decimal, allowNegative: Bool = false, allowZero: Bool = false) -> Bool {
        !amount.isNaN && abs(amount) <= Decimal(1_000_000_000_000 as Int64)
            && amount == money(amount) && (allowNegative || amount >= 0) && (allowZero || amount != 0)
    }

    static func validShareAmount(_ value: Decimal) -> Bool {
        guard value > 0, !value.isNaN else { return false }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 6, .plain)
        return rounded == value
    }
}
#endif







