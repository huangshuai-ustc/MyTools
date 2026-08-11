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

    static func expression(from text: String) -> Decimal? {
        guard let normalized = normalizedExpression(text), normalized.count <= 256 else { return nil }
        var parser = DecimalExpressionParser(characters: Array(normalized))
        return parser.parse()
    }

    static func optionalExpression(from text: String) -> Decimal? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? 0
            : expression(from: text)
    }

    private static func normalizedExpression(_ text: String) -> String? {
        var result = ""
        for character in text {
            switch character {
            case "0"..."9", ".", "+", "-", "*", "/", "(", ")":
                result.append(character)
            case "０"..."９":
                guard let value = character.wholeNumberValue else { return nil }
                result.append(String(value))
            case "＋": result.append("+")
            case "－", "−": result.append("-")
            case "×", "＊", "x", "X": result.append("*")
            case "÷", "／": result.append("/")
            case "（": result.append("(")
            case "）": result.append(")")
            case "。": result.append(".")
            case ",", "，", " ", "\t", "\n", "\r": continue
            default: return nil
            }
        }
        return result.isEmpty ? nil : result
    }
}

private struct DecimalExpressionParser {
    let characters: [Character]
    var index = 0

    mutating func parse() -> Decimal? {
        guard let value = parseExpression(), index == characters.count else { return nil }
        return value
    }

    private mutating func parseExpression() -> Decimal? {
        guard var value = parseTerm() else { return nil }
        while let operation = current, operation == "+" || operation == "-" {
            index += 1
            guard let rhs = parseTerm() else { return nil }
            value = operation == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() -> Decimal? {
        guard var value = parseFactor() else { return nil }
        while let operation = current, operation == "*" || operation == "/" {
            index += 1
            guard let rhs = parseFactor(), operation != "/" || rhs != 0 else { return nil }
            value = operation == "*" ? value * rhs : value / rhs
        }
        return value
    }

    private mutating func parseFactor() -> Decimal? {
        if current == "+" {
            index += 1
            return parseFactor()
        }
        if current == "-" {
            index += 1
            guard let value = parseFactor() else { return nil }
            return -value
        }
        if current == "(" {
            index += 1
            guard let value = parseExpression(), current == ")" else { return nil }
            index += 1
            return value
        }
        return parseNumber()
    }

    private mutating func parseNumber() -> Decimal? {
        let start = index
        var hasDecimalPoint = false
        while let character = current {
            if character == "." {
                guard !hasDecimalPoint else { return nil }
                hasDecimalPoint = true
                index += 1
            } else if character >= "0", character <= "9" {
                index += 1
            } else {
                break
            }
        }
        guard index > start else { return nil }
        return Decimal(
            string: String(characters[start..<index]),
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private var current: Character? {
        index < characters.count ? characters[index] : nil
    }
}
