#if MYTOOLS_FEATURE_PARTNERSHIP
import Foundation

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

enum PartnershipEntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case contribution, withdrawal, settlement, valuation
    var id: Self { self }
    var title: String {
        switch self {
        case .contribution: "注资"
        case .withdrawal: "个人取出"
        case .settlement: "结算盈亏"
        case .valuation: "净值快照"
        }
    }
}

struct PartnershipEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: PartnershipEntryKind
    var date = Date()
    var amount: Decimal
    var memberID: UUID?
    var note = ""
    var allocations: [PartnershipAllocation] = []
    /// Capital redeemed on withdrawal; the remainder is withdrawn settled profit.
    var capitalRedeemed: Decimal = 0
}

/// One ledger is the atomic persistence / cloud record, including its frozen allocations.
struct PartnershipBook: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var currency: CurrencyCode = .cny
    var adjustmentRate: Decimal = Decimal(5) / 100
    var members: [PartnershipMember]
    var entries: [PartnershipEntry] = []
}

struct PartnershipPosition: Identifiable, Equatable {
    var id: UUID
    var name: String
    var isManager: Bool
    var capital: Decimal = 0
    var profit: Decimal = 0
    var equity: Decimal { capital + profit }
}

struct PartnershipSummary {
    var positions: [PartnershipPosition]
    var contributed: Decimal = 0
    var withdrawn: Decimal = 0
    var settledProfit: Decimal = 0
    var valuation: Decimal?
    var bookValue: Decimal { contributed - withdrawn + settledProfit }
    var netValue: Decimal { valuation ?? bookValue }
    var pendingProfit: Decimal { netValue - bookValue }
    var totalCapital: Decimal { positions.reduce(0) { $0 + $1.capital } }
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

    static func summary(_ book: PartnershipBook) -> PartnershipSummary {
        var result = PartnershipSummary(positions: book.members.map {
            PartnershipPosition(id: $0.id, name: $0.name, isManager: $0.isManager)
        })
        // Array order is authoritative, so same-time entries replay deterministically.
        for entry in book.entries {
            let index = result.positions.firstIndex { $0.id == entry.memberID }
            switch entry.kind {
            case .contribution:
                if let index { result.positions[index].capital += entry.amount }
                result.contributed += entry.amount
                if result.valuation != nil { result.valuation! += entry.amount }
            case .withdrawal:
                if let index {
                    result.positions[index].capital -= entry.capitalRedeemed
                    result.positions[index].profit -= entry.amount - entry.capitalRedeemed
                }
                result.withdrawn += entry.amount
                if result.valuation != nil { result.valuation! -= entry.amount }
            case .settlement:
                for allocation in entry.allocations {
                    if let i = result.positions.firstIndex(where: { $0.id == allocation.memberID }) {
                        result.positions[i].profit += allocation.actual
                    }
                }
                result.settledProfit += entry.amount
            case .valuation:
                result.valuation = entry.amount
            }
        }
        return result
    }

    static func split(_ total: Decimal, book: PartnershipBook, adjusted: Bool) throws -> [PartnershipAllocation] {
        let summary = summary(book)
        guard summary.totalCapital > 0,
              let manager = summary.positions.first(where: \.isManager) else {
            throw PartnershipError.invalid("没有有效出资比例，请先注资。")
        }
        var result: [PartnershipAllocation] = []
        var allocated: Decimal = 0
        var adjustments: Decimal = 0
        for position in summary.positions where position.id != manager.id {
            let raw = total * position.capital / summary.totalCapital
            var base = money(raw)
            if !adjusted {
                // Round contributions down so several one-cent shares cannot exceed total.
                var cents = raw * 100
                var whole = Decimal()
                NSDecimalRound(&whole, &cents, 0, .down)
                base = whole / 100
            }
            let adjustment = adjusted ? money(base * book.adjustmentRate) : 0
            result.append(.init(memberID: position.id, base: base, adjustment: adjustment, actual: base - adjustment))
            allocated += base
            adjustments += adjustment
        }
        // Assign rounding residual to the manager; all allocations sum exactly to total.
        result.append(.init(memberID: manager.id, base: total - allocated, adjustment: -adjustments, actual: total - allocated + adjustments))
        return result
    }

    static func validAmount(_ amount: Decimal, allowNegative: Bool = false, allowZero: Bool = false) -> Bool {
        !amount.isNaN && abs(amount) <= Decimal(1_000_000_000_000 as Int64)
            && amount == money(amount) && (allowNegative || amount >= 0) && (allowZero || amount != 0)
    }
}
#endif
