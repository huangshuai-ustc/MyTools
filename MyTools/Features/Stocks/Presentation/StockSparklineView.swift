#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

/// Inline intraday sparkline for a watchlist row.
///
/// Hand-drawn with `Canvas` rather than Swift Charts: `StockChartCanvas` and
/// `PortfolioChartCanvas` both hardcode much larger frames and own axes plus
/// drag/magnify gestures, and one `Chart` instance per row is measurably more
/// expensive in a long list. Hit testing is disabled so the row keeps its tap
/// and swipe gestures.
struct StockSparklineView: View {
    let series: StockSparklineSeries
    /// 涨跌零轴。由调用方从**行内报价**推出（价格 − 涨跌额），不从分时缓存另算：
    /// 盘前的零轴是 `StockChartPresentation` 特判过的上一结算收盘，与快照里的
    /// `previousClose` 不是同一个数，分开算会让虚线画在与本行百分比矛盾的一侧。
    let baseline: Double?
    let color: Color

    var body: some View {
        Canvas { context, size in
            let values = series.values
            guard !values.isEmpty else { return }

            // Include the baseline in the vertical range so the dashed
            // reference line is always visible.
            var lowest = series.lowest
            var highest = series.highest
            if let baseline {
                lowest = min(lowest, baseline)
                highest = max(highest, baseline)
            }
            let span = highest - lowest
            // A flat series (or a single point) sits on the vertical middle.
            let inset: CGFloat = 1.5
            let usableHeight = max(size.height - inset * 2, 1)

            func yPosition(_ value: Double) -> CGFloat {
                guard span > 0 else { return size.height / 2 }
                let ratio = (value - lowest) / span
                return inset + usableHeight * (1 - CGFloat(ratio))
            }

            func xPosition(_ index: Int) -> CGFloat {
                // 横坐标来自 `StockSparklineDomain`：整条轴代表本时段的全部交易分钟，
                // 所以刚开盘时折线只画在左侧，随时间从左往右生长。
                guard index < series.offsets.count else { return size.width }
                return size.width * CGFloat(series.offsets[index])
            }

            let points = values.indices.map { CGPoint(x: xPosition($0), y: yPosition(values[$0])) }

            if let baseline, span > 0 {
                let y = yPosition(baseline)
                var dashed = Path()
                dashed.move(to: CGPoint(x: 0, y: y))
                dashed.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    dashed,
                    with: .color(.secondary.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
                )
            }

            var line = Path()
            if points.count == 1 {
                // 只有一根柱时画一段贴左的短横线，配合末端圆点表示「刚开盘」。
                line.move(to: CGPoint(x: 0, y: points[0].y))
                line.addLine(to: CGPoint(x: max(points[0].x, 0.5), y: points[0].y))
            } else {
                line.move(to: points[0])
                for point in points.dropFirst() { line.addLine(to: point) }
            }

            // 渐变只填到折线已经走到的位置，时段尚未走完的右侧留白。
            let leadingX = points[0].x
            let trailingX = max(points.last?.x ?? leadingX, leadingX)
            var fill = line
            fill.addLine(to: CGPoint(x: trailingX, y: size.height))
            fill.addLine(to: CGPoint(x: leadingX, y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )

            if let last = points.last {
                let radius: CGFloat = 1.6
                let dot = Path(
                    ellipseIn: CGRect(
                        x: min(max(last.x - radius, 0), size.width - radius * 2),
                        y: last.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                context.fill(dot, with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#endif
