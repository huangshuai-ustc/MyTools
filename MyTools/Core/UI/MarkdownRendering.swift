import Foundation
import SwiftUI

struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        Text(MarkdownRenderer.attributedString(from: markdown))
    }
}

enum MarkdownRenderer {
    static func attributedString(from markdown: String) -> AttributedString {
        let normalized = normalizeInlineMath(in: markdown)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: normalized, options: options))
            ?? AttributedString(normalized)
    }

    private static func normalizeInlineMath(in text: String) -> String {
        var result = ""
        var cursor = text.startIndex

        while let opening = text[cursor...].firstIndex(of: "$"),
              let contentStart = text.index(opening, offsetBy: 1, limitedBy: text.endIndex),
              let closing = text[contentStart...].firstIndex(of: "$"),
              closing > contentStart {
            result += text[cursor..<opening]
            result += normalizeMathExpression(String(text[contentStart..<closing]))
            cursor = text.index(after: closing)
        }

        return result + text[cursor...]
    }

    private static func normalizeMathExpression(_ expression: String) -> String {
        var result = ""
        var cursor = expression.startIndex

        while cursor < expression.endIndex {
            guard expression[cursor] == "^" else {
                result.append(expression[cursor])
                cursor = expression.index(after: cursor)
                continue
            }

            let exponentStart = expression.index(after: cursor)
            guard exponentStart < expression.endIndex else {
                result.append("^")
                cursor = exponentStart
                continue
            }

            let nextCursor: String.Index
            if expression[exponentStart] == "{" {
                guard let closing = expression[exponentStart...].firstIndex(of: "}") else {
                    result.append("^")
                    cursor = exponentStart
                    continue
                }
                let exponent = String(expression[expression.index(after: exponentStart)..<closing])
                result += superscript(exponent) ?? "^\(exponent)"
                nextCursor = expression.index(after: closing)
            } else {
                let exponentEnd = expression.index(after: exponentStart)
                let exponent = String(expression[exponentStart..<exponentEnd])
                result += superscript(exponent) ?? "^\(exponent)"
                nextCursor = exponentEnd
            }
            cursor = nextCursor
        }

        return result
    }

    private static func superscript(_ value: String) -> String? {
        let values: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾"
        ]
        let converted = value.compactMap { values[$0] }
        return converted.count == value.count ? String(converted) : nil
    }
}

struct MarkdownValueRow: View {
    let title: String
    let markdown: String
    var alignment: TextAlignment = .trailing
    var emptyValue = "未填写"

    var body: some View {
        if alignment == .leading {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                valueView
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            LabeledContent(title) {
                valueView
            }
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if markdown.isEmpty {
            Text(emptyValue)
                .foregroundStyle(.secondary)
        } else {
            MarkdownText(markdown)
                .multilineTextAlignment(alignment)
                .frame(
                    maxWidth: .infinity,
                    alignment: alignment == .leading ? .leading : .trailing
                )
                .copyableText(markdown)
        }
    }
}
