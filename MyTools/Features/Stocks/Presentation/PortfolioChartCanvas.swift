#if MYTOOLS_FEATURE_STOCKS
import Charts
import SwiftUI

// MARK: - Presentation helpers

struct PortfolioPlotPoint: Identifiable {
    let index: Int
    let point: PortfolioValuePoint
    var id: Int { index }
    var x: Double { Double(index) }
}

struct PortfolioChartPresentation {
    let plotPoints: [PortfolioPlotPoint]
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let range: StockChartRange

    init(points: [PortfolioValuePoint], range: StockChartRange) {
        self.range = range
        let pp = points.enumerated().map { PortfolioPlotPoint(index: $0.offset, point: $0.element) }
        self.plotPoints = pp
        if pp.isEmpty {
            self.xDomain = 0...1
            self.yDomain = 0...1
        } else {
            self.xDomain = pp.first!.x...pp.last!.x
            let values = pp.map { NSDecimalNumber(decimal: $0.point.value).doubleValue }
            let lo = values.min()!
            let hi = values.max()!
            let pad = max((hi - lo) * 0.05, hi * 0.01, 1)
            self.yDomain = (lo - pad)...(hi + pad)
        }
    }

    var defaultVisibleXDomain: ClosedRange<Double> {
        guard !plotPoints.isEmpty else { return xDomain }
        let count: Int
        switch range {
        case .dayK: count = min(65, plotPoints.count)
        case .weekK: count = min(104, plotPoints.count)
        case .monthK: count = min(60, plotPoints.count)
        case .quarterK: count = min(40, plotPoints.count)
        case .yearK: return xDomain
        default: return xDomain
        }
        guard count > 1, plotPoints.count > 1 else { return xDomain }
        let first = plotPoints[plotPoints.count - count].x
        return clampedVisibleXDomain(first...plotPoints.last!.x)
    }

    func clampedVisibleXDomain(_ candidate: ClosedRange<Double>) -> ClosedRange<Double> {
        let fullLength = xDomain.upperBound - xDomain.lowerBound
        guard fullLength > 0 else { return xDomain }
        let candidateLength = candidate.upperBound - candidate.lowerBound
        guard candidateLength > 0 else { return xDomain }
        let length = min(candidateLength, fullLength)
        let lower = min(
            max(candidate.lowerBound, xDomain.lowerBound),
            xDomain.upperBound - length
        )
        return lower...(lower + length)
    }

    func closestPlotPoint(toX x: Double, in domain: ClosedRange<Double>) -> PortfolioPlotPoint? {
        guard !plotPoints.isEmpty else { return nil }
        let visible = plotPoints.filter { $0.x >= domain.lowerBound && $0.x <= domain.upperBound }
        let arr = visible.isEmpty ? plotPoints : visible
        return arr.min(by: { abs($0.x - x) < abs($1.x - x) })
    }

    func yDomain(for domain: ClosedRange<Double>) -> ClosedRange<Double> {
        let visible = plotPoints.filter { $0.x >= domain.lowerBound && $0.x <= domain.upperBound }
        guard !visible.isEmpty else { return yDomain }
        let values = visible.map { NSDecimalNumber(decimal: $0.point.value).doubleValue }
        let lo = values.min()!
        let hi = values.max()!
        let pad = max((hi - lo) * 0.05, hi * 0.01, 1)
        return (lo - pad)...(hi + pad)
    }

    func xAxisDates(in domain: ClosedRange<Double>, count: Int = 5) -> [Double] {
        let visible = plotPoints.filter { $0.x >= domain.lowerBound && $0.x <= domain.upperBound }
        guard visible.count > 1 else { return visible.map(\.x) }
        let stride = max(1, visible.count / count)
        return visible.enumerated().compactMap { i, p in i % stride == 0 ? p.x : nil }
    }

    func axisLabel(for x: Double) -> String {
        guard let pp = plotPoints.first(where: { Int($0.x) == Int(x) }) else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        switch range {
        case .intraday:
            fmt.dateFormat = "HH:mm"
        case .fiveDays:
            fmt.dateFormat = "MM-dd HH:mm"
        case .dayK:
            fmt.dateFormat = "MM-dd"
        case .weekK, .monthK:
            fmt.dateFormat = "yyyy-MM"
        case .quarterK, .yearK:
            fmt.dateFormat = "yyyy"
        }
        return fmt.string(from: pp.point.date)
    }

    func selectedPointLabel(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        switch range {
        case .intraday, .fiveDays:
            fmt.dateFormat = "MM-dd HH:mm"
        case .dayK:
            fmt.dateFormat = "yyyy-MM-dd"
        case .weekK, .monthK:
            fmt.dateFormat = "yyyy-MM"
        case .quarterK, .yearK:
            fmt.dateFormat = "yyyy"
        }
        return fmt.string(from: date)
    }
}

// MARK: - Canvas

struct PortfolioChartCanvas: View {
    let series: [PortfolioValueSeries]
    let range: StockChartRange

    @State private var visibleXDomain: ClosedRange<Double>?
    @State private var selectedDate: Date?
    @State private var isInteracting = false
    @State private var lastPanTranslation: CGFloat = 0
    @State private var lastMagnification: CGFloat = 1
    @State private var isLongPressPanning = false
    @State private var didBeginLongPressPan = false
    @State private var isPointerDown = false
    @State private var longPressTask: Task<Void, Never>?
    @State private var initialPointerLocation: CGPoint = .zero
    @State private var latestPointerLocation: CGPoint = .zero
    @State private var lastSelectionUpdateTime: TimeInterval = 0

    private var presentations: [String: PortfolioChartPresentation] {
        Dictionary(uniqueKeysWithValues: series.map { s in
            (s.id, PortfolioChartPresentation(
                points: aggregatedPoints(s.points),
                range: range
            ))
        })
    }

    private var combinedPresentation: PortfolioChartPresentation {
        let allPoints = series.flatMap { aggregatedPoints($0.points) }.sorted { $0.date < $1.date }
        return PortfolioChartPresentation(points: allPoints, range: range)
    }

    // Per-range filtering/aggregation
    private func aggregatedPoints(_ points: [PortfolioValuePoint]) -> [PortfolioValuePoint] {
        guard !points.isEmpty else { return [] }
        let cal = Calendar(identifier: .gregorian)
        switch range {
        case .intraday, .fiveDays:
            // Data already correctly scoped by service; return as-is
            return points
        case .dayK:
            return points
        case .weekK:
            return aggregateBucket(points) { date in
                cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            }
        case .monthK:
            return aggregateBucket(points) { date in
                cal.dateInterval(of: .month, for: date)?.start ?? date
            }
        case .quarterK:
            return aggregateBucket(points) { date in
                let month = cal.component(.month, from: date)
                let year = cal.component(.year, from: date)
                let qStartMonth = ((month - 1) / 3) * 3 + 1
                return cal.date(from: DateComponents(year: year, month: qStartMonth, day: 1)) ?? date
            }
        case .yearK:
            return aggregateBucket(points) { date in
                let year = cal.component(.year, from: date)
                return cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? date
            }
        }
    }

    private func aggregateBucket(
        _ points: [PortfolioValuePoint],
        bucket: (Date) -> Date
    ) -> [PortfolioValuePoint] {
        var grouped: [Date: Decimal] = [:]
        var groupedDates: [Date: Date] = [:]
        for point in points {
            let b = bucket(point.date)
            grouped[b] = point.value
            groupedDates[b] = point.date
        }
        return grouped.keys.sorted().compactMap { b in
            guard let val = grouped[b], let date = groupedDates[b] else { return nil }
            return PortfolioValuePoint(date: date, value: val)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let date = selectedDate {
                selectedHeader(date: date)
                    .transition(.opacity)
            }
            chartBody
        }
        .onChange(of: range) { _, _ in
            visibleXDomain = nil
            selectedDate = nil
        }
        .onChange(of: series.map(\.id)) { _, _ in
            visibleXDomain = nil
            selectedDate = nil
        }
    }

    // MARK: - Selected header

    @ViewBuilder
    private func selectedHeader(date: Date) -> some View {
        let pres = combinedPresentation
        VStack(alignment: .leading, spacing: 4) {
            Text(pres.selectedPointLabel(for: date))
                .appFont(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(series) { s in
                    if let pp = presentations[s.id]?.plotPoints.first(where: {
                        Calendar(identifier: .gregorian).isDate($0.point.date, inSameDayAs: date)
                    }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.label)
                                .appFont(.caption2)
                                .foregroundStyle(.secondary)
                            Text(formattedValue(pp.point.value, currencyCode: s.currencyCode))
                                .appFont(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chart

    private var chartBody: some View {
        let pres = combinedPresentation
        let domain = chartXDomain(pres: pres)
        return Chart {
            ForEach(series) { s in
                let sp = presentations[s.id] ?? PortfolioChartPresentation(points: [], range: range)
                ForEach(sp.plotPoints) { pp in
                    LineMark(
                        x: .value("序号", pp.x),
                        y: .value("价值", NSDecimalNumber(decimal: pp.point.value).doubleValue)
                    )
                    .foregroundStyle(by: .value("系列", s.label))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            if let date = selectedDate {
                selectionOverlayContent(date: date, pres: pres)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: pres.yDomain(for: domain))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: pres.xAxisDates(in: domain)) { value in
                AxisGridLine()
                if let x = value.as(Double.self) {
                    AxisValueLabel { Text(pres.axisLabel(for: x)).appFont(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let n = value.as(Double.self) {
                        Text(yLabel(n)).appFont(.caption2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                gestureLayer(proxy: proxy, geometry: geometry, pres: pres)
            }
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    guard range.isKLineRange else { return }
                    selectedDate = nil
                    let scale = value / max(lastMagnification, 0.01)
                    lastMagnification = value
                    let pres2 = combinedPresentation
                    zoomViewport(by: 1 / Double(scale), pres: pres2)
                }
                .onEnded { _ in lastMagnification = 1 }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ChartContentBuilder
    private func selectionOverlayContent(
        date: Date,
        pres: PortfolioChartPresentation
    ) -> some ChartContent {
        if let pp = pres.plotPoints.first(where: {
            Calendar(identifier: .gregorian).isDate($0.point.date, inSameDayAs: date)
        }) {
            RuleMark(x: .value("所选时间", pp.x))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(series) { s in
                if let spp = presentations[s.id]?.plotPoints.first(where: {
                    Calendar(identifier: .gregorian).isDate($0.point.date, inSameDayAs: date)
                }) {
                    PointMark(
                        x: .value("所选时间", spp.x),
                        y: .value("价值", NSDecimalNumber(decimal: spp.point.value).doubleValue)
                    )
                    .symbolSize(40)
                }
            }
        }
    }

    // MARK: - Gesture layer

    @ViewBuilder
    private func gestureLayer(
        proxy: ChartProxy,
        geometry: GeometryProxy,
        pres: PortfolioChartPresentation
    ) -> some View {
        let domain = chartXDomain(pres: pres)
        if range.isKLineRange {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
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
                                    lastPanTranslation = value.translation.width
                                    didBeginLongPressPan = true
                                } else if let plotFrame = proxy.plotFrame {
                                    let frame = geometry[plotFrame]
                                    let deltaPixels = value.translation.width - lastPanTranslation
                                    lastPanTranslation = value.translation.width
                                    let deltaDomain = -Double(deltaPixels / max(frame.width, 1))
                                        * (domain.upperBound - domain.lowerBound)
                                    panViewport(by: deltaDomain, pres: pres)
                                }
                            } else {
                                selectPoint(at: value.location, proxy: proxy, geometry: geometry,
                                            pres: pres, domain: domain)
                            }
                        }
                        .onEnded { value in
                            endLongPressTimer()
                            if !isLongPressPanning {
                                selectPoint(at: value.location, proxy: proxy, geometry: geometry,
                                            pres: pres, domain: domain, force: true)
                            }
                            isLongPressPanning = false
                            didBeginLongPressPan = false
                            lastPanTranslation = 0
                            initialPointerLocation = .zero
                            latestPointerLocation = .zero
                            isInteracting = false
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
                            selectPoint(at: value.location, proxy: proxy, geometry: geometry,
                                        pres: pres, domain: domain)
                        }
                        .onEnded { value in
                            selectPoint(at: value.location, proxy: proxy, geometry: geometry,
                                        pres: pres, domain: domain, force: true)
                            isInteracting = false
                        }
                )
        }
    }

    // MARK: - Viewport helpers

    private func chartXDomain(pres: PortfolioChartPresentation) -> ClosedRange<Double> {
        pres.clampedVisibleXDomain(
            visibleXDomain ?? pres.defaultVisibleXDomain
        )
    }

    private func panViewport(by delta: Double, pres: PortfolioChartPresentation) {
        let full = pres.xDomain
        let current = chartXDomain(pres: pres)
        let length = current.upperBound - current.lowerBound
        guard length > 0, full.upperBound > full.lowerBound else { return }
        let lower = min(max(current.lowerBound + delta, full.lowerBound), full.upperBound - length)
        visibleXDomain = lower...(lower + length)
    }

    private func zoomViewport(by scale: Double, pres: PortfolioChartPresentation) {
        let full = pres.xDomain
        let current = chartXDomain(pres: pres)
        let currentLength = current.upperBound - current.lowerBound
        let fullLength = full.upperBound - full.lowerBound
        guard currentLength > 0, fullLength > 0 else { return }
        let newLength = min(max(currentLength * scale, 12), fullLength)
        let center = (current.lowerBound + current.upperBound) / 2
        let lower = min(max(center - newLength / 2, full.lowerBound), full.upperBound - newLength)
        visibleXDomain = lower...(lower + newLength)
    }

    // MARK: - Point selection

    private func selectPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        pres: PortfolioChartPresentation,
        domain: ClosedRange<Double>,
        force: Bool = false
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            if selectedDate != nil { selectedDate = nil }
            return
        }
        let local = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        if let x: Double = proxy.value(atX: local.x),
           let pp = pres.closestPlotPoint(toX: x, in: domain) {
            let date = pp.point.date
            let now = Date.timeIntervalSinceReferenceDate
            guard force || now - lastSelectionUpdateTime >= (1 / 30) else { return }
            lastSelectionUpdateTime = now
            selectedDate = date
        }
    }

    // MARK: - Long press timer

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
            } catch { return }
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

    private func finishInteraction() {
        lastSelectionUpdateTime = 0
        isInteracting = false
    }

    // MARK: - Formatting

    private func yLabel(_ value: Double) -> String {
        if abs(value) >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if abs(value) >= 10_000 {
            return String(format: "%.0f万", value / 10_000)
        }
        return String(format: "%.0f", value)
    }

    private func formattedValue(_ value: Decimal, currencyCode: String) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d >= 1_000_000 {
            return String(format: "%.2fM \(currencyCode)", d / 1_000_000)
        } else if d >= 10_000 {
            return String(format: "%.2f万 \(currencyCode)", d / 10_000)
        }
        return String(format: "%.2f \(currencyCode)", d)
    }
}

#endif
