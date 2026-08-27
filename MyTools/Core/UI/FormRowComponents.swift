import SwiftUI

/// 详情页"标签+值"行：trailing 模式固定单行（长文本截断，可复制），leading 模式允许多行（地址/备注类）。
struct DetailValueRow: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    let value: String
    var alignment: TextAlignment = .trailing
    var emptyValue = "未填写"
    var isMonospaced = false
    var truncationMode: Text.TruncationMode = .tail

    var body: some View {
        if alignment == .leading {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .appFont(.body)
                    .foregroundStyle(.primary)
                valueText
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LabeledContent(title) {
                valueText
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if alignment == .leading {
            Text(value.isEmpty ? emptyValue : value)
                .copyableText(value.isEmpty ? nil : value)
        } else {
            Text(value.isEmpty ? emptyValue : value)
                .fontDesign(isMonospaced ? .monospaced : .default)
                .lineLimit(1)
                .truncationMode(truncationMode)
                .multilineTextAlignment(.trailing)
                .copyableText(value.isEmpty ? nil : value)
        }
    }

    /// 敏感值遮罩变体：`isRevealed` 为假时展示 `concealedValue`，且不允许复制未揭示的内容。
    /// `fontScale` 由调用处的 `@Environment(\.appFontScale)` 传入（静态函数无法直接持有 `@Environment`）。
    static func protected(
        _ title: String,
        value: String,
        concealedValue: String = "••••••",
        isRevealed: Bool,
        monospaced: Bool = false,
        truncationMode: Text.TruncationMode = .tail,
        fontScale: CGFloat? = nil
    ) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "未填写" : (isRevealed ? value : concealedValue))
                .fontDesign(monospaced && isRevealed ? .monospaced : .default)
                .lineLimit(1)
                .truncationMode(truncationMode)
                .multilineTextAlignment(.trailing)
                .copyableText(isRevealed && !value.isEmpty ? value : nil)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
    }

    /// 详情页超链接值行：可点击打开、长按复制，行高与其它 `DetailValueRow` 一致。`resolveURL` 用于把原始字符串解析为可跳转链接
    /// （不同模块的补全规则可能不同，例如是否允许缺省协议）；解析失败或值为空时退回普通文本展示。
    /// `fontScale` 由调用处的 `@Environment(\.appFontScale)` 传入（静态函数无法直接持有 `@Environment`）。
    static func link(
        _ title: String,
        urlString: String,
        emptyValue: String = "未填写",
        fontScale: CGFloat? = nil,
        resolveURL: (String) -> URL? = { string in
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
            return url
        }
    ) -> some View {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if let url = resolveURL(trimmed) {
                LabeledContent(title) {
                    Link(destination: url) {
                        Text(trimmed)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.trailing)
                    }
                    .copyableText(trimmed)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
            } else {
                DetailValueRow(title: title, value: trimmed, emptyValue: emptyValue)
            }
        }
    }
}

/// 编辑页"标签+单行输入框"行，固定最小行高，保证与其它行同高。
struct FieldEditorRow: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    let prompt: String
    @Binding var text: String
    var alignment: TextAlignment = .trailing
    var mode: IMESafeTextInputMode = .text
    var maxFieldWidth: CGFloat = 260

    var body: some View {
        LabeledContent(title) {
            IMESafeTextField(prompt: prompt, text: $text, alignment: alignment, mode: mode)
                .frame(maxWidth: maxFieldWidth)
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
    }
}

/// 编辑页"标签+日期选择器"行，固定最小行高，与 `FieldEditorRow`/`PickerFieldRow` 同高。
struct DateFieldRow: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    @Binding var date: Date
    var displayedComponents: DatePicker.Components = .date

    var body: some View {
        LabeledContent(title) {
            DatePicker("", selection: $date, displayedComponents: displayedComponents)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
    }
}

/// 编辑页"标签+选择器"行：包裹原生 `Picker`，强制外层高度与 `FieldEditorRow` 一致——原生 `Picker`/`Toggle` 行不可靠地遵循
/// `.environment(\.defaultMinListRowHeight, ...)`（`AppListSpacingModifier` 设置的地板值），导致同一 Section 里裸 `Picker`
/// 行比显式 `.frame(minHeight:)` 的行矮。仅用于同 Section 内与文本/数值/日期行混排、需要像素级同高的场景；
/// 独立成段或 `.segmented` 样式的全宽选择器不受此问题影响，无需包裹。
struct PickerFieldRow<Selection: Hashable, Content: View>: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    @Binding var selection: Selection
    @ViewBuilder let content: () -> Content

    var body: some View {
        LabeledContent(title) {
            Picker("", selection: $selection) {
                content()
            }
            .labelsHidden()
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
    }
}

/// 编辑页"标签+数值/算式输入框"行；可选算式支持与计算结果预览（预览文案由调用处的 `previewFormatter` 提供，避免 Core 依赖具体模块的货币格式化规则）。焦点绑定由调用处自行附加。
struct NumericFieldRow: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    let prompt: String
    @Binding var text: String
    var allowsExpression = false
    var maxFieldWidth: CGFloat = 260
    var previewFormatter: ((Decimal) -> String)?

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(prompt, text: $text)
                    .multilineTextAlignment(.trailing)
#if os(iOS)
                    .keyboardType(allowsExpression ? .numbersAndPunctuation : .decimalPad)
#endif
                if allowsExpression,
                   let previewFormatter,
                   text.contains(where: { "+-*/×÷（）()".contains($0) }),
                   let value = DecimalTextParser.expression(from: text) {
                    Text("= \(previewFormatter(value))")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: maxFieldWidth)
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
    }
}

