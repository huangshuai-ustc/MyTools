import Charts
import SwiftUI

#if os(iOS)
import UIKit
#endif

private enum StockChartDisplayMode: String, CaseIterable, Identifiable {
    case line
    case candlestick
    case movingAverage
    case bollingerBands
    case volume
    case macd
    case rsi

    var id: Self { self }

    var title: String {
        switch self {
        case .line: return "走势"
        case .candlestick: return "K 线"
        case .movingAverage: return "均线"
        case .bollingerBands: return "布林"
        case .volume: return "成交量"
        case .macd: return "MACD"
        case .rsi: return "RSI"
        }
    }

    var isPriceChart: Bool {
        switch self {
        case .line, .candlestick, .movingAverage, .bollingerBands:
            return true
        case .volume, .macd, .rsi:
            return false
        }
    }

    func isCompatible(with other: StockChartDisplayMode) -> Bool {
        guard self != other else { return true }
        guard isPriceChart, other.isPriceChart else { return false }
        let basePriceModes: Set<StockChartDisplayMode> = [.line, .candlestick]
        return !(basePriceModes.contains(self) && basePriceModes.contains(other))
    }
}

private enum StockChartVisualStyle {
    static let dataLine = StrokeStyle(
        lineWidth: 1.25,
        lineCap: .round,
        lineJoin: .round
    )
    static let referenceLineWidth: CGFloat = 0.75
}

private struct StockTransactionMarker: Identifiable {
    let id: UUID
    let date: Date
    let plotX: Double
    let plotPrice: Double
    let type: StockTransactionType
    let quantity: Decimal
    let unitPrice: Decimal
}

private struct StockTransactionSelection: Identifiable {
    let type: StockTransactionType
    let averagePrice: Decimal

    var id: StockTransactionType { type }
}

private struct StockChartPlotPoint: Identifiable {
    let point: StockChartPoint
    let x: Double

    var id: Date { point.id }
}

private struct StockTechnicalPlotPoint: Identifiable {
    let indicator: StockTechnicalIndicatorPoint
    let x: Double

    var id: Date { indicator.id }
}

private func technicalScoreColor(_ value: Int) -> Color {
    switch value {
    case 80...: return .green
    case 65..<80: return .teal
    case 50..<65: return .secondary
    case 35..<50: return .orange
    default: return .red
    }
}

struct StockWatchView: View {
    private struct LoadKey: Hashable {
        let market: StockMarket?
        let symbol: String
        let range: StockChartRange
    }

    private struct ScoreLoadKey: Hashable {
        let market: StockMarket?
        let symbol: String
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stockID: UUID

    @State private var selectedStockID: UUID?
    @State private var selectedRange: StockChartRange = .intraday
    @State private var selectedDisplayModes: Set<StockChartDisplayMode> = [.line]
    @State private var snapshot: StockChartSnapshot?
    @State private var technicalScore: StockInvestmentScore?
    @State private var selectedDate: Date?
    @State private var isRefreshing = false
    @State private var isTechnicalScoreRefreshing = false
    @State private var errorMessage: String?
    @State private var showsExpandedChart = false
    @State private var showsTechnicalScoreDetails = false
    @State private var orientationBeforeExpansion: Int?
    @State private var isInteractingWithChart = false

    private var stock: StockHolding? {
        let activeStockID = selectedStockID ?? stockID
        return store.stocks.first { $0.id == activeStockID }
    }

    private var loadKey: LoadKey {
        LoadKey(
            market: stock?.market,
            symbol: stock.map {
                StockHolding.normalizedSymbol($0.symbol, market: $0.market)
            } ?? "",
            range: selectedRange
        )
    }

    private var scoreLoadKey: ScoreLoadKey {
        ScoreLoadKey(
            market: stock?.market,
            symbol: stock.map {
                StockHolding.normalizedSymbol($0.symbol, market: $0.market)
            } ?? ""
        )
    }

    private var orderedSelectedDisplayModes: [StockChartDisplayMode] {
        StockChartDisplayMode.allCases.filter(selectedDisplayModes.contains)
    }

    private var hasPriceChart: Bool {
        selectedDisplayModes.contains { $0.isPriceChart }
    }

    private var hasBasePriceChart: Bool {
        selectedDisplayModes.contains(.line)
            || selectedDisplayModes.contains(.candlestick)
    }

    private var selectedChartModesTitle: String {
        let title = orderedSelectedDisplayModes.map(\.title).joined(separator: "、")
        return title.isEmpty ? "未选择" : title
    }

    private var outsideChartTapGesture: some Gesture {
        TapGesture().onEnded {
            guard !isInteractingWithChart else { return }
            selectedDate = nil
        }
    }

    var body: some View {
        Group {
            if let stock {
                watchList(for: stock)
            } else {
                ContentUnavailableView(
                    "股票已不存在",
                    systemImage: "chart.line.downtrend.xyaxis"
                )
            }
        }
        .navigationTitle("股票看盘")
        .iOSLabeledBackButton(ToolModule.myStocks.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let stock {
                    stockSwitcher(currentStock: stock)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshChartAndScore() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || stock == nil)
                .accessibilityLabel("刷新看盘行情")
            }
        }
        .task(id: loadKey) {
            selectedDate = nil
            await loadChart(forceRefresh: false)
            await pollMinuteChartIfNeeded()
        }
        .task(id: scoreLoadKey) {
            technicalScore = nil
            await loadTechnicalScore(forceRefresh: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await loadChart(forceRefresh: false, showsProgress: false)
                await loadTechnicalScore(forceRefresh: false, showsProgress: false)
            }
        }
        .sheet(isPresented: $showsTechnicalScoreDetails) {
            if let technicalScore {
                StockTechnicalScoreDetailView(score: technicalScore)
            }
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showsExpandedChart) {
            if let stock {
                expandedChart(for: stock)
            }
        }
#elseif os(macOS)
        .overlay {
            if showsExpandedChart, let stock {
                expandedChart(for: stock)
            }
        }
#endif
    }

    private func watchList(for stock: StockHolding) -> some View {
        List {
            Section {
                quoteHeader(for: stock)

                chartRangePicker

                chartModePicker
            }

            Section {
                chartSection(for: stock)
                    .frame(height: 260)
                    .padding(.vertical, 8)
            } header: {
                HStack {
                    Text("行情图")
                    Spacer()
                    Button(action: presentExpandedChart) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全屏查看行情图")
                    .help("全屏查看行情图")
                }
            }

            if let snapshot, let latest = snapshot.latestPoint {
                Section("当期数据") {
                    LabeledContent(
                        "开盘",
                        value: priceText(latest.open, currencyCode: snapshot.currencyCode)
                    )
                    LabeledContent(
                        "最高",
                        value: priceText(latest.high, currencyCode: snapshot.currencyCode)
                    )
                    LabeledContent(
                        "最低",
                        value: priceText(latest.low, currencyCode: snapshot.currencyCode)
                    )
                    LabeledContent(
                        "收盘 / 最新",
                        value: priceText(latest.close, currencyCode: snapshot.currencyCode)
                    )
                    if let volume = latest.volume {
                        LabeledContent("成交量", value: volumeText(volume))
                    }
                }

                Section {
                    LabeledContent("行情来源", value: snapshot.source)
                    LabeledContent(
                        "行情时间",
                        value: AppDateFormatter.dateTimeString(from: snapshot.quoteUpdatedAt)
                    )
                    LabeledContent(
                        "获取时间",
                        value: AppDateFormatter.dateTimeString(from: snapshot.fetchedAt)
                    )
                } footer: {
                    Text("公开行情可能存在延迟，仅供查看，请以交易所和券商数据为准。")
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
        .simultaneousGesture(outsideChartTapGesture)
    }

    private var chartRangePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(StockChartRange.allCases) { range in
                    Button {
                        selectedRange = range
                    } label: {
                        Text(range.title)
                            .font(.caption.weight(
                                selectedRange == range ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                selectedRange == range ? Color.accentColor : Color.primary
                            )
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(
                                selectedRange == range
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        selectedRange == range ? .isSelected : []
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartModePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(StockChartDisplayMode.allCases) { mode in
                    let isAvailable = isChartModeAvailable(mode, in: snapshot)
                    let isSelected = selectedDisplayModes.contains(mode)
                    Button {
                        toggleChartMode(mode)
                    } label: {
                        Text(mode.title)
                            .font(.caption.weight(
                                isSelected ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                isSelected ? Color.accentColor : Color.primary
                            )
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable)
                    .opacity(isAvailable ? 1 : 0.45)
                    .accessibilityAddTraits(
                        isSelected ? .isSelected : []
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleChartMode(_ mode: StockChartDisplayMode) {
        if selectedDisplayModes.contains(mode) {
            selectedDisplayModes.remove(mode)
        } else {
            selectedDisplayModes = Set(
                selectedDisplayModes.filter { mode.isCompatible(with: $0) }
            )
            selectedDisplayModes.insert(mode)
        }
        selectedDate = nil
    }

    private func stockSwitcher(currentStock: StockHolding) -> some View {
        Menu {
            ForEach(StockMarket.displayOrder) { market in
                let stocks = store.stocks.filter {
                    $0.market == market && $0.hasConfiguredSymbol
                }
                if !stocks.isEmpty {
                    Section(market.title) {
                        ForEach(stocks) { candidate in
                            Button {
                                selectStock(candidate.id)
                            } label: {
                                if candidate.id == currentStock.id {
                                    Label(
                                        "\(candidate.displayName) · \(candidate.symbol)",
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text("\(candidate.displayName) · \(candidate.symbol)")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentStock.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.headline)
        }
        .accessibilityLabel("切换看盘股票，当前为\(currentStock.displayName)")
        .help("切换看盘股票")
    }

    private func selectStock(_ id: UUID) {
        guard stock?.id != id else { return }
        selectedStockID = id
        snapshot = nil
        technicalScore = nil
        selectedDate = nil
        errorMessage = nil
    }

    private func quoteHeader(for stock: StockHolding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StockMarketBadge(market: stock.market)
                Text(stock.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(stock.symbol)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Label(
                    StockMarketTradingCalendar.isOpen(stock.market) ? "交易中" : "已休市",
                    systemImage: StockMarketTradingCalendar.isOpen(stock.market)
                        ? "circle.fill"
                        : "moon.zzz"
                )
                .font(.caption)
                .foregroundStyle(
                    StockMarketTradingCalendar.isOpen(stock.market) ? .green : .secondary
                )
            }

            if let snapshot, let latest = snapshot.latestPoint {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(priceText(latest.close, currencyCode: snapshot.currencyCode))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        if let performance = rangePerformance(
                            for: snapshot,
                            range: selectedRange
                        ) {
                            HStack(spacing: 10) {
                                Text(
                                    signedPriceText(
                                        performance.change,
                                        currencyCode: snapshot.currencyCode
                                    )
                                )
                                Text(StockValueFormatter.percent(Decimal(performance.percent)))
                            }
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(
                                valueColor(performance.change, market: stock.market)
                            )
                        }
                    }
                    Spacer(minLength: 8)
                    technicalScoreButton
                }
            } else if isRefreshing {
                ProgressView("正在获取行情")
                    .controlSize(.small)
            }

            if snapshot != nil, let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var technicalScoreButton: some View {
        if let technicalScore {
            Button {
                showsTechnicalScoreDetails = true
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("技术机会分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(technicalScore.value)")
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(technicalScoreColor(technicalScore.value))
                        Text("/ 100")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 82, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "技术机会分 \(technicalScore.value) 分，\(technicalScore.levelTitle)"
            )
            .help("查看技术机会分构成")
        } else if isTechnicalScoreRefreshing {
            VStack(alignment: .trailing, spacing: 6) {
                Text("技术机会分")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }
            .frame(minWidth: 82, alignment: .trailing)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text("技术机会分")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("--")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 82, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func chartSection(for stock: StockHolding) -> some View {
        if let snapshot, !snapshot.points.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                chartSummaryHeader(snapshot, stock: stock)
                if selectedDisplayModes.isEmpty {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stockChart(snapshot, stock: stock, isExpanded: false)
                }
            }
        } else if isRefreshing {
            HStack {
                Spacer()
                ProgressView("正在获取行情")
                Spacer()
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(errorMessage ?? "该时段暂无可用行情")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await loadChart(forceRefresh: true) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stockChart(
        _ snapshot: StockChartSnapshot,
        stock: StockHolding,
        isExpanded: Bool
    ) -> some View {
        let plotPoints = chartPlotPoints(for: snapshot)
        let technicalPlotPoints = technicalPlotPoints(
            for: plotPoints,
            in: snapshot
        )
        let selectedPlotPoint = selectedPlotPoint(in: plotPoints)
        let selectedTechnicalPlotPoint = selectedTechnicalPlotPoint(
            in: technicalPlotPoints
        )
        let transactionMarkers = transactionMarkers(for: stock, in: snapshot)
        let xDomain = xDomain(for: plotPoints)
        let domain = yDomain(
            for: snapshot,
            technicalPlotPoints: technicalPlotPoints
        )

        return Chart {
            if hasBasePriceChart,
               selectedRange == .intraday,
               let previousClose = snapshot.previousClose,
               domain.contains(previousClose) {
                RuleMark(y: .value("昨收", previousClose))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth,
                        dash: [4, 3]
                    ))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("昨收 \(plainPriceText(previousClose))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }

            if selectedDisplayModes.contains(.line) {
                ForEach(plotPoints) { plotPoint in
                    LineMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("价格", plotPoint.point.close)
                    )
                    .foregroundStyle(
                        lineColor(
                            for: snapshot,
                            market: stock.market,
                            range: selectedRange
                        )
                    )
                    .lineStyle(StockChartVisualStyle.dataLine)
                    .interpolationMethod(.linear)
                }
            }

            if selectedDisplayModes.contains(.candlestick) {
                ForEach(plotPoints) { plotPoint in
                    RuleMark(
                        x: .value("时间", plotPoint.x),
                        yStart: .value("最低", plotPoint.point.low),
                        yEnd: .value("最高", plotPoint.point.high)
                    )
                    .foregroundStyle(candleColor(plotPoint.point, market: stock.market))

                    RectangleMark(
                        x: .value("时间", plotPoint.x),
                        yStart: .value("开盘", plotPoint.point.open),
                        yEnd: .value("收盘", plotPoint.point.close),
                        width: .fixed(candleWidth(
                            pointCount: snapshot.points.count,
                            isExpanded: isExpanded
                        ))
                    )
                    .foregroundStyle(candleColor(plotPoint.point, market: stock.market))
                }
            }

            if selectedDisplayModes.contains(.movingAverage) {
                ForEach(technicalPlotPoints) { plotPoint in
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

            if selectedDisplayModes.contains(.bollingerBands) {
                ForEach(technicalPlotPoints) { plotPoint in
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

            if selectedDisplayModes.contains(.volume) {
                ForEach(plotPoints) { plotPoint in
                    if let volume = plotPoint.point.volume {
                        BarMark(
                            x: .value("时间", plotPoint.x),
                            y: .value("成交量", volume),
                            width: .fixed(indicatorBarWidth(
                                pointCount: plotPoints.count,
                                isExpanded: isExpanded
                            ))
                        )
                        .foregroundStyle(
                            candleColor(plotPoint.point, market: stock.market)
                                .opacity(0.72)
                        )
                    }
                }
            }

            if selectedDisplayModes.contains(.macd) {
                RuleMark(y: .value("零轴", 0))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(
                        lineWidth: StockChartVisualStyle.referenceLineWidth
                    ))
                ForEach(technicalPlotPoints) { plotPoint in
                    BarMark(
                        x: .value("时间", plotPoint.x),
                        y: .value("MACD", plotPoint.indicator.macdHistogram),
                        width: .fixed(indicatorBarWidth(
                            pointCount: plotPoints.count,
                            isExpanded: isExpanded
                        ))
                    )
                    .foregroundStyle(
                        valueColor(
                            plotPoint.indicator.macdHistogram,
                            market: stock.market
                        ).opacity(0.68)
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

            if selectedDisplayModes.contains(.rsi) {
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
                ForEach(technicalPlotPoints) { plotPoint in
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

            if hasBasePriceChart {
                ForEach(transactionMarkers) { marker in
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
                if hasBasePriceChart {
                    PointMark(
                        x: .value("所选时间", selectedPlotPoint.x),
                        y: .value("所选价格", selectedPlotPoint.point.close)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
                if selectedDisplayModes.contains(.volume),
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
                if selectedDisplayModes.contains(.macd) {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选 DIF", selectedTechnicalPlotPoint.indicator.macdLine)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
                if selectedDisplayModes.contains(.rsi),
                   let rsi = selectedTechnicalPlotPoint.indicator.rsi14 {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选 RSI", rsi)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                }
                if !hasBasePriceChart,
                   selectedDisplayModes.contains(.movingAverage),
                   let movingAverage = selectedTechnicalPlotPoint.indicator.movingAverage5
                    ?? selectedTechnicalPlotPoint.indicator.movingAverage20
                    ?? selectedTechnicalPlotPoint.indicator.movingAverage60 {
                    PointMark(
                        x: .value("所选时间", selectedTechnicalPlotPoint.x),
                        y: .value("所选均线", movingAverage)
                    )
                    .foregroundStyle(Color.primary)
                    .symbolSize(36)
                } else if !hasBasePriceChart,
                          selectedDisplayModes.contains(.bollingerBands),
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
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: xAxisValues(for: plotPoints, isExpanded: isExpanded)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let x = value.as(Double.self),
                       let plotPoint = plotPoint(closestTo: x, in: plotPoints) {
                        Text(axisLabelText(plotPoint.point.date))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            if selectedDisplayModes.contains(.rsi) {
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
            domain: xDomain,
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
                                isInteractingWithChart = true
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
                                   let plotPoint = plotPoint(closestTo: x, in: plotPoints) {
                                    selectedDate = plotPoint.point.date
                                }
                            }
                            .onEnded { _ in
                                Task { @MainActor in
                                    await Task.yield()
                                    isInteractingWithChart = false
                                }
                            }
                    )
            }
        }
        .accessibilityLabel(
            "\(stock.displayName)\(selectedRange.title)\(selectedChartModesTitle)图"
        )
    }

    @ViewBuilder
    private func chartSummaryHeader(
        _ snapshot: StockChartSnapshot,
        stock: StockHolding
    ) -> some View {
        selectedPointSummary(snapshot, stock: stock)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)
    }

    @ViewBuilder
    private func selectedPointSummary(
        _ snapshot: StockChartSnapshot,
        stock: StockHolding
    ) -> some View {
        if let point = selectedPoint(in: snapshot) {
            let indicator = technicalIndicatorPoint(at: point, in: snapshot)
            let transactionSelections = selectedTransactionSelections(
                at: point,
                for: stock,
                in: snapshot
            )
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    Text(chartDateText(point.date))
                        .foregroundStyle(.secondary)

                    if hasPriceChart {
                        Text(priceText(point.close, currencyCode: snapshot.currencyCode))
                            .fontWeight(.medium)
                    }

                    if hasBasePriceChart {
                        ForEach(transactionSelections) { selection in
                            Text(
                                plainPriceText(
                                    NSDecimalNumber(
                                        decimal: selection.averagePrice
                                    ).doubleValue
                                )
                            )
                            .fontWeight(.semibold)
                            .foregroundStyle(transactionColor(selection.type))
                        }
                    }

                    if selectedDisplayModes.contains(.candlestick) {
                        Text("高 \(plainPriceText(point.high))  低 \(plainPriceText(point.low))")
                            .foregroundStyle(.secondary)
                    }

                    if selectedDisplayModes.contains(.movingAverage), let indicator {
                        if let value = indicator.movingAverage5 {
                            Text("MA5 \(plainPriceText(value))")
                                .foregroundStyle(.teal)
                        }
                        if let value = indicator.movingAverage20 {
                            Text("MA20 \(plainPriceText(value))")
                                .foregroundStyle(.purple)
                        }
                        if let value = indicator.movingAverage60 {
                            Text("MA60 \(plainPriceText(value))")
                                .foregroundStyle(.brown)
                        }
                    }

                    if selectedDisplayModes.contains(.bollingerBands), let indicator {
                        if let value = indicator.bollingerUpper {
                            Text("上 \(plainPriceText(value))")
                                .foregroundStyle(.mint)
                        }
                        if let value = indicator.bollingerMiddle {
                            Text("中 \(plainPriceText(value))")
                                .foregroundStyle(.teal)
                        }
                        if let value = indicator.bollingerLower {
                            Text("下 \(plainPriceText(value))")
                                .foregroundStyle(.cyan)
                        }
                    }

                    if selectedDisplayModes.contains(.volume) {
                        Text(point.volume.map(volumeText) ?? "--")
                            .fontWeight(.medium)
                    }

                    if selectedDisplayModes.contains(.macd), let indicator {
                        Text("DIF \(indicatorText(indicator.macdLine))")
                            .foregroundStyle(.purple)
                        Text("DEA \(indicatorText(indicator.macdSignal))")
                            .foregroundStyle(.teal)
                        Text("MACD \(indicatorText(indicator.macdHistogram))")
                            .foregroundStyle(.secondary)
                    }

                    if selectedDisplayModes.contains(.rsi), let rsi = indicator?.rsi14 {
                        Text("RSI14 \(indicatorText(rsi))")
                            .fontWeight(.medium)
                            .foregroundStyle(.purple)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .font(.caption.monospacedDigit())
            .lineLimit(1)
        } else {
            chartSummaryPlaceholder
        }
    }

    @ViewBuilder
    private var chartSummaryPlaceholder: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if selectedDisplayModes.isEmpty {
                    Text("未选择图表").foregroundStyle(.secondary)
                }
                if selectedDisplayModes.contains(.line) {
                    Text("收盘价").foregroundStyle(.secondary)
                }
                if selectedDisplayModes.contains(.candlestick) {
                    Text("开盘 · 最高 · 最低 · 收盘").foregroundStyle(.secondary)
                }
                if selectedDisplayModes.contains(.movingAverage) {
                    Text("MA5").foregroundStyle(.teal)
                    Text("MA20").foregroundStyle(.purple)
                    Text("MA60").foregroundStyle(.brown)
                }
                if selectedDisplayModes.contains(.bollingerBands) {
                    Text("上轨").foregroundStyle(.mint)
                    Text("中轨").foregroundStyle(.teal)
                    Text("下轨").foregroundStyle(.cyan)
                }
                if selectedDisplayModes.contains(.volume) {
                    Text("成交量").foregroundStyle(.secondary)
                }
                if selectedDisplayModes.contains(.macd) {
                    Text("DIF").foregroundStyle(.purple)
                    Text("DEA").foregroundStyle(.teal)
                    Text("MACD").foregroundStyle(.secondary)
                }
                if selectedDisplayModes.contains(.rsi) {
                    Text("RSI14").foregroundStyle(.purple)
                }
            }
        }
        .scrollIndicators(.hidden)
        .font(.caption)
        .lineLimit(1)
    }

    private func selectedTransactionSelections(
        at point: StockChartPoint,
        for stock: StockHolding,
        in snapshot: StockChartSnapshot
    ) -> [StockTransactionSelection] {
        let markers = transactionMarkers(for: stock, in: snapshot).filter {
            $0.date == point.date
        }
        return StockTransactionType.allCases.compactMap { type in
            let matchingMarkers = markers.filter { $0.type == type }
            let totalQuantity = matchingMarkers.reduce(Decimal.zero) {
                $0 + $1.quantity
            }
            guard totalQuantity > 0 else { return nil }
            let totalAmount = matchingMarkers.reduce(Decimal.zero) {
                $0 + $1.quantity * $1.unitPrice
            }
            return StockTransactionSelection(
                type: type,
                averagePrice: totalAmount / totalQuantity
            )
        }
    }

    private func selectedPoint(in snapshot: StockChartSnapshot) -> StockChartPoint? {
        guard let selectedDate else { return nil }
        return snapshot.points.min {
            abs($0.date.timeIntervalSince(selectedDate))
                < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private func chartPlotPoints(for snapshot: StockChartSnapshot) -> [StockChartPlotPoint] {
        snapshot.points.enumerated().map { index, point in
            StockChartPlotPoint(
                point: point,
                x: chartXValue(for: point, index: index)
            )
        }
    }

    private func technicalPlotPoints(
        for plotPoints: [StockChartPlotPoint],
        in snapshot: StockChartSnapshot
    ) -> [StockTechnicalPlotPoint] {
        let xValuesByDate = Dictionary(uniqueKeysWithValues: plotPoints.map {
            ($0.point.date, $0.x)
        })
        let indicators = StockTechnicalIndicators.calculate(
            snapshot.indicatorPoints ?? plotPoints.map(\.point)
        )
        return indicators.compactMap { indicator in
            guard let x = xValuesByDate[indicator.date] else { return nil }
            return StockTechnicalPlotPoint(
                indicator: indicator,
                x: x
            )
        }
    }

    private func technicalIndicatorPoint(
        at point: StockChartPoint,
        in snapshot: StockChartSnapshot
    ) -> StockTechnicalIndicatorPoint? {
        StockTechnicalIndicators.calculate(snapshot.indicatorPoints ?? snapshot.points)
            .first { $0.date == point.date }
    }

    private func chartXValue(for point: StockChartPoint, index: Int) -> Double {
        switch selectedRange {
        case .intraday, .fiveDays:
            return Double(index)
        default:
            return point.date.timeIntervalSinceReferenceDate
        }
    }

    private func xDomain(
        for plotPoints: [StockChartPlotPoint]
    ) -> ClosedRange<Double> {
        guard let first = plotPoints.first?.x, let last = plotPoints.last?.x else {
            return 0...1
        }
        guard first != last else { return (first - 1)...(last + 1) }
        return min(first, last)...max(first, last)
    }

    private func selectedPlotPoint(
        in plotPoints: [StockChartPlotPoint]
    ) -> StockChartPlotPoint? {
        guard let selectedDate else { return nil }
        return plotPoints.min {
            abs($0.point.date.timeIntervalSince(selectedDate))
                < abs($1.point.date.timeIntervalSince(selectedDate))
        }
    }

    private func selectedTechnicalPlotPoint(
        in plotPoints: [StockTechnicalPlotPoint]
    ) -> StockTechnicalPlotPoint? {
        guard let selectedDate else { return nil }
        return plotPoints.min {
            abs($0.indicator.date.timeIntervalSince(selectedDate))
                < abs($1.indicator.date.timeIntervalSince(selectedDate))
        }
    }

    private func plotPoint(
        closestTo x: Double,
        in plotPoints: [StockChartPlotPoint]
    ) -> StockChartPlotPoint? {
        plotPoints.min { abs($0.x - x) < abs($1.x - x) }
    }

    private func transactionMarkers(
        for stock: StockHolding,
        in snapshot: StockChartSnapshot
    ) -> [StockTransactionMarker] {
        let calendar = chartCalendar(for: stock.market)
        return stock.transactions.compactMap { transaction in
            guard transaction.quantity > 0,
                  transaction.unitPrice > 0,
                  let transactionDate = marketDate(
                    for: transaction.tradedAt,
                    market: stock.market
                  ) else { return nil }

            let matchingPoints = snapshot.points.filter { point in
                if selectedRange == .fiveYears || selectedRange == .tenYears {
                    return calendar.dateInterval(of: .weekOfYear, for: point.date)?
                        .contains(transactionDate) == true
                }
                if selectedRange == .sinceInception {
                    return calendar.dateInterval(of: .month, for: point.date)?
                        .contains(transactionDate) == true
                }
                return calendar.isDate(point.date, inSameDayAs: transactionDate)
            }
            guard !matchingPoints.isEmpty else { return nil }
            let markerPoint: StockChartPoint
            if selectedRange == .intraday || selectedRange == .fiveDays {
                markerPoint = matchingPoints[matchingPoints.count / 2]
            } else {
                markerPoint = matchingPoints.last ?? matchingPoints[0]
            }
            guard let markerIndex = snapshot.points.firstIndex(where: { $0.id == markerPoint.id })
            else { return nil }
            return StockTransactionMarker(
                id: transaction.id,
                date: markerPoint.date,
                plotX: chartXValue(for: markerPoint, index: markerIndex),
                plotPrice: markerPoint.close,
                type: transaction.type,
                quantity: transaction.quantity,
                unitPrice: transaction.unitPrice
            )
        }
        .sorted { $0.date < $1.date }
    }

    private func marketDate(for date: Date, market: StockMarket) -> Date? {
        let localComponents = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day],
            from: date
        )
        var marketComponents = localComponents
        marketComponents.calendar = chartCalendar(for: market)
        marketComponents.timeZone = chartTimeZone(for: market)
        marketComponents.hour = 12
        return marketComponents.calendar?.date(from: marketComponents)
    }

    private func yDomain(
        for snapshot: StockChartSnapshot,
        technicalPlotPoints: [StockTechnicalPlotPoint]
    ) -> ClosedRange<Double> {
        if selectedDisplayModes.contains(.rsi) { return 0...100 }
        if selectedDisplayModes.contains(.volume) {
            let maximum = snapshot.points.compactMap(\.volume).max() ?? 0
            return 0...max(maximum * 1.08, 1)
        }
        if selectedDisplayModes.contains(.macd) {
            var values = [0.0]
            values += technicalPlotPoints.flatMap { point in
                [
                    point.indicator.macdLine,
                    point.indicator.macdSignal,
                    point.indicator.macdHistogram
                ]
            }
            return paddedDomain(for: values)
        }

        var values: [Double] = []
        if selectedDisplayModes.contains(.line) {
            values += snapshot.points.map(\.close)
        }
        if selectedDisplayModes.contains(.candlestick) {
            values += snapshot.points.flatMap { [$0.low, $0.high] }
        }
        if selectedDisplayModes.contains(.movingAverage) {
            values += technicalPlotPoints.flatMap { point in
                [
                    point.indicator.movingAverage5,
                    point.indicator.movingAverage20,
                    point.indicator.movingAverage60
                ].compactMap { $0 }
            }
        }
        if selectedDisplayModes.contains(.bollingerBands) {
            values += technicalPlotPoints.flatMap { point in
                [
                    point.indicator.bollingerUpper,
                    point.indicator.bollingerLower
                ].compactMap { $0 }
            }
        }
        return paddedDomain(for: values)
    }

    private func paddedDomain(for values: [Double]) -> ClosedRange<Double> {
        guard !values.isEmpty else { return 0...1 }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let spread = maximum - minimum
        let padding = max(spread * 0.08, max(abs(maximum) * 0.002, 0.01))
        return (minimum - padding)...(maximum + padding)
    }

    private func isChartModeAvailable(
        _ mode: StockChartDisplayMode,
        in snapshot: StockChartSnapshot?
    ) -> Bool {
        guard let snapshot else { return mode == .line }
        let indicatorPointCount = snapshot.indicatorPoints?.count ?? snapshot.points.count
        switch mode {
        case .line:
            return true
        case .candlestick:
            return snapshot.supportsCandlesticks
        case .movingAverage:
            return indicatorPointCount >= 5
        case .bollingerBands:
            return indicatorPointCount >= 20
        case .volume:
            return snapshot.points.contains { ($0.volume ?? 0) > 0 }
        case .macd:
            return indicatorPointCount >= 2
        case .rsi:
            return indicatorPointCount >= 15
        }
    }

    private func lineColor(
        for snapshot: StockChartSnapshot,
        market: StockMarket,
        range: StockChartRange
    ) -> Color {
        guard let performance = rangePerformance(for: snapshot, range: range) else {
            return .accentColor
        }
        return valueColor(performance.change, market: market)
    }

    private func rangePerformance(
        for snapshot: StockChartSnapshot,
        range: StockChartRange
    ) -> (change: Double, percent: Double)? {
        guard let first = snapshot.points.first,
              let latest = snapshot.latestPoint else { return nil }
        let referencePrice: Double
        if range == .intraday, let previousClose = snapshot.previousClose {
            referencePrice = previousClose
        } else {
            referencePrice = first.close
        }
        guard referencePrice != 0 else { return nil }
        let change = latest.close - referencePrice
        return (change, change / referencePrice)
    }

    private func candleColor(_ point: StockChartPoint, market: StockMarket) -> Color {
        valueColor(point.close - point.open, market: market)
    }

    private func transactionColor(_ type: StockTransactionType) -> Color {
        switch type {
        case .buy: return .blue
        case .sell: return .orange
        }
    }

    private func valueColor(_ value: Double, market: StockMarket) -> Color {
        guard value != 0 else { return .secondary }
        let scheme = stockAppearanceSettings.scheme(for: market)
        switch (value > 0, scheme) {
        case (true, .redRiseGreenFall), (false, .greenRiseRedFall): return .red
        case (true, .greenRiseRedFall), (false, .redRiseGreenFall): return .green
        }
    }

    private func candleWidth(pointCount: Int, isExpanded: Bool) -> CGFloat {
        let multiplier: CGFloat = isExpanded ? 1.4 : 1
        switch pointCount {
        case 0...40: return 7 * multiplier
        case 41...100: return 4 * multiplier
        default: return 2 * multiplier
        }
    }

    private func indicatorBarWidth(pointCount: Int, isExpanded: Bool) -> CGFloat {
        switch pointCount {
        case 0...40: return isExpanded ? 8 : 5
        case 41...100: return isExpanded ? 5 : 2.5
        case 101...200: return isExpanded ? 3 : 1.25
        default: return isExpanded ? 1.1 : 0.75
        }
    }

    private func chartDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = stock.map { chartTimeZone(for: $0.market) } ?? .autoupdatingCurrent
        formatter.dateFormat = selectedRange == .intraday || selectedRange == .fiveDays
            ? "MM-dd HH:mm"
            : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func xAxisValues(
        for plotPoints: [StockChartPlotPoint],
        isExpanded: Bool
    ) -> [Double] {
        guard plotPoints.count > 1 else { return plotPoints.map(\.x) }
        if selectedRange == .fiveDays, let market = stock?.market {
            let calendar = chartCalendar(for: market)
            var retainedDays = Set<Date>()
            return plotPoints.compactMap { plotPoint in
                let day = calendar.startOfDay(for: plotPoint.point.date)
                guard retainedDays.insert(day).inserted else { return nil }
                return plotPoint.x
            }
        }

        let desiredCount: Int
        switch selectedRange {
        case .intraday:
            desiredCount = isExpanded ? 10 : 6
        case .fiveDays:
            desiredCount = isExpanded ? 8 : 5
        case .oneMonth, .threeMonths, .oneYear:
            desiredCount = isExpanded ? 8 : 5
        case .fiveYears, .tenYears, .sinceInception:
            desiredCount = isExpanded ? 10 : 6
        }
        let finalIndex = plotPoints.count - 1
        let indices = Set((0..<desiredCount).map { position in
            Int(
                (Double(position) * Double(finalIndex) / Double(desiredCount - 1))
                    .rounded()
            )
        })
        return indices.sorted().map { plotPoints[$0].x }
    }

    private func axisLabelText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = stock.map { chartTimeZone(for: $0.market) } ?? .autoupdatingCurrent
        switch selectedRange {
        case .intraday:
            formatter.dateFormat = "HH:mm"
        case .fiveDays:
            formatter.dateFormat = "MM-dd"
        case .oneMonth, .threeMonths, .oneYear:
            formatter.dateFormat = "MM-dd"
        case .fiveYears, .tenYears, .sinceInception:
            formatter.dateFormat = "yyyy"
        }
        return formatter.string(from: date)
    }

    private func chartCalendar(for market: StockMarket) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chartTimeZone(for: market)
        return calendar
    }

    private func chartTimeZone(for market: StockMarket) -> TimeZone {
        let identifier: String
        switch market {
        case .aShare: identifier = "Asia/Shanghai"
        case .hongKong: identifier = "Asia/Hong_Kong"
        case .unitedStates: identifier = "America/New_York"
        }
        return TimeZone(identifier: identifier) ?? .gmt
    }

    private func priceText(_ value: Double, currencyCode: String) -> String {
        StockValueFormatter.price(Decimal(value), currencyCode: currencyCode)
    }

    private func plainPriceText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? "--"
    }

    private func indicatorText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? "--"
    }

    private func yAxisLabelText(_ value: Double) -> String {
        if selectedDisplayModes.contains(.volume) {
            return volumeText(value)
        }
        if selectedDisplayModes.contains(.macd) {
            return indicatorText(value)
        }
        return plainPriceText(value)
    }

    private func signedPriceText(_ value: Double, currencyCode: String) -> String {
        let prefix = value >= 0 ? "+" : "-"
        return prefix + priceText(abs(value), currencyCode: currencyCode)
    }

    private func volumeText(_ value: Double) -> String {
        switch abs(value) {
        case 100_000_000...:
            return String(format: "%.2f 亿", value / 100_000_000)
        case 10_000...:
            return String(format: "%.2f 万", value / 10_000)
        default:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: value)) ?? "--"
        }
    }

    private func expandedChart(for stock: StockHolding) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                chartRangePicker
                chartModePicker

                if let snapshot, !snapshot.points.isEmpty {
                    chartSummaryHeader(snapshot, stock: stock)
                    if selectedDisplayModes.isEmpty {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        stockChart(snapshot, stock: stock, isExpanded: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if isRefreshing {
                    ProgressView("正在获取行情")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "行情暂不可用",
                        systemImage: "chart.xyaxis.line",
                        description: Text(errorMessage ?? "该时段暂无可用行情")
                    )
                }
            }
            .padding(16)
            .navigationTitle("\(stock.displayName) · 行情图")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    stockSwitcher(currentStock: stock)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showsExpandedChart = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭全屏行情图")
                }
            }
        }
        .onAppear(perform: requestLandscapeOrientation)
        .onDisappear(perform: restorePreviousOrientation)
        .simultaneousGesture(outsideChartTapGesture)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func presentExpandedChart() {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            orientationBeforeExpansion = activeWindowScene?
                .effectiveGeometry.interfaceOrientation.rawValue
        }
#endif
        showsExpandedChart = true
    }

    private func requestLandscapeOrientation() {
#if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard showsExpandedChart, let scene = activeWindowScene else { return }
            AppOrientationController.allow(.landscape)
            topViewController(in: scene)?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
            ) { error in
                print("[StockWatch] 横屏切换失败：\(error.localizedDescription)")
            }
        }
#endif
    }

    private func restorePreviousOrientation() {
#if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard let scene = activeWindowScene else { return }
        let mask: UIInterfaceOrientationMask
        if let rawValue = orientationBeforeExpansion,
           let orientation = UIInterfaceOrientation(rawValue: rawValue) {
            switch orientation {
            case .portrait: mask = .portrait
            case .portraitUpsideDown: mask = .portraitUpsideDown
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            default: mask = .all
            }
        } else {
            mask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        }
        AppOrientationController.allow(.all)
        topViewController(in: scene)?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(
            UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        ) { error in
            print("[StockWatch] 恢复屏幕方向失败：\(error.localizedDescription)")
        }
        orientationBeforeExpansion = nil
#endif
    }

#if os(iOS)
    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func topViewController(in scene: UIWindowScene) -> UIViewController? {
        var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
#endif

    private func loadChart(forceRefresh: Bool, showsProgress: Bool = true) async {
        guard let stock else { return }
        let shouldShowProgress = showsProgress && snapshot == nil
        if shouldShowProgress { isRefreshing = true }
        defer { if shouldShowProgress { isRefreshing = false } }

        if !forceRefresh,
           let cached = await StockChartService.shared.cachedChart(
                for: stock,
                range: selectedRange
            ) {
            guard !Task.isCancelled else { return }
            snapshot = cached
            removeUnavailableChartModes(for: cached)
        }

        do {
            let updated = try await StockChartService.shared.fetchChart(
                for: stock,
                range: selectedRange,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
            snapshot = updated
            removeUnavailableChartModes(for: updated)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "行情获取失败。"
        }
    }

    private func refreshChartAndScore() async {
        await loadChart(forceRefresh: true)
        if selectedRange == .oneYear, let snapshot {
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: snapshot.indicatorPoints ?? snapshot.points
                )
            )
        } else {
            await loadTechnicalScore(forceRefresh: true, showsProgress: false)
        }
    }

    private func loadTechnicalScore(
        forceRefresh: Bool,
        showsProgress: Bool = true
    ) async {
        guard let stock else { return }
        let requestedKey = scoreLoadKey
        let shouldShowProgress = showsProgress && technicalScore == nil
        if shouldShowProgress { isTechnicalScoreRefreshing = true }
        defer { if shouldShowProgress { isTechnicalScoreRefreshing = false } }

        if !forceRefresh,
           let cached = await StockChartService.shared.cachedChart(
                for: stock,
                range: .oneYear
           ) {
            guard !Task.isCancelled, scoreLoadKey == requestedKey else { return }
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: cached.indicatorPoints ?? cached.points
                )
            )
        }

        do {
            let updated = try await StockChartService.shared.fetchChart(
                for: stock,
                range: .oneYear,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled, scoreLoadKey == requestedKey else { return }
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: updated.indicatorPoints ?? updated.points
                )
            )
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func removeUnavailableChartModes(for snapshot: StockChartSnapshot) {
        selectedDisplayModes = Set(
            selectedDisplayModes.filter { isChartModeAvailable($0, in: snapshot) }
        )
    }

    private func pollMinuteChartIfNeeded() async {
        guard selectedRange == .intraday || selectedRange == .fiveDays else { return }
        while !Task.isCancelled {
            do {
                let interval = selectedRange == .intraday ? 30 : 60
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  scenePhase == .active,
                  let stock,
                  StockMarketTradingCalendar.isOpen(stock.market) else { continue }
            await loadChart(forceRefresh: false, showsProgress: false)
        }
    }
}

private struct StockTechnicalScoreDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let score: StockInvestmentScore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(score.value)")
                                .font(.largeTitle.weight(.bold).monospacedDigit())
                                .foregroundStyle(technicalScoreColor(score.value))
                            Text("/ 100")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(score.levelTitle)
                                .font(.headline)
                        }
                        Text("截至 \(AppDateFormatter.string(from: score.date)) 的日线技术机会")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("连续证据") {
                    ForEach(score.factors) { factor in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(factor.kind.title)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(factor.directionTitle) · \(factor.displayValue)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: Double(factor.displayValue),
                                total: 100
                            )
                            .tint(technicalScoreColor(factor.displayValue))
                            Text(factor.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                    }
                }

                if !score.adjustments.isEmpty {
                    Section("非线性调整") {
                        ForEach(score.adjustments, id: \.self) { adjustment in
                            Text(adjustment)
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    LabeledContent("模型版本", value: score.modelVersion)
                    if let legacyValue = score.legacyValue {
                        LabeledContent("V1 对照分", value: "\(legacyValue)")
                    }
                    if score.unadjustedValue != score.value {
                        LabeledContent("可信度调整前", value: "\(score.unadjustedValue)")
                    }
                    LabeledContent("周期", value: "日线")
                    LabeledContent("历史样本", value: "\(score.sampleCount) 个交易日")
                    LabeledContent(
                        "数据可信度",
                        value: "\(score.confidence.rawValue) · \(Int((score.confidenceValue * 100).rounded()))%"
                    )
                } header: {
                    Text("数据基础")
                } footer: {
                    Text(
                        "各项证据不会直接相加。模型会考虑信号共振、冲突、波动与回撤，并按数据可信度向50分收缩。当前仍只使用历史价量数据，不包含估值、财务、行业和消息面。"
                    )
                }
            }
            .navigationTitle("技术机会分")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭技术机会分")
                }
            }
        }
    }
}
