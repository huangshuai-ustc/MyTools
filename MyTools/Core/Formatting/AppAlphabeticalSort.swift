import Foundation

/// Shared dictionary ordering for user-facing names. Han characters are
/// transliterated to unaccented Pinyin before comparison so Latin and Chinese
/// names participate in one alphabet instead of being split into script groups.
enum AppAlphabeticalSort {
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    static func comparison(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsKey = key(for: lhs)
        let rhsKey = key(for: rhs)
        let keyComparison = lhsKey.compare(
            rhsKey,
            options: [.numeric],
            range: nil,
            locale: comparisonLocale
        )
        guard keyComparison == .orderedSame else { return keyComparison }

        return lhs.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: comparisonLocale
        ).compare(
            rhs.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: comparisonLocale
            ),
            options: [.numeric],
            range: nil,
            locale: comparisonLocale
        )
    }

    static func isOrderedBefore(
        _ lhs: String,
        _ rhs: String,
        lhsTieBreaker: String = "",
        rhsTieBreaker: String = ""
    ) -> Bool {
        let result = comparison(lhs, rhs)
        if result != .orderedSame { return result == .orderedAscending }
        return lhsTieBreaker < rhsTieBreaker
    }

    private static func key(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let latin = trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
        return latin
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: comparisonLocale
            )
            .lowercased(with: comparisonLocale)
            .filter { !$0.isWhitespace }
    }
}
