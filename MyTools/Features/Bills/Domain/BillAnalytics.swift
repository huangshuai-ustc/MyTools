#if MYTOOLS_FEATURE_BILLS
import Foundation

enum BillAnalysisPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case quarter
    case year
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .week: return "周"
        case .month: return "月"
        case .quarter: return "季"
        case .year: return "年"
        case .custom: return "自定义"
        }
    }
}

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
        interval: DateInterval,
        currency: CurrencyCode,
        calendar: Calendar = .autoupdatingCurrent
    ) -> BillAnalyticsSnapshot {
        makeSnapshot(records: records, interval: interval, currency: currency, calendar: calendar)
    }

    static func snapshot(
        records: [BillRecord],
        month: Date,
        currency: CurrencyCode,
        calendar: Calendar = .autoupdatingCurrent
    ) -> BillAnalyticsSnapshot {
        let interval = monthInterval(containing: month, calendar: calendar)
        return makeSnapshot(records: records, interval: interval, currency: currency, calendar: calendar)
    }

    static func interval(
        for period: BillAnalysisPeriod,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval {
        switch period {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)
                ?? fallbackInterval(containing: date, calendar: calendar)
        case .month:
            return monthInterval(containing: date, calendar: calendar)
        case .quarter:
            let components = calendar.dateComponents([.year, .month], from: date)
            let month = components.month ?? 1
            let startMonth = ((month - 1) / 3) * 3 + 1
            var startComponents = DateComponents()
            startComponents.year = components.year
            startComponents.month = startMonth
            startComponents.day = 1
            let start = calendar.date(from: startComponents) ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .month, value: 3, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .year:
            return calendar.dateInterval(of: .year, for: date)
                ?? fallbackInterval(containing: date, calendar: calendar)
        case .custom:
            return fallbackInterval(containing: date, calendar: calendar)
        }
    }

    static func customInterval(
        start: Date,
        end: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval {
        let startDay = calendar.startOfDay(for: min(start, end))
        let endDay = calendar.startOfDay(for: max(start, end))
        let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return DateInterval(start: startDay, end: exclusiveEnd)
    }

    static func previousInterval(
        before interval: DateInterval,
        period: BillAnalysisPeriod,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval? {
        let component: Calendar.Component
        let value: Int
        switch period {
        case .week:
            component = .weekOfYear
            value = -1
        case .month:
            component = .month
            value = -1
        case .quarter:
            component = .month
            value = -3
        case .year:
            component = .year
            value = -1
        case .custom:
            return nil
        }
        guard let start = calendar.date(byAdding: component, value: value, to: interval.start),
              let end = calendar.date(byAdding: component, value: value, to: interval.end) else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    static func shiftedAnchor(
        _ anchor: Date,
        period: BillAnalysisPeriod,
        by offset: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let component: Calendar.Component
        let value: Int
        switch period {
        case .week:
            component = .weekOfYear
            value = offset
        case .month:
            component = .month
            value = offset
        case .quarter:
            component = .month
            value = offset * 3
        case .year:
            component = .year
            value = offset
        case .custom:
            return anchor
        }
        return calendar.date(byAdding: component, value: value, to: anchor) ?? anchor
    }

    private static func makeSnapshot(
        records: [BillRecord],
        interval: DateInterval,
        currency: CurrencyCode,
        calendar: Calendar
    ) -> BillAnalyticsSnapshot {
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
            ?? fallbackInterval(containing: date, calendar: calendar)
    }

    private static func fallbackInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
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
