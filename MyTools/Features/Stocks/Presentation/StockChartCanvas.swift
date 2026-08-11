#if MYTOOLS_FEATURE_STOCKS
import Charts
import SwiftUI

private enum StockChartVisualStyle {
    static let dataLine = StrokeStyle(
        lineWidth: 1.25,
        lineCap: .round,
        lineJoin: .round
    )
    static let referenceLineWidth: CGFloat = 0.75
}

struct StockChartCanvas: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings

    let snapshot: StockChartSnapshot
    let stock: StockHolding
    let range: StockChartRange
    let displayModes: Set<StockChartDisplayMode>
    let isExpanded: Bool
    @Binding var selectedDate: Date?
    @Binding var isInteracting: Bool

    var body: some View {
        let presentation = StockChartPresentation(
            snapshot: snapshot,
            stock: stock,
            range: range,
            displayModes: displayModes
        )
        VStack(alignment: .leading, spacing: 8) {
            summary(presentation)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 34, alignment: .top)
            if displayModes.isEmpty {
                Image(systemName: "chart.xyaxis.line")
                    .font(isExpanded ? .largeTitle : .title2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart(presentation)
            }
        }
    }

    private func chart(_ presentation: StockChartPresentation) -> some View {
        let selectedPlotPoint = presentation.selectedPlotPoint(at: selectedDate)
        let selectedTechnicalPlotPoint = presentation.selectedTechnicalPlotPoint(
            at: selectedDate
        )

        return Chart {
            if presentation.hasBasePriceChart,
               range == .intraday,
               let previousClose = StockChartPresentation.intradayPreviousClose(
                snapshot: snapshot,
                market: stock.market
               ),
               presentation.yDomain.contains(previousClose) {
                RuleMark(y: .value("昨收", previousClose))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth,
                        dash: [4, 3]
                    ))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("昨收 \(StockChartPresentation.plainPriceText(previousClose))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }

            if displayModes.contains(.line) {
                ForEach(presentation.plotPoints) { plotPoint in
                    LineMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("价格", plotPoint.point.close)
                    )
                    .foregroundStyle(lineColor())
                    .lineStyle(StockChartVisualStyle.dataLine)
                    .interpolationMethod(.linear)
                }
            }

            if displayModes.contains(.candlestick) {
                ForEach(presentation.plotPoints) { plotPoint in
                    RuleMark(
                        x: .value("时间", plotPoint.x),
                        yStart: .value("最低", plotPoint.point.low),
                        yEnd: .value("最高", plotPoint.point.high)
                    )
                    .foregroundStyle(candleColor(plotPoint.point))

                    RectangleMark(
                        x: .value("时间", plotPoint.x),
                        yStart: .value("开盘", plotPoint.point.open),
                        yEnd: .value("收盘", plotPoint.point.close),
                        width: .fixed(StockChartPresentation.candleWidth(
                            pointCount: snapshot.points.count,
                            isExpanded: isExpanded
                        ))
                    )
                    .foregroundStyle(candleColor(plotPoint.point))
                }
            }

            if displayModes.contains(.movingAverage) {
                ForEach(presentation.technicalPlotPoints) { plotPoint in
                    if let value = plotPoint.indicator.movingAverage5 {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("MA5", value),
                            series: .value("指标", "MA5")
                        )
                        .foregroundStyle(.teal)
                        .lineStyle(StockChartVisualStyle.dataLine)
                        .interpolationMethod(.linear)
                    }
                    if let value = plotPoint.indicator.movingAverage20 {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("MA20", value),
                            series: .value("指标", "MA20")
                        )
                        .foregroundStyle(.purple)
                        .lineStyle(StockChartVisualStyle.dataLine)
                        .interpolationMethod(.linear)
                    }
                    if let value = plotPoint.indicator.movingAverage60 {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("MA60", value),
                            series: .value("指标", "MA60")
                        )
                        .foregroundStyle(.brown)
                        .lineStyle(StockChartVisualStyle.dataLine)
                        .interpolationMethod(.linear)
                    }
                }
            }

            if displayModes.contains(.bollingerBands) {
                ForEach(presentation.technicalPlotPoints) { plotPoint in
                    if let upper = plotPoint.indicator.bollingerUpper,
                       let lower = plotPoint.indicator.bollingerLower {
                        AreaMark(
                            x: .value("时间", plotPoint.x),
                            yStart: .value("下轨", lower),
                            yEnd: .value("上轨", upper)
                        )
                        .foregroundStyle(Color.mint.opacity(0.12))
                    }
                    if let value = plotPoint.indicator.bollingerUpper {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("上轨", value),
                            series: .value("指标", "上轨")
                        )
                        .foregroundStyle(Color.mint.opacity(0.9))
                        .lineStyle(StockChartVisualStyle.dataLine)
                    }
                    if let value = plotPoint.indicator.bollingerMiddle {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("中轨", value),
                            series: .value("指标", "中轨")
                        )
                        .foregroundStyle(.teal)
                        .lineStyle(StockChartVisualStyle.dataLine)
                    }
                    if let value = plotPoint.indicator.bollingerLower {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("下轨", value),
                            series: .value("指标", "下轨")
                        )
                        .foregroundStyle(Color.cyan.opacity(0.9))
                        .lineStyle(StockChartVisualStyle.dataLine)
                    }
                }
            }

            if displayModes.contains(.volume) {
                ForEach(presentation.plotPoints) { plotPoint in
                    if let volume = plotPoint.point.volume {
                        BarMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("成交量", volume),
                            width: .fixed(StockChartPresentation.indicatorBarWidth(
                                pointCount: presentation.plotPoints.count,
                                isExpanded: isExpanded
                            ))
                        )
                        .foregroundStyle(candleColor(plotPoint.point).opacity(0.72))
                    }
                }
            }

            if displayModes.contains(.macd) {
                RuleMark(y: .value("零轴", 0))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth
                    ))
                ForEach(presentation.technicalPlotPoints) { plotPoint in
                    BarMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("MACD", plotPoint.indicator.macdHistogram),
                        width: .fixed(StockChartPresentation.indicatorBarWidth(
                            pointCount: presentation.plotPoints.count,
                            isExpanded: isExpanded
                        ))
                    )
                    .foregroundStyle(
                        valueColor(plotPoint.indicator.macdHistogram).opacity(0.68)
                    )
                    LineMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("DIF", plotPoint.indicator.macdLine),
                        series: .value("指标", "DIF")
                    )
                    .foregroundStyle(.purple)
                    .lineStyle(StockChartVisualStyle.dataLine)
                    LineMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("DEA", plotPoint.indicator.macdSignal),
                        series: .value("指标", "DEA")
                    )
                    .foregroundStyle(.teal)
                    .lineStyle(StockChartVisualStyle.dataLine)
                }
            }

            if displayModes.contains(.rsi) {
                RuleMark(y: .value("超买参考", 70))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth,
                        dash: [4, 3]
                    ))
                RuleMark(y: .value("超卖参考", 30))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth,
                        dash: [4, 3]
                    ))
                ForEach(presentation.technicalPlotPoints) { plotPoint in
                    if let value = plotPoint.indicator.rsi14 {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("RSI14", value)
                        )
                        .foregroundStyle(.purple)
                        .lineStyle(StockChartVisualStyle.dataLine)
                        .interpolationMethod(.linear)
                    }
                }
            }

            if presentation.hasBasePriceChart {
                ForEach(presentation.transactionMarkers) { marker in
                    PointMark(
                        x: .value("交易日期", marker.plotX),
                        y: .value("交易位置", marker.plotPrice)
                    )
                    .foregroundStyle(transactionColor(marker.type))
                    .symbolSize(isExpanded ? 64 : 46)
                }
            }

            if let selectedPlotPoint {
                RuleMark(x: .value("所选时间", selectedPlotPoint.x))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth
                    ))
                if presentation.hasBasePriceChart {
                    PointMark(
                        x: .value("所选时间", selectedPlotPoint.x),
                        y: .value("所选价格", selectedPlotPoint.point.close)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
                if displayModes.contains(.volume),
                   let volume = selectedPlotPoint.point.volume {
                    PointMark(
                        x: .value("所选时间", selectedPlotPoint.x),
                        y: .value("所选成交量", volume)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
            }

            if let selectedTechnicalPlotPoint {
                if displayModes.contains(.macd) {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选 DIF", selectedTechnicalPlotPoint.indicator.macdLine)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
                if displayModes.contains(.rsi),
                   let rsi = selectedTechnicalPlotPoint.indicator.rsi14 {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选 RSI", rsi)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
                if !presentation.hasBasePriceChart,
                   displayModes.contains(.movingAverage),
                   let movingAverage = selectedTechnicalPlotPoint.indicator.movingAverage5
                    ?? selectedTechnicalPlotPoint.indicator.movingAverage20
                    ?? selectedTechnicalPlotPoint.indicator.movingAverage60 {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选均线", movingAverage)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                } else if !presentation.hasBasePriceChart,
                          displayModes.contains(.bollingerBands),
                          let middle = selectedTechnicalPlotPoint.indicator.bollingerMiddle {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选中轨", middle)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
            }
        }
        .chartYScale(domain: presentation.yDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: presentation.xAxisValues(isExpanded: isExpanded)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let x = value.as(Double.self),
                       let plotPoint = presentation.plotPoint(closestTo: x) {
                        Text(presentation.axisLabelText(plotPoint.point.date))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            if displayModes.contains(.rsi) {
                AxisMarks(position: .leading, values: [0, 30, 50, 70, 100]) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            } else {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(yAxisLabelText(number))
                        }
                    }
                }
            }
        }
        .chartXScale(
            domain: presentation.xDomain,
            range: .plotDimension(startPadding: 22, endPadding: 22)
        )
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isInteracting = true
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geometry[plotFrame]
                                guard frame.contains(value.location) else {
                                    selectedDate = nil
                                    return
                                }
                                let location = CGPoint(
                                    x: value.location.x - frame.minX,
                                    y: value.location.y - frame.minY
                                )
                                if let x: Double = proxy.value(atX: location.x),
                                   let plotPoint = presentation.plotPoint(closestTo: x) {
                                    selectedDate = plotPoint.point.date
                                }
                            }
                            .onEnded { _ in
                                Task { @MainActor in
                                    await Task.yield()
                                    isInteracting = false
                                }
                            }
                    )
            }
        }
        .accessibilityLabel(
            "\(stock.displayName)\(range.title)\(presentation.displayModesTitle)图"
        )
    }

    @ViewBuilder
    private func summary(_ presentation: StockChartPresentation) -> some View {
        if let point = presentation.selectedPoint(at: selectedDate) {
            selectedPointSummary(point, presentation: presentation)
        } else {
            summaryPlaceholder
        }
    }

    private func selectedPointSummary(
        _ point: StockChartPoint,
        presentation: StockChartPresentation
    ) -> some View {
        let indicator = presentation.technicalIndicator(at: point)
        let selections = presentation.transactionSelections(at: point)
        let closeText = StockChartPresentation.priceText(
            point.close,
            currencyCode: snapshot.currencyCode
        )
        let volumeText = point.volume.map(StockChartPresentation.volumeText) ?? "--"
        return VStack(alignment: .leading, spacing: 4) {
            StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                Text(presentation.chartDateText(point.date))
                    .foregroundStyle(.secondary)
                if presentation.hasPriceChart {
                    Text("收盘 \(closeText)")
                        .fontWeight(.medium)
                }
                if displayModes.contains(.candlestick) {
                    Text(
                        "高 \(StockChartPresentation.plainPriceText(point.high))  "
                            + "低 \(StockChartPresentation.plainPriceText(point.low))"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if presentation.hasBasePriceChart, !selections.isEmpty {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(selections) { selection in
                        Text(transactionSummary(selection))
                            .fontWeight(.semibold)
                            .foregroundStyle(transactionColor(selection.type))
                    }
                }
            }

            if displayModes.contains(.movingAverage), let indicator {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    movingAverageSummary(indicator)
                }
            }

            if displayModes.contains(.bollingerBands), let indicator {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    bollingerSummary(indicator)
                }
            }

            if displayModes.contains(.volume) {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    Text("成交量 \(volumeText)")
                        .fontWeight(.medium)
                }
            }

            if displayModes.contains(.macd), let indicator {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    Text("DIF \(StockChartPresentation.indicatorText(indicator.macdLine))")
                        .foregroundStyle(.purple)
                    Text("DEA \(StockChartPresentation.indicatorText(indicator.macdSignal))")
                        .foregroundStyle(.teal)
                    Text("MACD \(StockChartPresentation.indicatorText(indicator.macdHistogram))")
                        .foregroundStyle(.secondary)
                }
            }

            if displayModes.contains(.rsi), let rsi = indicator?.rsi14 {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    Text("RSI14 \(StockChartPresentation.indicatorText(rsi))")
                        .fontWeight(.medium)
                        .foregroundStyle(.purple)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func transactionSummary(_ selection: StockTransactionSelection) -> String {
        let price = StockValueFormatter.price(
            selection.averagePrice,
            currencyCode: snapshot.currencyCode
        )
        return "\(selection.type.title) \(price)"
    }

    @ViewBuilder
    private func movingAverageSummary(_ indicator: StockTechnicalIndicatorPoint) -> some View {
        if let value = indicator.movingAverage5 {
            Text("MA5 \(StockChartPresentation.plainPriceText(value))")
                .foregroundStyle(.teal)
        }
        if let value = indicator.movingAverage20 {
            Text("MA20 \(StockChartPresentation.plainPriceText(value))")
                .foregroundStyle(.purple)
        }
        if let value = indicator.movingAverage60 {
            Text("MA60 \(StockChartPresentation.plainPriceText(value))")
                .foregroundStyle(.brown)
        }
    }

    @ViewBuilder
    private func bollingerSummary(_ indicator: StockTechnicalIndicatorPoint) -> some View {
        if let value = indicator.bollingerUpper {
            Text("上 \(StockChartPresentation.plainPriceText(value))")
                .foregroundStyle(.mint)
        }
        if let value = indicator.bollingerMiddle {
            Text("中 \(StockChartPresentation.plainPriceText(value))")
                .foregroundStyle(.teal)
        }
        if let value = indicator.bollingerLower {
            Text("下 \(StockChartPresentation.plainPriceText(value))")
                .foregroundStyle(.cyan)
        }
    }

    private var summaryPlaceholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            if displayModes.isEmpty {
                Text("未选择图表")
                    .foregroundStyle(.secondary)
            }

            if displayModes.contains(.line) || displayModes.contains(.candlestick) {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    if displayModes.contains(.line) {
                        Text("收盘价").foregroundStyle(.secondary)
                    }
                    if displayModes.contains(.candlestick) {
                        Text("开盘 · 最高 · 最低 · 收盘").foregroundStyle(.secondary)
                    }
                }
            }

            if displayModes.contains(.movingAverage) {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    Text("MA5").foregroundStyle(.teal)
                    Text("MA20").foregroundStyle(.purple)
                    Text("MA60").foregroundStyle(.brown)
                }
            }

            if displayModes.contains(.bollingerBands) {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    Text("上轨").foregroundStyle(.mint)
                    Text("中轨").foregroundStyle(.teal)
                    Text("下轨").foregroundStyle(.cyan)
                }
            }

            if displayModes.contains(.volume) {
                Text("成交量").foregroundStyle(.secondary)
            }

            if displayModes.contains(.macd) {
                StockChartSummaryFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    Text("DIF").foregroundStyle(.purple)
                    Text("DEA").foregroundStyle(.teal)
                    Text("MACD").foregroundStyle(.secondary)
                }
            }

            if displayModes.contains(.rsi) {
                Text("RSI14").foregroundStyle(.purple)
            }
        }
        .font(.caption)
    }

    private func lineColor() -> Color {
        guard let performance = StockChartPresentation.rangePerformance(
            snapshot: snapshot,
            range: range,
            market: stock.market
        ) else { return .accentColor }
        return valueColor(performance.change)
    }

    private func candleColor(_ point: StockChartPoint) -> Color {
        valueColor(point.close - point.open)
    }

    private func transactionColor(_ type: StockTransactionType) -> Color {
        switch type {
        case .buy: return .blue
        case .sell: return .orange
        }
    }

    private func valueColor(_ value: Double) -> Color {
        StockTrendColor.color(
            for: value,
            market: stock.market,
            settings: stockAppearanceSettings,
            neutral: .secondary
        )
    }

    private func yAxisLabelText(_ value: Double) -> String {
        if displayModes.contains(.volume) {
            return StockChartPresentation.volumeText(value)
        }
        if displayModes.contains(.macd) {
            return StockChartPresentation.indicatorText(value)
        }
        return StockChartPresentation.plainPriceText(value)
    }
}

private struct StockChartSummaryFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 10, verticalSpacing: CGFloat = 4) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = itemSize(subview, availableWidth: availableWidth)
            let nextWidth = currentWidth == 0
                ? size.width
                : currentWidth + horizontalSpacing + size.width
            if currentWidth > 0, nextWidth > availableWidth {
                measuredWidth = max(measuredWidth, currentWidth)
                totalHeight += currentHeight + verticalSpacing
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentWidth = nextWidth
                currentHeight = max(currentHeight, size.height)
            }
        }

        if currentHeight > 0 {
            measuredWidth = max(measuredWidth, currentWidth)
            totalHeight += currentHeight
        }
        let width = proposal.width ?? measuredWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let availableWidth = max(bounds.width, 1)
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = itemSize(subview, availableWidth: availableWidth)
            let nextX = x == bounds.minX
                ? x + size.width
                : x + horizontalSpacing + size.width
            if x > bounds.minX, nextX > bounds.maxX {
                y += lineHeight + verticalSpacing
                x = bounds.minX
                lineHeight = 0
            }

            let placedX = x == bounds.minX ? x : x + horizontalSpacing
            subview.place(
                at: CGPoint(x: placedX, y: y + max((lineHeight - size.height) / 2, 0)),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x = placedX + size.width
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func itemSize(
        _ subview: LayoutSubview,
        availableWidth: CGFloat
    ) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard availableWidth.isFinite, ideal.width > availableWidth else {
            return ideal
        }
        return subview.sizeThatFits(
            ProposedViewSize(width: availableWidth, height: nil)
        )
    }
}

#endif
