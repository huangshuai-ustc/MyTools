#if MYTOOLS_FEATURE_BILLS
import Foundation

struct BillAnalyticsSnapshot: Equatable, Sendable {
    let interval: DateInterval
    let currency: CurrencyCode
    let transactionCount: Int
    let neutralCount: Int
    let expense: Decimal
    let income: Decimal
    let refund: Decimal
    let dailyTotals: [BillDailyTotal]
    let categoryTotals: [BillCategoryTotal]
    let merchantTotals: [BillNamedTotal]
    let paymentMethodTotals: [BillNamedTotal]

    var netExpense: Decimal { expense - refund }
    var balance: Decimal { income + refund - expense }
}

struct BillDailyTotal: Identifiable, Equatable, Sendable {
    var id: Date { day }
    let day: Date
    let expense: Decimal
    let income: Decimal
    let refund: Decimal

    var netExpense: Decimal { expense - refund }
}

struct BillCategoryTotal: Identifiable, Equatable, Sendable {
    var id: BillCategory { category }
    let category: BillCategory
    let amount: Decimal
    let transactionCount: Int
}

struct BillNamedTotal: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let amount: Decimal
    let transactionCount: Int
}

enum BillAnalyticsCalculator {
    static func snapshot(
        records: [BillRecord],
        month: Date,
        currency: CurrencyCode,
        calendar: Calendar = .autoupdatingCurrent
    ) -> BillAnalyticsSnapshot {
        let interval = monthInterval(containing: month, calendar: calendar)
        let includedRecords = records.filter {
            $0.currency == currency
                && $0.status != .cancelled
                && interval.contains($0.occurredAt)
        }

        var expense: Decimal = 0
        var income: Decimal = 0
        var refund: Decimal = 0
        var neutralCount = 0
        var dailyValues: [Date: DirectionAmounts] = [:]
        var categoryValues: [BillCategory: Aggregate] = [:]
        var merchantValues: [String: Aggregate] = [:]
        var paymentMethodValues: [String: Aggregate] = [:]

        for record in includedRecords {
            let day = calendar.startOfDay(for: record.occurredAt)
            var daily = dailyValues[day, default: DirectionAmounts()]

            switch record.direction {
            case .expense:
                expense += record.amount
                daily.expense += record.amount
                if record.amount > 0 {
                    categoryValues[record.category, default: Aggregate()].add(record.amount)
                    merchantValues[merchantName(for: record), default: Aggregate()].add(record.amount)
                    paymentMethodValues[
                        normalizedName(record.paymentMethod, fallback: "未记录付款方式"),
                        default: Aggregate()
                    ].add(record.amount)
                }
            case .income:
                income += record.amount
                daily.income += record.amount
            case .refund:
                refund += record.amount
                daily.refund += record.amount
            case .neutral:
                neutralCount += 1
            }

            if record.direction != .neutral, record.amount > 0 {
                dailyValues[day] = daily
            }
        }

        return BillAnalyticsSnapshot(
            interval: interval,
            currency: currency,
            transactionCount: includedRecords.count,
            neutralCount: neutralCount,
            expense: expense,
            income: income,
            refund: refund,
            dailyTotals: dailyValues.map {
                BillDailyTotal(
                    day: $0.key,
                    expense: $0.value.expense,
                    income: $0.value.income,
                    refund: $0.value.refund
                )
            }.sorted { $0.day < $1.day },
            categoryTotals: categoryValues.map {
                BillCategoryTotal(
                    category: $0.key,
                    amount: $0.value.amount,
                    transactionCount: $0.value.count
                )
            }.sorted(by: rankedBefore),
            merchantTotals: namedTotals(from: merchantValues),
            paymentMethodTotals: namedTotals(from: paymentMethodValues)
        )
    }

    static func previousMonth(
        before month: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.date(byAdding: .month, value: -1, to: monthInterval(containing: month, calendar: calendar).start)
            ?? month
    }

    static func monthInterval(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval {
        calendar.dateInterval(of: .month, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 0)
    }

    private struct DirectionAmounts {
        var expense: Decimal = 0
        var income: Decimal = 0
        var refund: Decimal = 0
    }

    private struct Aggregate {
        var amount: Decimal = 0
        var count = 0

        mutating func add(_ value: Decimal) {
            amount += value
            count += 1
        }
    }

    private static func merchantName(for record: BillRecord) -> String {
        for candidate in [record.merchant, record.counterparty, record.itemDescription] {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return "未记录商户"
    }

    private static func normalizedName(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private static func namedTotals(from values: [String: Aggregate]) -> [BillNamedTotal] {
        values.map {
            BillNamedTotal(name: $0.key, amount: $0.value.amount, transactionCount: $0.value.count)
        }.sorted(by: rankedBefore)
    }

    private static func rankedBefore(_ lhs: BillCategoryTotal, _ rhs: BillCategoryTotal) -> Bool {
        if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
        return lhs.category.title.localizedStandardCompare(rhs.category.title) == .orderedAscending
    }

    private static func rankedBefore(_ lhs: BillNamedTotal, _ rhs: BillNamedTotal) -> Bool {
        if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

#endif
