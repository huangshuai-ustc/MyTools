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
            multipliers: renminbiMultipliers,
            extendedHours: store.extendedHoursPerformance
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
            headline

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
                                stocks: summaryStocks,
                                extendedHours: store.extendedHoursPerformance
                            ),
                            allocation: allocations.marketShare(for: market),
                            showsAllocation: marketFilter.market == nil
                        )
                    }
                }
            }
        }
        .alert("人民币合计说明", isPresented: $showingConversionInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(conversionInfoText)
        }
    }

    /// 标题行不放进展开按钮里：折算说明是独立按钮，嵌套在另一个按钮里点击判定不可靠。
    /// 展开/收起由 chevron 按钮和下面那行大字各自触发。
    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("净清算价值")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Text("CNY")
                    .appFont(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                conversionInfoButton
                Spacer(minLength: 4)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起明细" : "展开明细")
            }

            Button {
                isExpanded.toggle()
            } label: {
                valueRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headlineAccessibilityLabel)
            .accessibilityHint(isExpanded ? "收起明细" : "展开明细")
        }
    }

    /// `Label` 会在图标和文字之间塞一段固定间距，这里要紧挨着，所以手写 `HStack`。
    private var conversionInfoButton: some View {
        Button {
            showingConversionInfo = true
        } label: {
            HStack(spacing: 1) {
                Image(systemName: "exclamationmark.circle")
                Text("人民币折算说明")
            }
            .appFont(.caption2)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("人民币合计说明")
    }

    private var valueRow: some View {
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
        .contentShape(Rectangle())
    }

    private var headlineAccessibilityLabel: String {
        let today = signedMoneyText(convertedSummary.todayProfitLoss)
        let rate = convertedSummary.todayChangeRate.map(StockValueFormatter.signedPercent) ?? "--"
        return "净清算价值 \(moneyText(convertedSummary.marketValue)) 人民币，当日盈亏 \(today)，\(rate)"
    }

    /// 常驻的大字已经给出净清算价值和当日盈亏，所以这一格只补三项累计指标，避免同一
    /// 个数字出现两次。三列与下方每个市场的概况块同宽同形，「持仓总盈亏」的「总」也
    /// 是用来区分它和分市场那一列的：这里是全部市场折算后的合计。
    ///
    /// 三项之间是加法关系：持仓总盈亏（未落袋）+ 已实现收益（卖出盈亏与净分红）
    /// = 累计总收益。
    private var metricsGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                overviewMetric(
                    "持仓总盈亏",
                    value: signedMoneyText(convertedSummary.holdingProfitLoss),
                    color: profitLossColor(convertedSummary.holdingProfitLoss)
                )
                overviewMetric(
                    "已实现收益",
                    value: signedMoneyText(convertedSummary.realizedProfitLoss),
                    color: profitLossColor(convertedSummary.realizedProfitLoss)
                )
                overviewMetric(
                    "累计总收益",
                    value: signedMoneyText(convertedSummary.totalProfitLoss),
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
                .minimumScaleFactor(0.62)
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
        return StockValueFormatter.signedMoney(value, currencyCode: summary.market.currencyCode)
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
        return StockValueFormatter.signedMoney(
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
