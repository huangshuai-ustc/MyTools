#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

/// 组合总览：折叠态只给净清算价值与当日盈亏两个大字，展开后补齐四项汇总、
/// 各市场概况和折算说明。
///
/// 折算逻辑沿用原「人民币总览」：无论筛选哪个市场，合计一律按中国银行现汇
/// 买入价折成人民币，缺牌价时只提示待同步而不显示零值。
struct StockPortfolioOverviewRow: View {
    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let marketFilter: StockMarketFilter
    let summaryStocks: [StockHolding]
    let summaryMarkets: [StockMarket]
    let allocations: StockAllocationSnapshot
    /// Expanded by default: the market breakdown is the reason to open this row,
    /// and collapsing it hides the only place the per-market numbers live.
    @State private var isExpanded = true
    @State private var showingConversionInfo = false

    private var selectedStocks: [StockHolding] {
        store.stocks.filter {
            $0.hasPurchaseRecord && marketFilter.includes($0)
        }
    }

    private var convertedSummary: StockConvertedPortfolioSummary {
        StockConvertedPortfolioSummary(
            stocks: selectedStocks,
            multipliers: renminbiMultipliers
        )
    }

    private var renminbiMultipliers: [StockMarket: Decimal] {
        var result: [StockMarket: Decimal] = [.aShare: 1]
        if let rate = exchangeRateStore.renminbiBuyingRates[.hkd] {
            result[.hongKong] = rate
        }
        if let rate = exchangeRateStore.renminbiBuyingRates[.usd] {
            result[.unitedStates] = rate
        }
        return result
    }

    private var requiredForeignCurrencies: [CurrencyCode] {
        var result: [CurrencyCode] = []
        if marketFilter.market == .hongKong || selectedStocks.contains(where: { $0.market == .hongKong }) {
            result.append(.hkd)
        }
        if marketFilter.market == .unitedStates || selectedStocks.contains(where: { $0.market == .unitedStates }) {
            result.append(.usd)
        }
        return result
    }

    private var hasMissingRates: Bool {
        requiredForeignCurrencies.contains { exchangeRateStore.renminbiBuyingRates[$0] == nil }
    }

    private var missingRateText: String {
        let missing = requiredForeignCurrencies.filter {
            exchangeRateStore.renminbiBuyingRates[$0] == nil
        }
        guard !missing.isEmpty else { return "外币买入价待同步" }
        return "中国银行\(missing.map(\.title).joined(separator: "、"))现汇买入价待同步"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                headline
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headlineAccessibilityLabel)
            .accessibilityHint(isExpanded ? "收起明细" : "展开明细")

            if hasMissingRates {
                Label(missingRateText, systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }

            if isExpanded {
                Divider()
                if !hasMissingRates { metricsGrid }
                if !summaryMarkets.isEmpty {
                    ForEach(summaryMarkets) { market in
                        StockMarketSummaryRow(
                            summary: StockPortfolioSummary(
                                market: market,
                                stocks: summaryStocks
                            ),
                            allocation: allocations.marketShare(for: market),
                            showsAllocation: marketFilter.market == nil
                        )
                    }
                }
                Button {
                    showingConversionInfo = true
                } label: {
                    Label("人民币折算说明", systemImage: "exclamationmark.circle")
                        .appFont(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("人民币合计说明")
            }
        }
        .alert("人民币合计说明", isPresented: $showingConversionInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(conversionInfoText)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("净清算价值")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Text("CNY")
                    .appFont(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(moneyText(convertedSummary.marketValue))
                    .font(AppFontSpec.largeTitle.weight(.semibold).monospacedDigit().font(scale: fontScale))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("当日盈亏")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Text(signedMoneyText(convertedSummary.todayProfitLoss))
                            .font(AppFontSpec.headline.monospacedDigit().font(scale: fontScale))
                        Text(convertedSummary.todayChangeRate.map(StockValueFormatter.signedPercent) ?? "--")
                            .font(AppFontSpec.caption.monospacedDigit().font(scale: fontScale))
                            .opacity(0.75)
                    }
                    .foregroundStyle(profitLossColor(convertedSummary.todayProfitLoss))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .contentShape(Rectangle())
    }

    private var headlineAccessibilityLabel: String {
        let today = signedMoneyText(convertedSummary.todayProfitLoss)
        let rate = convertedSummary.todayChangeRate.map(StockValueFormatter.signedPercent) ?? "--"
        return "净清算价值 \(moneyText(convertedSummary.marketValue)) 人民币，当日盈亏 \(today)，\(rate)"
    }

    /// 折叠态的大字已经给出总资产（净清算价值）和今日盈亏，所以展开区只补两项它
    /// 没有的累计指标，避免同一个数字出现两次。
    private var metricsGrid: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                overviewMetric(
                    "持仓盈亏",
                    value: moneyText(convertedSummary.holdingProfitLoss),
                    color: profitLossColor(convertedSummary.holdingProfitLoss)
                )
                overviewMetric(
                    "累计总收益",
                    value: moneyText(convertedSummary.totalProfitLoss),
                    color: profitLossColor(convertedSummary.totalProfitLoss)
                )
            }
        }
    }

    private var conversionInfoText: String {
        if marketFilter.market == .aShare {
            return "A 股资产无需换汇。"
        }
        if requiredForeignCurrencies.isEmpty {
            return "当前没有需要折算的外币资产。"
        }

        var lines = requiredForeignCurrencies.compactMap { currency -> String? in
            guard let rate = exchangeRateStore.renminbiBuyingRates[currency] else { return nil }
            return "按中国银行\(currency.title)现汇买入价换算：1 \(currency.rawValue) = \(StockValueFormatter.exchangeRate(rate)) CNY"
        }
        let missingCurrencies = requiredForeignCurrencies.filter {
            exchangeRateStore.renminbiBuyingRates[$0] == nil
        }
        if !missingCurrencies.isEmpty {
            lines.append("\(missingCurrencies.map(\.title).joined(separator: "、"))牌价待同步。")
        }
        if let updatedAt = exchangeRateStore.updatedAt {
            lines.append("牌价时间：\(AppDateFormatter.dateTimeString(from: updatedAt))")
        }
        if let error = exchangeRateStore.error, !missingCurrencies.isEmpty {
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }

    private func overviewMetric(
        _ title: String,
        value: String,
        color: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func moneyText(_ value: Decimal?) -> String {
        guard let value else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(value, currencyCode: "CNY")
    }

    private func signedMoneyText(_ value: Decimal?) -> String {
        guard let value else { return "待同步" }
        return StockValueFormatter.signedMoney(value, currencyCode: "CNY")
    }

    private func profitLossColor(_ value: Decimal?) -> Color {
        guard let value else { return .secondary }
        let market = marketFilter.market ?? .aShare
        return StockTrendColor.color(
            for: value,
            market: market,
            settings: stockAppearanceSettings
        )
    }
}

/// 单个市场的概况块。原先是「市场概况」Section 的独立列表行，现在折叠进
/// `StockPortfolioOverviewRow` 的展开区，指标定义未变。
struct StockMarketSummaryRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let summary: StockPortfolioSummary
    let allocation: Decimal?
    let showsAllocation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            HStack {
                StockMarketBadge(market: summary.market)
                Text(positionSummaryText)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                HStack(spacing: 8) {
                    StockMarketSessionLabel(market: summary.market, usesCompactIcon: true)
                    Text(summary.market.currencyCode)
                        .appFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(horizontalSpacing: 12) {
                GridRow {
                    summaryMetric("市值", value: marketValueText)
                    summaryMetric("今日盈亏", value: todayProfitLossText, color: todayProfitLossColor)
                    summaryMetric("持仓盈亏", value: profitLossText, color: profitLossColor)
                }
            }
        }
    }

    private var positionSummaryText: String {
        let positionCount = "\(summary.openPositionCount) 只持仓"
        guard showsAllocation else { return positionCount }
        let allocationText = allocation.map(StockValueFormatter.allocationPercent) ?? "待同步"
        return "\(positionCount) · 占比 \(allocationText)"
    }

    private var marketValueText: String {
        guard !summary.hasMissingQuotes else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(
            summary.knownMarketValue,
            currencyCode: summary.market.currencyCode
        )
    }

    private var todayProfitLossText: String {
        guard let value = summary.todayProfitLoss else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(value, currencyCode: summary.market.currencyCode)
    }

    private var todayProfitLossColor: Color {
        guard let value = summary.todayProfitLoss else { return .secondary }
        return StockTrendColor.color(
            for: value,
            market: summary.market,
            settings: stockAppearanceSettings
        )
    }

    private var profitLossText: String {
        guard let profitLoss = summary.profitLoss else { return "待同步" }
        return StockValueFormatter.moneyMagnitude(
            profitLoss,
            currencyCode: summary.market.currencyCode
        )
    }

    private var profitLossColor: Color {
        guard let profitLoss = summary.profitLoss else { return .secondary }
        return StockTrendColor.color(
            for: profitLoss,
            market: summary.market,
            settings: stockAppearanceSettings
        )
    }

    private func summaryMetric(
        _ title: String,
        value: String,
        color: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#endif
