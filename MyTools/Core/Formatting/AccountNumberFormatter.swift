import Foundation

/// Formats account identifiers for list and detail summaries without exposing the
/// full value. The stored value is never changed.
enum AccountNumberFormatter {
    static func masked(_ value: String, empty: String = "未填写账号") -> String {
        let characters = Array(value.filter { !$0.isWhitespace && $0 != "-" })
        guard !characters.isEmpty else { return empty }
        if characters.count > 8 {
            return String(characters.prefix(4)) + "••••" + String(characters.suffix(4))
        }
        if characters.count > 4 {
            return String(characters.prefix(2)) + "••••" + String(characters.suffix(2))
        }
        return String(characters.prefix(1)) + "••••" + String(characters.suffix(1))
    }
}
