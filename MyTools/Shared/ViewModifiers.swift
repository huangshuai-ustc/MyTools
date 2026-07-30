import Foundation
import SwiftUI

enum AppListMetrics {
    static let rowVerticalInset: CGFloat = 10
    static let rowHorizontalInset: CGFloat = 16
    static let minimumRowHeight: CGFloat = 46
    static let recordContentSpacing: CGFloat = 10
}

enum AppDateFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter
    }()

    static func string(from date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

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
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
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

struct HiddenItemsVisibilityButton: View {
    let itemsDescription: String
    @Binding var isShowing: Bool

    var body: some View {
        Button { isShowing.toggle() } label: {
            Label(
                isShowing ? "隐藏 \(itemsDescription)" : "显示 \(itemsDescription)",
                systemImage: isShowing ? "eye.slash" : "eye"
            )
        }
    }
}

extension View {
    func appListRowStyle() -> some View {
        listRowInsets(EdgeInsets(
            top: AppListMetrics.rowVerticalInset,
            leading: AppListMetrics.rowHorizontalInset,
            bottom: AppListMetrics.rowVerticalInset,
            trailing: AppListMetrics.rowHorizontalInset
        ))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }

    @ViewBuilder
    func appListSpacing() -> some View {
        environment(\.defaultMinListRowHeight, AppListMetrics.minimumRowHeight)
#if os(iOS)
            .listSectionSpacing(.compact)
            .listRowSpacing(0)
#endif
    }

    func iOSLabeledBackButton(_ title: String) -> some View {
        modifier(IOSLabeledBackButtonModifier(title: title))
    }

    @ViewBuilder
    func iOSLargeSheet() -> some View {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad 上不要按内容收缩，否则表单会退化成无法操作的小浮层。
            presentationDetents([.large])
                .presentationSizing(.page)
                .presentationDragIndicator(.visible)
        } else {
            presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
#elseif os(macOS)
        frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: 900,
            minHeight: 500,
            idealHeight: 720
        )
#else
        self
#endif
    }

    @ViewBuilder
    func iOSAuthenticationSheet() -> some View {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // 认证表单与其他页面弹窗保持同样的 iPad 页面尺寸。
            presentationDetents([.large])
                .presentationSizing(.page)
                .presentationDragIndicator(.visible)
        } else {
            presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
#elseif os(macOS)
        frame(width: 440, height: 360)
#else
        self
#endif
    }

    func diagnosticScreen(_ name: String) -> some View {
        onAppear {
            DiagnosticLogger.shared.log(.navigation, "页面显示：\(name)")
        }
        .onDisappear {
            DiagnosticLogger.shared.log(.navigation, "页面离开：\(name)")
        }
    }

    @ViewBuilder
    func appReadableContent(maxWidth: CGFloat = 960) -> some View {
#if os(macOS)
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
#elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            self
        }
#else
        self
#endif
    }
}

private struct IOSLabeledBackButtonModifier: ViewModifier {
    let title: String

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        // 保留系统返回按钮，才能同时显示上一层标题并支持左侧边缘滑动返回。
        content.navigationBarBackButtonHidden(false)
#else
        content
#endif
    }
}
