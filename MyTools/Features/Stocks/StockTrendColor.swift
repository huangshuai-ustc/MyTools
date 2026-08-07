import SwiftUI

enum StockTrendColor {
    @MainActor
    static func color(
        for value: Decimal,
        market: StockMarket,
        settings: StockAppearanceSettings,
        neutral: Color = .primary
    ) -> Color {
        color(for: value, scheme: settings.scheme(for: market), neutral: neutral)
    }

    @MainActor
    static func color(
        for value: Double,
        market: StockMarket,
        settings: StockAppearanceSettings,
        neutral: Color = .primary
    ) -> Color {
        color(for: value, scheme: settings.scheme(for: market), neutral: neutral)
    }

    static func color(
        for value: Decimal,
        scheme: StockRiseFallColorScheme,
        neutral: Color = .primary
    ) -> Color {
        color(isRising: value == 0 ? nil : value > 0, scheme: scheme, neutral: neutral)
    }

    static func color(
        for value: Double,
        scheme: StockRiseFallColorScheme,
        neutral: Color = .primary
    ) -> Color {
        color(isRising: value == 0 ? nil : value > 0, scheme: scheme, neutral: neutral)
    }

    private static func color(
        isRising: Bool?,
        scheme: StockRiseFallColorScheme,
        neutral: Color
    ) -> Color {
        guard let isRising else { return neutral }
        switch (isRising, scheme) {
        case (true, .redRiseGreenFall), (false, .greenRiseRedFall): return .red
        case (true, .greenRiseRedFall), (false, .redRiseGreenFall): return .green
        }
    }
}
