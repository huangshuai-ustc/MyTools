#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

/// Column widths shared by the positions table header and its data rows.
/// `Grid` cannot align them because each list row is laid out independently, so
/// the widths have to be explicit. They scale with the macOS font setting.
enum StockPositionColumnMetrics {
    static let spacing: CGFloat = 6
    static let wideLayoutThreshold: CGFloat = 600
    /// Approximate width of the list disclosure indicator, applied to the header
    /// so its labels line up with the data rows beneath it.
    static let disclosureAllowance: CGFloat = 12

    private static func scaled(_ base: CGFloat, _ fontScale: CGFloat?) -> CGFloat {
        base * max(fontScale ?? 1, 1)
    }

    static func price(_ fontScale: CGFloat?) -> CGFloat { scaled(58, fontScale) }
    static func change(_ fontScale: CGFloat?) -> CGFloat { scaled(60, fontScale) }
    static func shares(_ fontScale: CGFloat?) -> CGFloat { scaled(46, fontScale) }
    static func profit(_ fontScale: CGFloat?) -> CGFloat { scaled(66, fontScale) }

    static func usesEqualColumns(at width: CGFloat) -> Bool {
        width >= wideLayoutThreshold
    }

    /// 只有 iPad 才按实际宽度在标准列与等宽列之间切换。
    ///
    /// iPhone 与 macOS 直接用固定列宽的标准布局：把 `GeometryReader` 套在列表行上会让
    /// 行高吃掉 `List` 给出的全部提案高度（`.frame(minHeight:)` 只是下限），内容顶对齐、
    /// 下面空出一截，整张持仓表因此比看盘页松散得多。看盘行同样只在 iPad 上测宽
    /// （`StockWatchlistRow.body`），两页保持一致的行高观感。iPad 仍然需要测宽——分屏时
    /// 宽度可能落在阈值以下。
    static var usesWidthAdaptiveColumns: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    static func equalColumnWidth(for width: CGFloat) -> CGFloat {
        max((width - spacing * 4) / 5, 0)
    }
}

/// Secondary percentages in the dense home rows. Deliberately smaller than
/// `caption2` so the value on the first line stays the thing you read first.
private let stockRowPercentFont = AppFontSpec.system(size: 10).monospacedDigit()

/// 持仓表表头。列宽与 `StockPositionRow` 共用 `StockPositionColumnMetrics`。
struct StockPositionColumnHeader: View {
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        if StockPositionColumnMetrics.usesWidthAdaptiveColumns {
            GeometryReader { proxy in
                if StockPositionColumnMetrics.usesEqualColumns(at: proxy.size.width) {
                    equalColumnHeader(width: proxy.size.width)
                } else {
                    standardHeader
                }
            }
            .frame(minHeight: 24)
        } else {
            standardHeader
        }
    }

    private var standardHeader: some View {
        HStack(spacing: StockPositionColumnMetrics.spacing) {
            Text("投资产品")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("最新价")
                .frame(width: StockPositionColumnMetrics.price(fontScale), alignment: .leading)
            Text("涨跌")
                .frame(width: StockPositionColumnMetrics.change(fontScale), alignment: .leading)
            Text("持仓")
                .frame(width: StockPositionColumnMetrics.shares(fontScale), alignment: .leading)
            Text("盈亏")
                .frame(width: StockPositionColumnMetrics.profit(fontScale), alignment: .leading)
        }
        .padding(.trailing, StockPositionColumnMetrics.disclosureAllowance)
        .appFont(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }

    private func equalColumnHeader(width: CGFloat) -> some View {
        let columnWidth = StockPositionColumnMetrics.equalColumnWidth(for: width)
        return HStack(spacing: StockPositionColumnMetrics.spacing) {
            Text("投资产品")
                .frame(width: columnWidth, alignment: .leading)
            Text("最新价")
                .frame(width: columnWidth, alignment: .leading)
            Text("涨跌")
                .frame(width: columnWidth, alignment: .leading)
            Text("持仓")
                .frame(width: columnWidth, alignment: .leading)
            Text("盈亏")
                .frame(width: columnWidth, alignment: .leading)
        }
        .appFont(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }
}

/// 持仓行：代码/名称 · 最新价 · 涨跌 · 持仓 · 盈亏。
struct StockPositionRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let stock: StockHolding
    let costShare: Decimal?
    let extendedHours: StockExtendedHoursPerformance?
    var performance: StockHolding.Performance? = nil

    var body: some View {
        // `GeometryReader` 会随宽度提案反复求值，而 `holdingProfitLoss`/`holdingProfitRate`
        // /`accessibilityLabel` 原先各自都要把这只股票的交易回放一遍（`holdingCost` 还带
        // 排序），一行最多 6 次。这里一次算好往下传。
        let values = rowValues()
        if StockPositionColumnMetrics.usesWidthAdaptiveColumns {
            GeometryReader { proxy in
                if StockPositionColumnMetrics.usesEqualColumns(at: proxy.size.width) {
                    equalColumnBody(width: proxy.size.width, values: values)
                } else {
                    standardBody(values: values)
                }
            }
            .frame(minHeight: 42)
        } else {
            standardBody(values: values)
        }
    }

    private func standardBody(values: RowValues) -> some View {
        HStack(alignment: .top, spacing: StockPositionColumnMetrics.spacing) {
            identityColumn
            priceColumn(values: values)
            valueColumn(
                width: StockPositionColumnMetrics.change(fontScale),
                primary: changeAmountText(values),
                secondary: changePercentText(values),
                color: trendColor(values.quote.percent)
            )
            valueColumn(
                width: StockPositionColumnMetrics.shares(fontScale),
                primary: StockValueFormatter.integerQuantity(values.shares),
                secondary: costShare.map(StockValueFormatter.allocationPercent)
            )
            valueColumn(
                width: StockPositionColumnMetrics.profit(fontScale),
                primary: holdingProfitLossText(values),
                secondary: holdingProfitRateText(values),
                color: trendColor(values.holdingProfitLoss)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(values))
    }

    private func equalColumnBody(width: CGFloat, values: RowValues) -> some View {
        let columnWidth = StockPositionColumnMetrics.equalColumnWidth(for: width)
        return HStack(alignment: .top, spacing: StockPositionColumnMetrics.spacing) {
            identityColumn.frame(width: columnWidth, alignment: .leading)
            priceColumn(values: values).frame(width: columnWidth, alignment: .leading)
            valueColumn(width: columnWidth, primary: changeAmountText(values), secondary: changePercentText(values), color: trendColor(values.quote.percent))
            valueColumn(width: columnWidth, primary: StockValueFormatter.integerQuantity(values.shares), secondary: costShare.map(StockValueFormatter.allocationPercent))
            valueColumn(width: columnWidth, primary: holdingProfitLossText(values), secondary: holdingProfitRateText(values), color: trendColor(values.holdingProfitLoss))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(values))
    }

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                StockMarketBadge(market: stock.market)
                Text(stock.symbol)
                    .font(AppFontSpec.subheadline.weight(.semibold).monospaced().font(scale: fontScale))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(stock.displayName)
                .appFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 最新价只有一行，用一个不可见的「两行模板」撑出与其他列相同的高度，再靠
    /// `ZStack` 的垂直居中把价格摆在相邻两行文字之间。模板跟着字号变化，比写死
    /// 偏移量或依赖 `maxHeight: .infinity` 在列表行里的高度提案更可预测。
    private func priceColumn(values: RowValues) -> some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 2) {
                Text("0").font(primaryValueFont)
                Text("0").font(secondaryValueFont)
            }
            .hidden()
            Text(priceText(values))
                .font(primaryValueFont)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: StockPositionColumnMetrics.price(fontScale), alignment: .leading)
    }

    private var primaryValueFont: Font {
        AppFontSpec.caption.weight(.semibold).monospacedDigit().font(scale: fontScale)
    }

    private var secondaryValueFont: Font {
        stockRowPercentFont.font(scale: fontScale)
    }

    private func valueColumn(
        width: CGFloat,
        primary: String,
        secondary: String? = nil,
        color: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primary)
                .font(primaryValueFont)
                .foregroundStyle(color)
            if let secondary {
                Text(secondary)
                    .font(secondaryValueFont)
                    .foregroundStyle(color)
                    .opacity(0.72)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: width, alignment: .leading)
    }

    /// 一行需要的全部派生值，一次交易回放算完。
    private struct RowValues {
        let quote: StockActiveQuote
        let shares: Decimal
        /// Holding profit measured against the price actually shown, so extended
        /// hours moves are reflected in the same row.
        ///
        /// 由 `StockHoldingValuation` 从 `quote` 派生，与顶部总览、市场概况共用同一个
        /// 类型：行内不再自己写 `currentShares * price - holdingCost`，否则改口径时会
        /// 漏掉一处。
        let holdingProfitLoss: Decimal?
        let holdingProfitRate: Decimal?
    }

    private func rowValues() -> RowValues {
        let performance = performance ?? stock.performance()
        let quote = StockActiveQuote.make(stock: stock, extendedHours: extendedHours)
        let holdingProfitLoss = StockHoldingValuation(
            stock: stock,
            quote: quote,
            performance: performance
        ).holdingProfitLoss
        var holdingProfitRate: Decimal?
        if performance.holdingCost > 0, let holdingProfitLoss {
            holdingProfitRate = holdingProfitLoss / performance.holdingCost
        }
        return RowValues(
            quote: quote,
            shares: performance.shares,
            holdingProfitLoss: holdingProfitLoss,
            holdingProfitRate: holdingProfitRate
        )
    }

    private func priceText(_ values: RowValues) -> String {
        values.quote.price.map {
            StockValueFormatter.price($0, currencyCode: stock.market.currencyCode)
        } ?? "--"
    }

    private func changeAmountText(_ values: RowValues) -> String {
        values.quote.changeAmount.map {
            StockValueFormatter.signedMoney($0, currencyCode: stock.market.currencyCode)
        } ?? "--"
    }

    private func changePercentText(_ values: RowValues) -> String {
        values.quote.percent.map(StockValueFormatter.signedPercent) ?? "--"
    }

    private func holdingProfitLossText(_ values: RowValues) -> String {
        guard let holdingProfitLoss = values.holdingProfitLoss else { return "待同步" }
        return StockValueFormatter.signedMoney(
            holdingProfitLoss,
            currencyCode: stock.market.currencyCode
        )
    }

    private func holdingProfitRateText(_ values: RowValues) -> String {
        values.holdingProfitRate.map(StockValueFormatter.signedPercent) ?? "--"
    }

    private func trendColor(_ value: Decimal?) -> Color {
        guard let value else { return .secondary }
        return StockTrendColor.color(
            for: value,
            market: stock.market,
            settings: stockAppearanceSettings,
            neutral: .secondary
        )
    }

    private func accessibilityLabel(_ values: RowValues) -> String {
        var parts = [
            "\(stock.market.title) \(stock.displayName) \(stock.symbol)",
            "\(values.quote.sessionTitle) \(priceText(values))",
            "涨跌 \(changeAmountText(values)) \(changePercentText(values))",
            "持仓 \(StockValueFormatter.integerQuantity(values.shares)) 股",
            "盈亏 \(holdingProfitLossText(values)) \(holdingProfitRateText(values))"
        ]
        if let costShare {
            parts.append("成本占比 \(StockValueFormatter.allocationPercent(costShare))")
        }
        return parts.joined(separator: "，")
    }
}

/// 看盘行：代码/名称 · 当日分时迷你图 · 价格色块与涨跌。
struct StockWatchlistRow: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @Environment(\.appFontScale) private var fontScale
    let stock: StockHolding
    let extendedHours: StockExtendedHoursPerformance?
    let sparkline: StockSparklineSeries?

    private var sparklineWidth: CGFloat { 88 * max(fontScale ?? 1, 1) }
    private var sparklineHeight: CGFloat { 30 * max(fontScale ?? 1, 1) }
    /// 名称列限宽、行尾留一个弹性空位，整行内容因此整体左移；迷你图和报价列都用
    /// 固定宽度左对齐，跨行的分时图起点和价格起点才会各自对齐成一条竖线。
    private var identityMaxWidth: CGFloat { 150 * max(fontScale ?? 1, 1) }
    private var quoteWidth: CGFloat { 96 * max(fontScale ?? 1, 1) }

    var body: some View {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            GeometryReader { proxy in
                iPadBody(width: proxy.size.width)
            }
            .frame(minHeight: 52)
        } else {
            standardBody
        }
#else
        standardBody
#endif
    }

    private var standardBody: some View {
        HStack(spacing: 8) {
            identityColumn
                .frame(maxWidth: identityMaxWidth, alignment: .leading)
            sparklineView
            quoteColumn
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func iPadBody(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            identityColumn.frame(width: width * 0.32, alignment: .leading)
            sparklineView.frame(width: width * 0.22, alignment: .leading)
            quoteColumn.frame(width: width * 0.28, alignment: .leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                StockMarketBadge(market: stock.market)
                Text(stock.symbol)
                    .font(AppFontSpec.subheadline.weight(.semibold).monospaced().font(scale: fontScale))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if stock.isArchived {
                    Text("已存档")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text(stock.displayName)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Draws only from the on-disk intraday cache. A missing entry keeps an
    /// equal-height placeholder so row heights stay stable.
    @ViewBuilder
    private var sparklineView: some View {
        if let sparkline {
            StockSparklineView(
                series: sparkline,
                baseline: sparklineBaseline,
                color: trendColor
            )
            .frame(width: sparklineWidth, height: sparklineHeight)
        } else {
            Color.clear
                .frame(width: sparklineWidth, height: sparklineHeight)
        }
    }

    /// 虚线零轴 = 这一行自己的「价格 − 涨跌额」，也就是本行百分比的分母。
    ///
    /// 不从分时缓存的 `previousClose` 另算：盘前的零轴是 `StockChartPresentation`
    /// 特判出的上一结算收盘，两者常常差一天，分开算过一次的结果就是「涨了 0.25%，
    /// 虚线却压在折线上方」。
    private var sparklineBaseline: Double? {
        let quote = quote
        guard let price = quote.price, let change = quote.changeAmount else { return nil }
        let reference = price - change
        guard reference > 0 else { return nil }
        return NSDecimalNumber(decimal: reference).doubleValue
    }

    private var quoteColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(priceText)
                .font(AppFontSpec.subheadline.weight(.semibold).monospacedDigit().font(scale: fontScale))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(trendColor, in: RoundedRectangle(cornerRadius: 4))
            Text("\(changeAmountText)（\(changePercentText)）")
                .font(stockRowPercentFont.font(scale: fontScale))
                .foregroundStyle(trendColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: quoteWidth, alignment: .leading)
    }

    private var quote: StockActiveQuote {
        StockActiveQuote.make(stock: stock, extendedHours: extendedHours)
    }

    private var priceText: String {
        quote.price.map {
            StockValueFormatter.price($0, currencyCode: stock.market.currencyCode)
        } ?? "--"
    }

    private var changeAmountText: String {
        quote.changeAmount.map {
            StockValueFormatter.signedMoney($0, currencyCode: stock.market.currencyCode)
        } ?? "--"
    }

    private var changePercentText: String {
        quote.percent.map(StockValueFormatter.signedPercent) ?? "--"
    }

    /// The price chip needs a solid fill, so a missing quote falls back to gray
    /// rather than the semantic `.secondary` used for text.
    private var trendColor: Color {
        guard let percent = quote.percent else { return .gray }
        return StockTrendColor.color(
            for: percent,
            market: stock.market,
            settings: stockAppearanceSettings,
            neutral: .gray
        )
    }

    private var accessibilityLabel: String {
        var parts = ["\(stock.market.title) \(stock.displayName) \(stock.symbol)"]
        if stock.isArchived { parts.append("已存档") }
        parts.append("\(quote.sessionTitle) \(priceText)")
        parts.append("涨跌 \(changeAmountText) \(changePercentText)")
        return parts.joined(separator: "，")
    }
}

#endif
