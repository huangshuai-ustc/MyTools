import ActivityKit
import SwiftUI
import WidgetKit

@main
struct StockMarketWidgetBundle: WidgetBundle {
    var body: some Widget {
        StockMarketLiveActivityWidget()
    }
}

struct StockMarketLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StockMarketActivityAttributes.self) { context in
            StockMarketLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("市场开市中", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MarketOverviewRows(markets: context.state.markets, compact: true)
                }
            } compactLeading: {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(compactChange(context.state.markets))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(trendColor(context.state.markets.first?.trend ?? 0))
            } minimal: {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }

    private func compactChange(_ markets: [StockMarketActivityAttributes.MarketOverview]) -> String {
        guard let first = markets.first else { return "--" }
        return markets.count == 1 ? first.todayChangeRate : "\(markets.count)市"
    }
}

/// The extension has its own environment and therefore cannot see the color scheme
/// forced by the main app. Prefer the appearance carried by the activity state; when
/// the app follows the system, retain the lock screen's current system appearance.
private struct StockMarketLockScreenView: View {
    let context: ActivityViewContext<StockMarketActivityAttributes>
    @Environment(\.colorScheme) private var systemColorScheme

    private var colorScheme: ColorScheme {
        switch context.state.appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return systemColorScheme
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.09)
            : Color(red: 0.97, green: 0.97, blue: 0.98)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.blue)
                Text(context.attributes.title)
                    .font(.headline)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    // 过了 staleDate 还没有新数据（App 被挂起），明确提示而不是让旧数字冒充实时。
                    Text(context.isStale ? "等待更新" : "行情更新")
                        .font(.caption2)
                        .foregroundStyle(context.isStale ? Color.orange : Color.secondary)
                    Text(context.state.updatedAt, style: .time)
                        .font(.caption.monospacedDigit())
                }
            }
            MarketOverviewRows(markets: context.state.markets, compact: false)
        }
        .padding(16)
        // iOS can render activityBackgroundTint as a translucent system material.
        // Paint the content surface as well so detailed wallpapers never bleed through.
        .background(backgroundColor)
        .environment(\.colorScheme, colorScheme)
        .activityBackgroundTint(backgroundColor)
        .activitySystemActionForegroundColor(colorScheme == .dark ? .white : .black)
    }
}

private struct MarketOverviewRows: View {
    let markets: [StockMarketActivityAttributes.MarketOverview]
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 5 : 8) {
            ForEach(markets) { market in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(market.name)
                            .font(compact ? .caption : .subheadline.weight(.semibold))
                        Text(market.currencyCode)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(market.marketValue)
                        .font((compact ? Font.caption : .body).monospacedDigit().weight(.semibold))
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(market.todayChange)
                        Text(market.todayChangeRate)
                            .opacity(0.78)
                    }
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(trendColor(market.trend))
                }
            }
        }
    }
}

private func trendColor(_ trend: Int) -> Color {
    if trend > 0 { return .red }
    if trend < 0 { return .green }
    return .secondary
}
