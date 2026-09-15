#if MYTOOLS_FEATURE_STOCKS
import SwiftUI

/// Flow layout for the compact chart summary rows. Keeping this layout
/// separate leaves the chart canvas focused on marks and interaction.
struct StockChartSummaryFlowLayout: Layout {
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
