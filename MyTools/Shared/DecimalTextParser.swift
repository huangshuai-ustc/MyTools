import Foundation

enum DecimalTextParser {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func decimal(from text: String) -> Decimal? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        guard !normalized.isEmpty else { return nil }
        return Decimal(string: normalized, locale: locale)
    }

    static func optionalDecimal(from text: String) -> Decimal? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? 0
            : decimal(from: text)
    }
}
