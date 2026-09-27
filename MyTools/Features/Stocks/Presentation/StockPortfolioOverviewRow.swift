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
    @State private var isExpanded = false
    @State private var showingConversionInfo = false

    private var selectedStocks: [StockHolding] {
        store.stocks.filter {
            $0.hasPurchaseRecord && marketFilter.includes($0)
        }
    }

    private func convertedSummary(for stocks: [StockHolding]) -> StockConvertedPortfolioSummary {
        StockConvertedPortfolioSummary(
            stocks: stocks,
            multipliers: usesRenminbi ? renminbiMultipliers : marketFilter.market.map { [$0: Decimal(1)] } ?? renminbiMultipliers,
            extendedHours: store.extendedHoursPerformance,
            performances: store.performances(for: stocks)
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

    private func requiredForeignCurrencies(in stocks: [StockHolding]) -> [CurrencyCode] {
        guard usesRenminbi else { return [] }
        var result: [CurrencyCode] = []
        if marketFilter.market == .hongKong || stocks.contains(where: { $0.market == .hongKong }) {
            result.append(.hkd)
        }
        if marketFilter.market == .unitedStates || stocks.contains(where: { $0.market == .unitedStates }) {
            result.append(.usd)
        }
        return result
    }

    private func missingRateText(_ missing: [CurrencyCode]) -> String {
        guard !missing.isEmpty else { return "外币买入价待同步" }
        return "中国银行\(missing.map(\.title).joined(separator: "、"))现汇买入价待同步"
    }

    var body: some View {
        // `selectedStocks` 的过滤条件 `hasPurchaseRecord` 要回放一遍交易，
        // `convertedSummary` 更是要把每只股票都回放一遍。两者原先都是零缓存的计算属性，
        // 一次 body 里被读十几次（总览三格 + 大字 + 无障碍标签 + 折算说明）。导航转场中
        // UIKit 会反复同步布局，这个常数倍足以把一次渲染推到几百毫秒——2026-09-22 那次
        // scene-update 看门狗崩溃就是这么被喂饱的。这里一次算好往下传。
        let selection = selectedStocks
        let foreignCurrencies = requiredForeignCurrencies(in: selection)
        let missingCurrencies = foreignCurrencies.filter {
            exchangeRateStore.renminbiBuyingRates[$0] == nil
        }
        let summary = convertedSummary(for: selection)

        VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing(fontScale: fontScale)) {
            headline(summary: summary)

            if !missingCurrencies.isEmpty {
                Label(missingRateText(missingCurrencies), systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }

            if isExpanded {
                Divider()
                if missingCurrencies.isEmpty { metricsGrid(summary: summary) }
                if !summaryMarkets.isEmpty {
                    ForEach(summaryMarkets) { market in
                        StockMarketSummaryRow(
                            summary: StockPortfolioSummary(
                                market: market,
                                stocks: summaryStocks,
                                extendedHours: store.extendedHoursPerformance,
                                performances: store.performances(for: summaryStocks)
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
            Text(conversionInfoText(foreignCurrencies: foreignCurrencies, missing: missingCurrencies))
        }
    }

    /// 标题行不放进展开按钮里：折算说明是独立按钮，嵌套在另一个按钮里点击判定不可靠。
    /// 展开/收起由 chevron 按钮和下面那行大字各自触发。
    private func headline(summary: StockConvertedPortfolioSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("持仓市值")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Text(displayCurrencyCode)
                    .appFont(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if usesRenminbi { conversionInfoButton }
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
                valueRow(summary: summary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headlineAccessibilityLabel(summary: summary))
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

    private func valueRow(summary: StockConvertedPortfolioSummary) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(moneyText(summary.marketValue))
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
                    Text(signedMoneyText(summary.todayProfitLoss))
                        .font(AppFontSpec.headline.monospacedDigit().font(scale: fontScale))
                    Text(summary.todayChangeRate.map(StockValueFormatter.signedPercent) ?? "--")
                        .font(AppFontSpec.caption.monospacedDigit().font(scale: fontScale))
                        .opacity(0.75)
                }
                .foregroundStyle(profitLossColor(summary.todayProfitLoss))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .contentShape(Rectangle())
    }

    private func headlineAccessibilityLabel(summary: StockConvertedPortfolioSummary) -> String {
        let today = signedMoneyText(summary.todayProfitLoss)
        let rate = summary.todayChangeRate.map(StockValueFormatter.signedPercent) ?? "--"
        return "持仓市值 \(moneyText(summary.marketValue)) \(displayCurrencyCode)，当日盈亏 \(today)，\(rate)"
    }

    /// 常驻的大字已经给出净清算价值和当日盈亏，所以这一格只补三项累计指标，避免同一
    /// 个数字出现两次。三列与下方每个市场的概况块同宽同形，「持仓总盈亏」的「总」也
    /// 是用来区分它和分市场那一列的：这里是全部市场折算后的合计。
    ///
    /// 三项之间是加法关系：持仓总盈亏（未落袋）+ 已实现收益（卖出盈亏与净分红）
    /// = 累计总收益。
    private func metricsGrid(summary: StockConvertedPortfolioSummary) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                overviewMetric(
                    "持仓总盈亏",
                    value: signedMoneyText(summary.holdingProfitLoss),
                    color: profitLossColor(summary.holdingProfitLoss)
                )
                overviewMetric(
                    "已实现收益",
                    value: signedMoneyText(summary.realizedProfitLoss),
                    color: profitLossColor(summary.realizedProfitLoss)
                )
                overviewMetric(
                    "累计总收益",
                    value: signedMoneyText(summary.totalProfitLoss),
                    color: profitLossColor(summary.totalProfitLoss)
                )
            }
        }
    }

    private func conversionInfoText(
        foreignCurrencies: [CurrencyCode],
        missing missingCurrencies: [CurrencyCode]
    ) -> String {
        if marketFilter.market == .aShare {
            return "A 股资产无需换汇。"
        }
        if foreignCurrencies.isEmpty {
            return "当前没有需要折算的外币资产。"
        }

        var lines = foreignCurrencies.compactMap { currency -> String? in
            guard let rate = exchangeRateStore.renminbiBuyingRates[currency] else { return nil }
            return "按中国银行\(currency.title)现汇买入价换算：1 \(currency.rawValue) = \(StockValueFormatter.exchangeRate(rate)) CNY"
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
        return StockValueFormatter.moneyMagnitude(value, currencyCode: displayCurrencyCode)
    }

    private func signedMoneyText(_ value: Decimal?) -> String {
        guard let value else { return "待同步" }
        return StockValueFormatter.signedMoney(value, currencyCode: displayCurrencyCode)
    }

    private var usesRenminbi: Bool { marketFilter.market == nil || stockAppearanceSettings.overviewUsesRenminbi }
    private var displayCurrencyCode: String { usesRenminbi ? "CNY" : marketFilter.market?.currencyCode ?? "CNY" }

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
