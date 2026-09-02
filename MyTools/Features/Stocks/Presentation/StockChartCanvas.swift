#if MYTOOLS_FEATURE_STOCKS
import Charts
import Foundation
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
    @Binding var visibleXDomain: ClosedRange<Double>?
    let isExpanded: Bool
    @Binding var selectedDate: Date?
    @Binding var isInteracting: Bool
    @State private var lastPanTranslation: CGFloat = 0
    @State private var lastMagnification: CGFloat = 1
    @State private var isLongPressPanning = false
    @State private var didBeginLongPressPan = false
    @State private var isPointerDown = false
    @State private var longPressTask: Task<Void, Never>?
    @State private var initialPointerLocation: CGPoint = .zero
    @State private var latestPointerLocation: CGPoint = .zero
    @State private var lastSelectionUpdateTime: TimeInterval = 0
    @State private var hasUserAdjustedVisibleXDomain = false
    @State private var cachedPresentation: StockChartPresentation

    private struct PresentationDataInputKey: Equatable {
        let snapshotFetchedAt: Date
        let snapshotQuoteUpdatedAt: Date
        let snapshotPointCount: Int
        let snapshotLatestDate: Date?
        let snapshotIndicatorPointCount: Int
        let snapshotDailyIndicatorPointCount: Int
        let cachedMinuteIndicatorPointCount: Int
        let cachedDailyIndicatorPointCount: Int
        let snapshotPreMarketPointCount: Int
        let snapshotPostMarketPointCount: Int
        let stockMarket: StockMarket
        let stockSymbol: String
        let stockName: String
        let stockQuoteName: String
        let transactions: [StockTransaction]
        let range: StockChartRange
    }

    init(
        snapshot: StockChartSnapshot,
        stock: StockHolding,
        range: StockChartRange,
        displayModes: Set<StockChartDisplayMode>,
        visibleXDomain: Binding<ClosedRange<Double>?>,
        isExpanded: Bool,
        selectedDate: Binding<Date?>,
        isInteracting: Binding<Bool>
    ) {
        self.snapshot = snapshot
        self.stock = stock
        self.range = range
        self.displayModes = displayModes
        self._visibleXDomain = visibleXDomain
        self.isExpanded = isExpanded
        self._selectedDate = selectedDate
        self._isInteracting = isInteracting
        self._cachedPresentation = State(
            initialValue: StockChartPresentation(
                snapshot: snapshot,
                stock: stock,
                range: range,
                displayModes: displayModes
            )
        )
    }

    private var presentationDataInputKey: PresentationDataInputKey {
        PresentationDataInputKey(
            snapshotFetchedAt: snapshot.fetchedAt,
            snapshotQuoteUpdatedAt: snapshot.quoteUpdatedAt,
            snapshotPointCount: snapshot.points.count,
            snapshotLatestDate: snapshot.points.last?.date,
            snapshotIndicatorPointCount: snapshot.indicatorPoints?.count ?? 0,
            snapshotDailyIndicatorPointCount: snapshot.dailyIndicatorPoints?.count ?? 0,
            cachedMinuteIndicatorPointCount: snapshot.cachedMinuteTechnicalIndicators?.count ?? 0,
            cachedDailyIndicatorPointCount: snapshot.cachedDailyTechnicalIndicators?.count ?? 0,
            snapshotPreMarketPointCount: snapshot.preMarketPoints.count,
            snapshotPostMarketPointCount: snapshot.postMarketPoints.count,
            stockMarket: stock.market,
            stockSymbol: stock.symbol,
            stockName: stock.name,
            stockQuoteName: stock.quoteName,
            transactions: stock.transactions,
            range: range
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if displayModes.isEmpty {
                summary(cachedPresentation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 34, alignment: .top)
                Image(systemName: "chart.xyaxis.line")
                    .appFont(isExpanded ? .largeTitle : .title2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Reserve the same information area for selected and
                // unselected states. This keeps the plot height stable without
                // placing a floating panel over the data.
                ScrollView(.vertical, showsIndicators: false) {
                    summary(cachedPresentation)
                }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 58)
                chart(cachedPresentation)
            }
        }
        .onAppear {
            synchronizeVisibleXDomain(using: cachedPresentation)
        }
        .onChange(of: presentationDataInputKey) { _, _ in
            let presentation = StockChartPresentation(
                snapshot: snapshot,
                stock: stock,
                range: range,
                displayModes: displayModes
            )
            // A cached snapshot can contain only the newest K line while the
            // remote refresh is still filling historical data. Do not carry
            // that automatically-created tiny viewport into the new series;
            // preserve a viewport only after the user has panned or zoomed it.
            if visibleXDomain == nil {
                hasUserAdjustedVisibleXDomain = false
            } else if !hasUserAdjustedVisibleXDomain {
                visibleXDomain = nil
            }
            cachedPresentation = presentation
            synchronizeVisibleXDomain(using: presentation)
        }
        .onChange(of: displayModes) { _, modes in
            let presentation = cachedPresentation.updatingDisplayModes(modes)
            // Session-layer composition changes the ordinal x offsets. Keep a
            // user-created K-line viewport, but rebuild the automatic minute
            // viewport so adding pre/post-market data does not hide the end of
            // the regular session behind the old coordinate range.
            if !hasUserAdjustedVisibleXDomain {
                visibleXDomain = nil
            }
            cachedPresentation = presentation
            synchronizeVisibleXDomain(using: presentation)
        }
    }

    private func synchronizeVisibleXDomain(
        using presentation: StockChartPresentation
    ) {
        let requested = visibleXDomain
            ?? presentation.defaultVisibleXDomain(isExpanded: isExpanded)
        let clamped = presentation.clampedVisibleXDomain(requested)
        if visibleXDomain != clamped {
            visibleXDomain = clamped
        }
    }

    private func chart(_ presentation: StockChartPresentation) -> some View {
        let selectedPlotPoint = presentation.selectedPlotPoint(at: selectedDate)
        let selectedTechnicalPlotPoint = presentation.selectedTechnicalPlotPoint(
            at: selectedDate
        )
        let requestedXDomain = visibleXDomain
            ?? presentation.defaultVisibleXDomain(isExpanded: isExpanded)
        let chartXDomain = presentation.clampedVisibleXDomain(requestedXDomain)
        // Swift Charts can let fixed-width marks bleed across the domain edge.
        // Feed it only points in the active viewport so a candle/line from the
        // previous period cannot appear in the left gutter.
        let visibleData = presentation.visibleData(in: chartXDomain)
        let chartYDomain = presentation.yDomain(for: visibleData)
        let visiblePointCount = visibleData.plotPointCount
        let visiblePlotPoints = visibleData.plotPoints
        let visiblePreMarketPlotPoints = visibleData.preMarketPlotPoints
        let visiblePostMarketPlotPoints = visibleData.postMarketPlotPoints
        let visibleTechnicalPlotPoints = visibleData.technicalPlotPoints
        let visibleTransactionMarkers = visibleData.transactionMarkers
        // lineColor() resolves rangePerformance → intradayPreviousClose → a
        // full filter scan over indicatorPoints. Computing it once here instead
        // of inside the ForEach closure drops the per-render cost from
        // O(n_visible × n_indicator) to O(n_indicator).
        let resolvedLineColor = lineColor()

        return Chart {
            if presentation.hasPriceChart,
               range == .intraday,
               let previousClose = presentation.cachedIntradayPreviousClose ?? StockChartPresentation.intradayPreviousClose(
                snapshot: snapshot,
                market: stock.market,
                quotePreviousClose: stock.previousClose.map {
                    NSDecimalNumber(decimal: $0).doubleValue
                },
                quoteUpdatedAt: stock.lastQuoteAt
               ) {
                let displayedPreviousClose = StockChartPresentation
                    .clampedReferencePrice(previousClose, to: chartYDomain)
                RuleMark(y: .value("昨收", displayedPreviousClose))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth,
                        dash: [4, 3]
                    ))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("昨收 \(StockChartPresentation.plainPriceText(previousClose))")
                            .appFont(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }

            if displayModes.contains(.line) {
                ForEach(visiblePlotPoints) { plotPoint in
                    LineMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("价格", plotPoint.point.close)
                    )
                    .foregroundStyle(resolvedLineColor)
                    .lineStyle(StockChartVisualStyle.dataLine)
                    .interpolationMethod(.linear)
                }
            }

            if displayModes.contains(.candlestick) {
                ForEach(visiblePlotPoints) { plotPoint in
                    RuleMark(
                        x: .value("时间", plotPoint.x),
                        yStart: .value("最低", plotPoint.point.low),
                        yEnd: .value("最高", plotPoint.point.high)
                    )
                    .foregroundStyle(candleColor(plotPoint.point))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))

                    RectangleMark(
                        x: .value("时间", plotPoint.x),
                        yStart: .value("开盘", plotPoint.point.open),
                        yEnd: .value("收盘", plotPoint.point.close),
                        width: .fixed(StockChartPresentation.candleWidth(
                            pointCount: visiblePointCount,
                            isExpanded: isExpanded
                        ))
                    )
                    .foregroundStyle(candleColor(plotPoint.point))
                }
            }

            if displayModes.contains(.bollingerBands) {
                ForEach(visibleTechnicalPlotPoints) { plotPoint in
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

            // Draw moving averages after the translucent Bollinger area so its
            // colors stay opaque and match the legend.
            if displayModes.contains(.movingAverage) {
                ForEach(visibleTechnicalPlotPoints) { plotPoint in
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

            if displayModes.contains(.volume) {
                ForEach(visiblePlotPoints) { plotPoint in
                    if let volume = plotPoint.point.volume {
                        BarMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("成交量", volume),
                            width: .fixed(StockChartPresentation.indicatorBarWidth(
                                pointCount: visiblePointCount,
                                isExpanded: isExpanded
                            ))
                        )
                        .foregroundStyle(candleColor(plotPoint.point).opacity(0.72))
                    }
                }
                if presentation.hasPostMarketChart {
                    ForEach(visiblePostMarketPlotPoints) { plotPoint in
                        if let volume = plotPoint.point.volume {
                            BarMark(
                                x: .value("\(presentation.postMarketTitle)时间", plotPoint.x),
                                y: .value("成交量", volume),
                                width: .fixed(StockChartPresentation.indicatorBarWidth(
                                    pointCount: visiblePointCount,
                                    isExpanded: isExpanded
                                ))
                            )
                            .foregroundStyle(Color.blue.opacity(0.72))
                        }
                    }
                }
            }

            if displayModes.contains(.macd) {
                RuleMark(y: .value("零轴", 0))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth
                    ))
                ForEach(visibleTechnicalPlotPoints) { plotPoint in
                    BarMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("MACD", plotPoint.indicator.macdHistogram),
                        width: .fixed(StockChartPresentation.indicatorBarWidth(
                            pointCount: visiblePointCount,
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
                ForEach(visibleTechnicalPlotPoints) { plotPoint in
                    if let value = plotPoint.indicator.rsi14 {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("RSI14", value),
                            series: .value("指标", "RSI14")
                        )
                        .foregroundStyle(.purple)
                        .lineStyle(StockChartVisualStyle.dataLine)
                        .interpolationMethod(.linear)
                    }
                    if let value = plotPoint.indicator.rsi30 {
                        LineMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("RSI30", value),
                            series: .value("指标", "RSI30")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StockChartVisualStyle.dataLine)
                        .interpolationMethod(.linear)
                    }
                }
            }

            if displayModes.contains(.kdj) {
                indicatorRule(80, label: "超买参考", dashed: true)
                indicatorRule(20, label: "超卖参考", dashed: true)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.stochasticK, label: "K", color: .purple)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.stochasticD, label: "D", color: .teal)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.stochasticJ, label: "J", color: .orange)
            }

            if displayModes.contains(.williamsR) {
                indicatorRule(-20, label: "超买参考", dashed: true)
                indicatorRule(-80, label: "超卖参考", dashed: true)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.williamsR, label: "W%R", color: .purple)
            }

            if displayModes.contains(.cci) {
                indicatorRule(100, label: "强势参考", dashed: true)
                indicatorRule(-100, label: "弱势参考", dashed: true)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.commodityChannelIndex, label: "CCI", color: .purple)
            }

            if displayModes.contains(.dmi) {
                indicatorRule(25, label: "趋势参考", dashed: true)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.positiveDirectionalIndex, label: "+DI", color: .green)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.negativeDirectionalIndex, label: "-DI", color: .red)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.averageDirectionalIndex, label: "ADX", color: .purple)
            }

            if displayModes.contains(.momentum) {
                indicatorRule(0, label: "零轴")
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.momentum, label: "MTM", color: .purple)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.momentumAverage, label: "MTMMA", color: .teal)
            }

            if displayModes.contains(.trix) {
                indicatorRule(0, label: "零轴")
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.trix, label: "TRIX", color: .purple)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.trixSignal, label: "MATRIX", color: .teal)
            }

            if displayModes.contains(.volumeFlow) {
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.onBalanceVolume, label: "OBV", color: .purple)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.accumulationDistribution, label: "A/D", color: .teal)
            }

            if displayModes.contains(.mfi) {
                indicatorRule(80, label: "超买参考", dashed: true)
                indicatorRule(20, label: "超卖参考", dashed: true)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.moneyFlowIndex, label: "MFI", color: .purple)
            }

            if displayModes.contains(.chaikinMoneyFlow) {
                indicatorRule(0, label: "零轴")
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.chaikinMoneyFlow, label: "CMF", color: .purple)
            }

            if displayModes.contains(.psychologicalLine) {
                indicatorRule(75, label: "乐观参考", dashed: true)
                indicatorRule(25, label: "谨慎参考", dashed: true)
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.psychologicalLine, label: "PSY", color: .purple)
            }

            if displayModes.contains(.rateOfChange) {
                indicatorRule(0, label: "零轴")
                indicatorLine(visibleTechnicalPlotPoints, keyPath: \.rateOfChange, label: "ROC", color: .purple)
            }

            if presentation.hasPreMarketChart, !presentation.preMarketPlotPoints.isEmpty {
                ForEach(visiblePreMarketPlotPoints) { plotPoint in
                    LineMark(
                        x: .value("\(presentation.preMarketTitle)时间", plotPoint.x),
                        y: .value("\(presentation.preMarketTitle)价格", plotPoint.point.close),
                        series: .value("行情", presentation.preMarketTitle)
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StockChartVisualStyle.dataLine)
                    .interpolationMethod(.linear)
                }
            }

            if presentation.hasPostMarketChart, !presentation.postMarketPlotPoints.isEmpty {
                ForEach(visiblePostMarketPlotPoints) { plotPoint in
                    LineMark(
                        x: .value("\(presentation.postMarketTitle)时间", plotPoint.x),
                        y: .value("\(presentation.postMarketTitle)价格", plotPoint.point.close),
                        series: .value("行情", presentation.postMarketTitle)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StockChartVisualStyle.dataLine)
                    .interpolationMethod(.linear)
                }
            }

            if presentation.hasBasePriceChart {
                ForEach(visibleTransactionMarkers) { marker in
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
                advancedIndicatorSelectionMarks(selectedTechnicalPlotPoint)
                if displayModes.contains(.rsi),
                   let rsi30 = selectedTechnicalPlotPoint.indicator.rsi30 {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选 RSI30", rsi30)
                    )
                    .foregroundStyle(Color.orange)
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
        .chartYScale(domain: chartYDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(
                values: presentation.xAxisValues(
                    isExpanded: isExpanded,
                    in: chartXDomain
                )
            ) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let x = value.as(Double.self),
                       let plotPoint = presentation.plotPoint(
                           closestTo: x,
                           in: chartXDomain
                       ) {
                        Text(presentation.axisLabelText(plotPoint.point.date))
                            .appFont(.caption2)
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
            } else if !displayModes.isDisjoint(with: [.kdj, .mfi]) {
                AxisMarks(position: .leading, values: [0, 20, 50, 80, 100]) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            } else if displayModes.contains(.psychologicalLine) {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            } else if displayModes.contains(.williamsR) {
                AxisMarks(position: .leading, values: [-100, -80, -50, -20, 0]) {
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
            domain: chartXDomain,
            range: .plotDimension(startPadding: 26, endPadding: 48)
        )
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if range.isKLineRange {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        // A normal drag selects the nearest point. The
                        // same gesture upgrades to viewport panning after a
                        // deliberate hold; using one drag recognizer avoids
                        // two competing DragGesture state machines.
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isPointerDown {
                                        beginLongPressTimer(at: value.location)
                                    }
                                    latestPointerLocation = value.location
                                    isInteracting = true
                                    if isLongPressPanning {
                                        if !didBeginLongPressPan {
                                            // Ignore the movement that was
                                            // already used for point selection
                                            // before the hold threshold.
                                            lastPanTranslation = value.translation.width
                                            didBeginLongPressPan = true
                                        } else if let plotFrame = proxy.plotFrame {
                                            let frame = geometry[plotFrame]
                                            let deltaPixels = value.translation.width
                                                - lastPanTranslation
                                            lastPanTranslation = value.translation.width
                                            let deltaDomain = -Double(
                                                deltaPixels / max(frame.width, 1)
                                            ) * (chartXDomain.upperBound
                                                - chartXDomain.lowerBound)
                                            panViewport(
                                                by: deltaDomain,
                                                presentation: presentation,
                                                isExpanded: isExpanded
                                            )
                                            hasUserAdjustedVisibleXDomain = true
                                        }
                                    } else {
                                        selectPoint(
                                            at: value.location,
                                            proxy: proxy,
                                            geometry: geometry,
                                            presentation: presentation,
                                            visibleDomain: chartXDomain
                                        )
                                    }
                                }
                                .onEnded { value in
                                    endLongPressTimer()
                                    if !isLongPressPanning {
                                        selectPoint(
                                            at: value.location,
                                            proxy: proxy,
                                            geometry: geometry,
                                            presentation: presentation,
                                            visibleDomain: chartXDomain,
                                            force: true
                                        )
                                    }
                                    isLongPressPanning = false
                                    didBeginLongPressPan = false
                                    lastPanTranslation = 0
                                    initialPointerLocation = .zero
                                    latestPointerLocation = .zero
                                    finishInteraction()
                                }
                        )
                } else {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    isInteracting = true
                                    selectPoint(
                                        at: value.location,
                                        proxy: proxy,
                                        geometry: geometry,
                                        presentation: presentation,
                                        visibleDomain: chartXDomain
                                    )
                                }
                                .onEnded { value in
                                    selectPoint(
                                        at: value.location,
                                        proxy: proxy,
                                        geometry: geometry,
                                        presentation: presentation,
                                        visibleDomain: chartXDomain,
                                        force: true
                                    )
                                    finishInteraction()
                                }
                        )
                }
            }
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    guard range.isKLineRange else { return }
                    selectedDate = nil
                    let scale = value / max(lastMagnification, 0.01)
                    lastMagnification = value
                    zoomViewport(
                        by: 1 / Double(scale),
                        presentation: presentation,
                        isExpanded: isExpanded
                    )
                    hasUserAdjustedVisibleXDomain = true
                }
                .onEnded { _ in
                    lastMagnification = 1
                }
        )
        .accessibilityLabel(
            "\(stock.displayName)\(range.title)\(presentation.displayModesTitle)图"
        )
    }

    @ChartContentBuilder
    private func indicatorRule(
        _ value: Double,
        label: String,
        dashed: Bool = false
    ) -> some ChartContent {
        RuleMark(y: .value(label, value))
            .foregroundStyle(Color.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(
                lineWidth: StockChartVisualStyle.referenceLineWidth,
                dash: dashed ? [4, 3] : []
            ))
    }

    @ChartContentBuilder
    private func indicatorLine(
        _ points: [StockTechnicalPlotPoint],
        keyPath: KeyPath<StockTechnicalIndicatorPoint, Double?>,
        label: String,
        color: Color
    ) -> some ChartContent {
        ForEach(points) { plotPoint in
            if let value = plotPoint.indicator[keyPath: keyPath] {
                LineMark(
                    x: .value("时间", plotPoint.x),
                    y: .value(label, value),
                    series: .value("指标", label)
                )
                .foregroundStyle(color)
                .lineStyle(StockChartVisualStyle.dataLine)
                .interpolationMethod(.linear)
            }
        }
    }

    @ChartContentBuilder
    private func advancedIndicatorSelectionMarks(
        _ plotPoint: StockTechnicalPlotPoint
    ) -> some ChartContent {
        if let value = primaryAdvancedIndicatorValue(plotPoint.indicator) {
            PointMark(
                x: .value("所选时间", plotPoint.x),
                y: .value("所选指标", value)
            )
            .foregroundStyle(Color.primary)
            .symbolSize(36)
        }
    }

    private func primaryAdvancedIndicatorValue(
        _ indicator: StockTechnicalIndicatorPoint
    ) -> Double? {
        if displayModes.contains(.kdj) { return indicator.stochasticK }
        if displayModes.contains(.williamsR) { return indicator.williamsR }
        if displayModes.contains(.cci) { return indicator.commodityChannelIndex }
        if displayModes.contains(.dmi) {
            return indicator.averageDirectionalIndex
                ?? indicator.positiveDirectionalIndex
        }
        if displayModes.contains(.momentum) { return indicator.momentum }
        if displayModes.contains(.trix) { return indicator.trix }
        if displayModes.contains(.volumeFlow) { return indicator.onBalanceVolume }
        if displayModes.contains(.mfi) { return indicator.moneyFlowIndex }
        if displayModes.contains(.chaikinMoneyFlow) {
            return indicator.chaikinMoneyFlow
        }
        if displayModes.contains(.psychologicalLine) {
            return indicator.psychologicalLine
        }
        if displayModes.contains(.rateOfChange) { return indicator.rateOfChange }
        return nil
    }

    private func selectPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        presentation: StockChartPresentation,
        visibleDomain: ClosedRange<Double>,
        force: Bool = false
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            if selectedDate != nil {
                selectedDate = nil
            }
            return
        }
        let localLocation = CGPoint(
            x: location.x - frame.minX,
            y: location.y - frame.minY
        )
        if let x: Double = proxy.value(atX: localLocation.x),
           let plotPoint = presentation.plotPoint(
               closestTo: x,
               in: visibleDomain
           ) {
            let pointDate = plotPoint.point.date
            guard selectedDate != pointDate else { return }
            let now = Date.timeIntervalSinceReferenceDate
            guard force || now - lastSelectionUpdateTime >= (1 / 30) else {
                return
            }
            lastSelectionUpdateTime = now
            selectedDate = pointDate
        }
    }

    private func finishInteraction() {
        lastSelectionUpdateTime = 0
        Task { @MainActor in
            await Task.yield()
            isInteracting = false
        }
    }

    private func beginLongPressTimer(at location: CGPoint) {
        isPointerDown = true
        initialPointerLocation = location
        latestPointerLocation = location
        isLongPressPanning = false
        didBeginLongPressPan = false
        longPressTask?.cancel()
        longPressTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            let distance = hypot(
                latestPointerLocation.x - initialPointerLocation.x,
                latestPointerLocation.y - initialPointerLocation.y
            )
            guard isPointerDown, distance <= 14 else { return }
            isLongPressPanning = true
            didBeginLongPressPan = false
            selectedDate = nil
        }
    }

    private func endLongPressTimer() {
        isPointerDown = false
        longPressTask?.cancel()
        longPressTask = nil
    }

    private func panViewport(
        by delta: Double,
        presentation: StockChartPresentation,
        isExpanded: Bool
    ) {
        let full = presentation.xDomain
        let current = presentation.clampedVisibleXDomain(
            visibleXDomain ?? presentation.defaultVisibleXDomain(isExpanded: isExpanded)
        )
        let length = current.upperBound - current.lowerBound
        guard length > 0, full.upperBound > full.lowerBound else { return }
        let lower = min(
            max(current.lowerBound + delta, full.lowerBound),
            full.upperBound - length
        )
        visibleXDomain = lower...(lower + length)
    }

    private func zoomViewport(
        by scale: Double,
        presentation: StockChartPresentation,
        isExpanded: Bool
    ) {
        let full = presentation.xDomain
        let current = presentation.clampedVisibleXDomain(
            visibleXDomain ?? presentation.defaultVisibleXDomain(isExpanded: isExpanded)
        )
        let currentLength = current.upperBound - current.lowerBound
        let fullLength = full.upperBound - full.lowerBound
        guard currentLength > 0, fullLength > 0 else { return }
        let newLength = min(max(currentLength * scale, 12), fullLength)
        let center = (current.lowerBound + current.upperBound) / 2
        let lower = min(
            max(center - newLength / 2, full.lowerBound),
            full.upperBound - newLength
        )
        visibleXDomain = lower...(lower + newLength)
    }

    @ViewBuilder
    private func summary(_ presentation: StockChartPresentation) -> some View {
        if let point = presentation.selectedPoint(at: selectedDate) {
            selectedPointSummary(point, presentation: presentation)
        } else {
            summaryPlaceholder(presentation)
        }
    }

    private func selectedPointSummary(
        _ point: StockChartPoint,
        presentation: StockChartPresentation
    ) -> some View {
        let indicator = presentation.technicalIndicator(at: point)
        let selections = presentation.transactionSelections(at: point)
        let volumeText = point.volume.map(StockChartPresentation.volumeText) ?? "--"
        return VStack(alignment: .leading, spacing: 4) {
            summaryRow {
                Text("时间 \(presentation.chartDateText(point.date))")
                    .foregroundStyle(.secondary)
            }

            sessionSummaryRows(presentation, selectedPoint: point)

            if presentation.hasBasePriceChart, !selections.isEmpty {
                summaryRow {
                    ForEach(selections) { selection in
                        Text(transactionSummary(selection))
                            .fontWeight(.semibold)
                            .foregroundStyle(transactionColor(selection.type))
                    }
                }
            }

            if displayModes.contains(.movingAverage), let indicator {
                summaryRow {
                    movingAverageSummary(indicator)
                }
            }

            if displayModes.contains(.bollingerBands), let indicator {
                summaryRow {
                    bollingerSummary(indicator)
                }
            }

            if displayModes.contains(.volume) {
                summaryRow {
                    Text("\(volumeDirectionText(point))成交量 \(volumeText)")
                        .fontWeight(.medium)
                }
            }

            if displayModes.contains(.macd), let indicator {
                summaryRow {
                    Text("DIF \(StockChartPresentation.indicatorText(indicator.macdLine))")
                        .foregroundStyle(.purple)
                    Text("DEA \(StockChartPresentation.indicatorText(indicator.macdSignal))")
                        .foregroundStyle(.teal)
                    Text("MACD \(StockChartPresentation.indicatorText(indicator.macdHistogram))")
                        .foregroundStyle(.secondary)
                }
            }

            if displayModes.contains(.rsi), let rsi = indicator?.rsi14 {
                summaryRow {
                    Text("RSI14 \(StockChartPresentation.indicatorText(rsi))")
                        .fontWeight(.medium)
                        .foregroundStyle(.purple)
                    if let rsi30 = indicator?.rsi30 {
                        Text("RSI30 \(StockChartPresentation.indicatorText(rsi30))")
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let indicator {
                advancedIndicatorSummary(indicator)
            }
        }
        .appFont(.caption2.monospacedDigit())
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

    @ViewBuilder
    private func advancedIndicatorSummary(
        _ indicator: StockTechnicalIndicatorPoint
    ) -> some View {
        if displayModes.contains(.kdj) {
            summaryRow {
                indicatorSummaryText("K", indicator.stochasticK, color: .purple)
                indicatorSummaryText("D", indicator.stochasticD, color: .teal)
                indicatorSummaryText("J", indicator.stochasticJ, color: .orange)
            }
        }
        if displayModes.contains(.williamsR) {
            singleIndicatorSummary("W%R", indicator.williamsR, color: .purple)
        }
        if displayModes.contains(.cci) {
            singleIndicatorSummary("CCI", indicator.commodityChannelIndex, color: .purple)
        }
        if displayModes.contains(.dmi) {
            summaryRow {
                indicatorSummaryText("+DI", indicator.positiveDirectionalIndex, color: .green)
                indicatorSummaryText("-DI", indicator.negativeDirectionalIndex, color: .red)
                indicatorSummaryText("ADX", indicator.averageDirectionalIndex, color: .purple)
            }
        }
        if displayModes.contains(.momentum) {
            summaryRow {
                indicatorSummaryText("MTM", indicator.momentum, color: .purple)
                indicatorSummaryText("MTMMA", indicator.momentumAverage, color: .teal)
            }
        }
        if displayModes.contains(.trix) {
            summaryRow {
                indicatorSummaryText("TRIX", indicator.trix, color: .purple)
                indicatorSummaryText("MATRIX", indicator.trixSignal, color: .teal)
            }
        }
        if displayModes.contains(.volumeFlow) {
            summaryRow {
                volumeIndicatorSummaryText("OBV", indicator.onBalanceVolume, color: .purple)
                volumeIndicatorSummaryText("A/D", indicator.accumulationDistribution, color: .teal)
            }
        }
        if displayModes.contains(.mfi) {
            singleIndicatorSummary("MFI", indicator.moneyFlowIndex, color: .purple)
        }
        if displayModes.contains(.chaikinMoneyFlow) {
            singleIndicatorSummary("CMF", indicator.chaikinMoneyFlow, color: .purple)
        }
        if displayModes.contains(.psychologicalLine) {
            singleIndicatorSummary("PSY", indicator.psychologicalLine, color: .purple)
        }
        if displayModes.contains(.rateOfChange) {
            singleIndicatorSummary("ROC", indicator.rateOfChange, color: .purple)
        }
    }

    private func singleIndicatorSummary(
        _ title: String,
        _ value: Double?,
        color: Color
    ) -> some View {
        summaryRow {
            indicatorSummaryText(title, value, color: color)
        }
    }

    private func indicatorSummaryText(
        _ title: String,
        _ value: Double?,
        color: Color
    ) -> some View {
        Text("\(title) \(value.map(StockChartPresentation.indicatorText) ?? "--")")
            .foregroundStyle(color)
    }

    private func volumeIndicatorSummaryText(
        _ title: String,
        _ value: Double?,
        color: Color
    ) -> some View {
        Text("\(title) \(value.map(StockChartPresentation.volumeText) ?? "--")")
            .foregroundStyle(color)
    }

    private func summaryRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }

    @ViewBuilder
    private func sessionSummaryRows(
        _ presentation: StockChartPresentation,
        selectedPoint: StockChartPoint?
    ) -> some View {
        if let selectedPoint {
            // When extended-hours layers are combined, show only the layer
            // under the crosshair. Falling back to each session's last bar
            // makes the values look like they belong to the selected point.
            if presentation.hasPreMarketChart,
               presentation.isPreMarket(selectedPoint) {
                fixedExtendedHoursSummaryRow(
                    title: presentation.preMarketTitle,
                    point: selectedPoint,
                    color: .orange
                )
            } else if presentation.hasPostMarketChart,
                      presentation.isPostMarket(selectedPoint) {
                fixedExtendedHoursSummaryRow(
                    title: presentation.postMarketTitle,
                    point: selectedPoint,
                    color: .blue
                )
            } else if presentation.hasBasePriceChart {
                regularSummaryRow(point: selectedPoint, presentation: presentation)
            }
        } else if presentation.hasBasePriceChart {
            // Do not display pre-market/post-market closing values as if they
            // were part of the current selection. The regular session remains
            // the neutral, unselected summary.
            regularSummaryRow(
                point: presentation.plotPoints.last?.point,
                presentation: presentation
            )
        }
    }

    private func regularSummaryRow(
        point: StockChartPoint?,
        presentation: StockChartPresentation
    ) -> some View {
        summaryRow {
            if let point {
                Text("盘中")
                if displayModes.contains(.candlestick) {
                    Text("开 \(StockChartPresentation.plainPriceText(point.open))")
                    Text("高 \(StockChartPresentation.plainPriceText(point.high))")
                    Text("低 \(StockChartPresentation.plainPriceText(point.low))")
                    Text("收 \(StockChartPresentation.priceText(point.close, currencyCode: snapshot.currencyCode))")
                } else {
                    Text(StockChartPresentation.priceText(point.close, currencyCode: snapshot.currencyCode))
                }
            } else {
                Text("盘中").foregroundStyle(.secondary)
                Text("暂无数据").foregroundStyle(.secondary)
            }
        }
        .fontWeight(.medium)
        .foregroundStyle(.primary)
    }

    private func fixedExtendedHoursSummaryRow(
        title: String,
        point: StockChartPoint?,
        color: Color
    ) -> some View {
        summaryRow {
            Text(title)
            if let point {
                Text("价格 \(StockChartPresentation.priceText(point.close, currencyCode: snapshot.currencyCode))")
            } else {
                Text("暂无数据").foregroundStyle(.secondary)
            }
        }
        .fontWeight(.medium)
        .foregroundStyle(color)
    }

    private func summaryPlaceholder(_ presentation: StockChartPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let latestPoint = presentation.latestDisplayedPoint {
                summaryRow {
                    Text("时间 \(presentation.chartDateText(latestPoint.date))")
                        .foregroundStyle(.secondary)
                }
            } else {
                summaryRow {
                    Text("时间 --")
                        .foregroundStyle(.secondary)
                }
            }

            if displayModes.isEmpty {
                Text("未选择图表")
                    .foregroundStyle(.secondary)
            }

            sessionSummaryRows(presentation, selectedPoint: nil)

            if displayModes.contains(.movingAverage) {
                summaryRow {
                    Text("MA5").foregroundStyle(.teal)
                    Text("MA20").foregroundStyle(.purple)
                    Text("MA60").foregroundStyle(.brown)
                }
            }

            if displayModes.contains(.bollingerBands) {
                summaryRow {
                    Text("上轨").foregroundStyle(.mint)
                    Text("中轨").foregroundStyle(.teal)
                    Text("下轨").foregroundStyle(.cyan)
                }
            }

            if displayModes.contains(.volume) {
                Text("成交量").foregroundStyle(.secondary)
            }

            if displayModes.contains(.macd) {
                summaryRow {
                    Text("DIF").foregroundStyle(.purple)
                    Text("DEA").foregroundStyle(.teal)
                    Text("MACD").foregroundStyle(.secondary)
                }
            }

            if displayModes.contains(.rsi) {
                summaryRow {
                    Text("RSI14").foregroundStyle(.purple)
                    Text("RSI30").foregroundStyle(.orange)
                }
            }

            advancedIndicatorPlaceholder()
        }
        .appFont(.caption2.monospacedDigit())
    }

    @ViewBuilder
    private func advancedIndicatorPlaceholder() -> some View {
        if displayModes.contains(.kdj) {
            indicatorPlaceholderRow([("K", .purple), ("D", .teal), ("J", .orange)])
        }
        if displayModes.contains(.williamsR) { indicatorPlaceholderRow([("W%R", .purple)]) }
        if displayModes.contains(.cci) { indicatorPlaceholderRow([("CCI", .purple)]) }
        if displayModes.contains(.dmi) {
            indicatorPlaceholderRow([("+DI", .green), ("-DI", .red), ("ADX", .purple)])
        }
        if displayModes.contains(.momentum) {
            indicatorPlaceholderRow([("MTM", .purple), ("MTMMA", .teal)])
        }
        if displayModes.contains(.trix) {
            indicatorPlaceholderRow([("TRIX", .purple), ("MATRIX", .teal)])
        }
        if displayModes.contains(.volumeFlow) {
            indicatorPlaceholderRow([("OBV", .purple), ("A/D", .teal)])
        }
        if displayModes.contains(.mfi) { indicatorPlaceholderRow([("MFI", .purple)]) }
        if displayModes.contains(.chaikinMoneyFlow) {
            indicatorPlaceholderRow([("CMF", .purple)])
        }
        if displayModes.contains(.psychologicalLine) {
            indicatorPlaceholderRow([("PSY", .purple)])
        }
        if displayModes.contains(.rateOfChange) {
            indicatorPlaceholderRow([("ROC", .purple)])
        }
    }

    private func indicatorPlaceholderRow(
        _ items: [(String, Color)]
    ) -> some View {
        summaryRow {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0).foregroundStyle(item.1)
            }
        }
    }

    private func lineColor() -> Color {
        let quotePreviousClose = stock.previousClose.map { NSDecimalNumber(decimal: $0).doubleValue }
        let referencePrice: Double?
        switch range {
        case .intraday:
            referencePrice = cachedPresentation.cachedIntradayPreviousClose
                ?? StockChartPresentation.intradayPreviousClose(
                    snapshot: snapshot, market: stock.market,
                    quotePreviousClose: quotePreviousClose, quoteUpdatedAt: stock.lastQuoteAt
                )
        default:
            referencePrice = StockChartPresentation.rangeReferencePrice(
                snapshot: snapshot, range: range, market: stock.market,
                visibleXDomain: visibleXDomain,
                quotePreviousClose: quotePreviousClose, quoteUpdatedAt: stock.lastQuoteAt
            )
        }
        guard let referencePrice, referencePrice != 0,
              let latest = snapshot.latestPoint else { return .accentColor }
        return valueColor(latest.close - referencePrice)
    }

    private func candleColor(_ point: StockChartPoint) -> Color {
        valueColor(point.close - point.open)
    }

    private func volumeDirectionText(_ point: StockChartPoint) -> String {
        if point.close > point.open { return "买入" }
        if point.close < point.open { return "卖出" }
        return "持平"
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
        if !displayModes.isDisjoint(with: [.volume, .volumeFlow]) {
            return StockChartPresentation.volumeText(value)
        }
        if !displayModes.isDisjoint(with: [
            .macd, .rsi, .kdj, .williamsR, .cci, .dmi, .momentum,
            .trix, .mfi, .chaikinMoneyFlow, .psychologicalLine,
            .rateOfChange
        ]) {
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
