#if MYTOOLS_FEATURE_BILLS
import Charts
import SwiftUI

private enum BillCalendarMode: String, CaseIterable, Identifiable {
    case anchor
    case range

    var id: Self { self }

    var title: String {
        switch self {
        case .anchor: return "选择某天"
        case .range: return "选择时间区间"
        }
    }
}

struct BillAnalysisView: View {
    @EnvironmentObject private var store: BillsStore
    @Binding var pageSelection: BillsPage
    @State private var period: BillAnalysisPeriod = .month
    @State private var anchorDate = Date()
    @State private var customStart = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var selectedCurrency: CurrencyCode = .cny
    @State private var showingDatePicker = false
    @State private var calendarMode: BillCalendarMode = .anchor
    @State private var refreshID = UUID()

    private var availableCurrencies: [CurrencyCode] {
        let currencies = Set(store.records.map(\.currency))
        return currencies.isEmpty
            ? [.cny]
            : currencies.sorted { $0.rawValue < $1.rawValue }
    }

    private var currency: CurrencyCode {
        availableCurrencies.contains(selectedCurrency) ? selectedCurrency : (availableCurrencies.first ?? .cny)
    }

    private var snapshot: BillAnalyticsSnapshot {
        _ = refreshID
        return BillAnalyticsCalculator.snapshot(records: store.records, interval: selectedInterval, currency: currency)
    }

    private var selectedInterval: DateInterval {
        switch period {
        case .custom:
            return BillAnalyticsCalculator.customInterval(start: customStart, end: customEnd)
        default:
            return BillAnalyticsCalculator.interval(for: period, containing: anchorDate)
        }
    }

    private var previousSnapshot: BillAnalyticsSnapshot? {
        guard let previousInterval = BillAnalyticsCalculator.previousInterval(
            before: selectedInterval,
            period: period
        ) else { return nil }
        return BillAnalyticsCalculator.snapshot(records: store.records, interval: previousInterval, currency: currency)
    }

    private var periodTitle: String {
        if period == .custom {
            return "\(customStart.formatted(date: .numeric, time: .omitted)) - \(customEnd.formatted(date: .numeric, time: .omitted))"
        }
        switch period {
        case .week:
            return "第 \(Calendar.autoupdatingCurrent.component(.weekOfYear, from: anchorDate)) 周"
        case .month:
            return anchorDate.formatted(.dateTime.year().month())
        case .quarter:
            let month = Calendar.autoupdatingCurrent.component(.month, from: anchorDate)
            let quarter = ((month - 1) / 3) + 1
            return "\(Calendar.autoupdatingCurrent.component(.year, from: anchorDate)) 年第 \(quarter) 季"
        case .year:
            return anchorDate.formatted(.dateTime.year())
        case .custom:
            return "自定义区间"
        }
    }

    private var overviewTitle: String {
        switch period {
        case .week: return "周度概览"
        case .month: return "月度概览"
        case .quarter: return "季度概览"
        case .year: return "年度概览"
        case .custom: return "区间概览"
        }
    }

    var body: some View {
        List {
            Section {
                BillsPagePicker(selection: $pageSelection)
            }

            Section {
                Picker("统计周期", selection: $period) {
                    ForEach(BillAnalysisPeriod.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { _, value in
                    calendarMode = value == .custom ? .range : .anchor
                    if value == .custom { showingDatePicker = true }
                    refresh()
                }
            }

            Section {
                periodSelector
            }

            if snapshot.transactionCount == 0 {
                ContentUnavailableView(
                    "当前周期暂无账单",
                    systemImage: "chart.bar.xaxis",
                    description: Text("请选择其他月份或币种。")
                )
            } else {
                overviewSection
                if previousSnapshot != nil { comparisonSection }
                dailySection
                categorySection
                merchantSection
                paymentMethodSection
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
        .onReceive(store.$records) { _ in refresh() }
        .refreshable { refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新分析")
                .accessibilityLabel("刷新分析")
            }
        }
        .sheet(isPresented: $showingDatePicker) {
            customDatePicker
                .iOSLargeSheet()
        }
    }

    private var periodSelector: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    moveMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("上个月")
                .accessibilityLabel("上个月")

                Text(periodTitle)
                    .appFont(.headline)
                    .frame(maxWidth: .infinity)

                Button {
                    moveMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("下个月")
                .accessibilityLabel("下个月")

                Button {
                    calendarMode = period == .custom ? .range : .anchor
                    showingDatePicker = true
                } label: {
                    Image(systemName: "calendar")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("选择日期或时间区间")
                .accessibilityLabel("选择日期或时间区间")
            }

            if availableCurrencies.count > 1 {
                HStack {
                    Text("币种")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("币种", selection: $selectedCurrency) {
                            ForEach(availableCurrencies) { currency in
                                Text(currency.rawValue).tag(currency)
                            }
                        }
                    } label: {
                        Label(currency.rawValue, systemImage: "coloncurrencysign.circle")
                    }
                    .help("选择币种")
                }
            }
        }
    }

    private var overviewSection: some View {
            Section(overviewTitle) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 16
            ) {
                metric("支出", value: snapshot.expense, color: .red)
                metric("净支出", value: snapshot.netExpense, color: .orange)
                metric("收入", value: snapshot.income, color: .green)
                metric("退款", value: snapshot.refund, color: .blue)
            }
            .padding(.vertical, 4)
            .appListRowStyle()

            LabeledContent("交易笔数", value: "\(snapshot.transactionCount)")
            if snapshot.neutralCount > 0 {
                LabeledContent("不计收支", value: "\(snapshot.neutralCount) 笔")
            }
            LabeledContent("月度结余") {
                Text(BillAnalysisFormatting.amount(snapshot.balance, currency: currency))
                    .foregroundStyle(snapshot.balance >= 0 ? Color.green : Color.red)
                    .monospacedDigit()
            }
        }
    }

    private var comparisonSection: some View {
        Section("月度对比") {
            Chart(comparisonPoints) { point in
                BarMark(
                    x: .value("月份", point.period),
                    y: .value("金额", point.value)
                )
                .position(by: .value("类型", point.kind))
                .foregroundStyle(by: .value("类型", point.kind))
                .accessibilityLabel("\(point.period)\(point.kind)")
                .accessibilityValue(BillAnalysisFormatting.amount(point.amount, currency: currency))
            }
            .chartForegroundStyleScale([
                "支出": Color.red,
                "收入": Color.green,
                "退款": Color.blue
            ])
            .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
            .frame(height: 220)
            .appListRowStyle()

            if let previousSnapshot {
                LabeledContent("支出较上周期", value: comparisonText(current: snapshot.expense, previous: previousSnapshot.expense))
                LabeledContent("净支出较上周期", value: comparisonText(current: snapshot.netExpense, previous: previousSnapshot.netExpense))
            }
        }
    }

    private var dailySection: some View {
        Section("每日支出") {
            Chart(snapshot.dailyTotals) { total in
                BarMark(
                    x: .value("日期", total.day, unit: .day),
                    y: .value("支出", BillAnalysisFormatting.double(total.expense))
                )
                .foregroundStyle(Color.red)
                .accessibilityLabel(total.day.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue(BillAnalysisFormatting.amount(total.expense, currency: currency))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .frame(height: 210)
            .appListRowStyle()
        }
    }

    private var categorySection: some View {
        Section("支出分类") {
            if snapshot.expense == 0 {
                    Text("当前周期没有支出")
                    .foregroundStyle(.secondary)
            } else {
                Chart(snapshot.categoryTotals) { total in
                    SectorMark(
                        angle: .value("金额", BillAnalysisFormatting.double(total.amount)),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(BillAnalysisFormatting.categoryColor(total.category))
                    .accessibilityLabel(total.category.title)
                    .accessibilityValue(BillAnalysisFormatting.amount(total.amount, currency: currency))
                }
                .chartLegend(.hidden)
                .frame(height: 230)
                .appListRowStyle()

                ForEach(snapshot.categoryTotals.prefix(8)) { total in
                    VStack(spacing: 4) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(BillAnalysisFormatting.categoryColor(total.category))
                                .frame(width: 9, height: 9)
                            Text(total.category.title)
                            Spacer()
                            Text(BillAnalysisFormatting.amount(total.amount, currency: currency))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("\(total.transactionCount) 笔")
                            Spacer()
                            Text(BillAnalysisFormatting.percentage(total.amount, of: snapshot.expense))
                                .monospacedDigit()
                        }
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var merchantSection: some View {
        Section("商户支出排行") {
            if snapshot.merchantTotals.isEmpty {
                Text("当前周期没有支出")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.merchantTotals.prefix(8)) { total in
                    BillRankingRow(
                        total: total,
                        maximum: snapshot.merchantTotals.first?.amount ?? 0,
                        currency: currency,
                        color: .orange
                    )
                }
            }
        }
    }

    private var paymentMethodSection: some View {
        Section("付款方式") {
            if snapshot.paymentMethodTotals.isEmpty {
                Text("当前周期没有支出")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.paymentMethodTotals.prefix(8)) { total in
                    BillRankingRow(
                        total: total,
                        maximum: snapshot.paymentMethodTotals.first?.amount ?? 0,
                        currency: currency,
                        color: .blue
                    )
                }
            }
        }
    }

    private var comparisonPoints: [BillMonthComparisonPoint] {
        guard let previousSnapshot else { return [] }
        return [
            BillMonthComparisonPoint(period: "上周期", kind: "支出", amount: previousSnapshot.expense),
            BillMonthComparisonPoint(period: "上周期", kind: "收入", amount: previousSnapshot.income),
            BillMonthComparisonPoint(period: "上周期", kind: "退款", amount: previousSnapshot.refund),
            BillMonthComparisonPoint(period: "当前", kind: "支出", amount: snapshot.expense),
            BillMonthComparisonPoint(period: "当前", kind: "收入", amount: snapshot.income),
            BillMonthComparisonPoint(period: "当前", kind: "退款", amount: snapshot.refund)
        ]
    }

    private func metric(_ title: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(BillAnalysisFormatting.amount(value, currency: currency))
                .appFont(.headline)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveMonth(by value: Int) {
        guard period != .custom else { return }
        anchorDate = BillAnalyticsCalculator.shiftedAnchor(anchorDate, period: period, by: value)
        refresh()
    }

    private var customDatePicker: some View {
        NavigationStack {
            Form {
                Picker("选择方式", selection: $calendarMode) {
                    ForEach(BillCalendarMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch calendarMode {
                case .anchor:
                    DatePicker("周期基准日", selection: $anchorDate, displayedComponents: .date)
                case .range:
                    DatePicker("开始日期", selection: $customStart, displayedComponents: .date)
                    DatePicker("结束日期", selection: $customEnd, displayedComponents: .date)
                }
            }
            .appNavigationTitle("选择分析时间")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if calendarMode == .range {
                            period = .custom
                        } else if period == .custom {
                            period = .month
                        }
                        showingDatePicker = false
                        refresh()
                    }
                }
            }
        }
    }

    private func refresh() {
        refreshID = UUID()
    }

    private func comparisonText(current: Decimal, previous: Decimal) -> String {
        guard previous != 0 else { return current == 0 ? "持平" : "无上一周期基数" }
        let change = (current - previous) / previous
        let value = BillAnalysisFormatting.percentage(change.magnitude, of: 1)
        if change > 0 { return "增加 \(value)" }
        if change < 0 { return "减少 \(value)" }
        return "持平"
    }

}

private struct BillRankingRow: View {
    let total: BillNamedTotal
    let maximum: Decimal
    let currency: CurrencyCode
    let color: Color

    private var fraction: Double {
        guard maximum > 0 else { return 0 }
        return min(1, BillAnalysisFormatting.double(total.amount / maximum))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(total.name)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(BillAnalysisFormatting.amount(total.amount, currency: currency))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text("\(total.transactionCount) 笔")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total.name)，\(total.transactionCount) 笔")
        .accessibilityValue(BillAnalysisFormatting.amount(total.amount, currency: currency))
    }
}

private struct BillMonthComparisonPoint: Identifiable {
    var id: String { "\(period)-\(kind)" }
    let period: String
    let kind: String
    let amount: Decimal
    var value: Double { BillAnalysisFormatting.double(amount) }
}

private enum BillAnalysisFormatting {
    static func amount(_ amount: Decimal, currency: CurrencyCode) -> String {
        BillPresentation.amount(amount, currency: currency)
    }

    static func double(_ amount: Decimal) -> Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }

    static func percentage(_ value: Decimal, of total: Decimal) -> String {
        guard total != 0 else { return "0%" }
        return ((double(value) / double(total)) * 100).formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    static func categoryColor(_ category: BillCategory) -> Color {
        switch category {
        case .dining: return .orange
        case .groceries: return .green
        case .transport: return .blue
        case .shopping: return .pink
        case .housing: return .brown
        case .utilities: return .teal
        case .medical: return .red
        case .education: return .indigo
        case .travel: return .cyan
        case .entertainment: return .purple
        case .transfer: return .gray
        case .salary: return .mint
        case .refund: return .blue
        case .other: return .secondary
        }
    }
}

#endif
