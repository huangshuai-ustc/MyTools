import SwiftUI

/// 标准单行“标签 + 任意尾部内容”容器。文本、日期、Picker、Badge、菜单和按钮等
/// 单行内容都以同一个内容高度为基准；真正的多行地址、备注和记录卡片不使用它。
struct AppLabeledContentRow<Content: View>: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    let systemImage: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: AppListMetrics.minimumRowHeight(fontScale: fontScale))
        // Do not leave row insets to each native control. Picker/DatePicker/Toggle
        // otherwise ask Form for slightly different vertical padding even when
        // their visible content has the same height.
        .appListRowStyle()
    }
}

/// 详情页"标签+值"行：trailing 模式固定单行（长文本截断，可复制），leading 模式允许多行（地址/备注类）。
struct DetailValueRow: View {
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
                    .foregroundStyle(.secondary)
                valueText
                    .appFont(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            AppLabeledContentRow(title) {
                valueText
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
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
    static func protected(
        _ title: String,
        value: String,
        concealedValue: String = "••••••",
        isRevealed: Bool,
        monospaced: Bool = false,
        truncationMode: Text.TruncationMode = .tail
    ) -> some View {
        AppLabeledContentRow(title) {
            Text(value.isEmpty ? "未填写" : (isRevealed ? value : concealedValue))
                .fontDesign(monospaced && isRevealed ? .monospaced : .default)
                .lineLimit(1)
                .truncationMode(truncationMode)
                .multilineTextAlignment(.trailing)
                .copyableText(isRevealed && !value.isEmpty ? value : nil)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// 详情页超链接值行：可点击打开、长按复制，行高与其它 `DetailValueRow` 一致。`resolveURL` 用于把原始字符串解析为可跳转链接
    /// （不同模块的补全规则可能不同，例如是否允许缺省协议）；解析失败或值为空时退回普通文本展示。
    static func link(
        _ title: String,
        urlString: String,
        emptyValue: String = "未填写",
        resolveURL: (String) -> URL? = { string in
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
            return url
        }
    ) -> some View {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if let url = resolveURL(trimmed) {
                AppLabeledContentRow(title) {
                    Link(destination: url) {
                        Text(trimmed)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.trailing)
                    }
                    .copyableText(trimmed)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                DetailValueRow(title: title, value: trimmed, emptyValue: emptyValue)
            }
        }
    }
}

/// 编辑页"标签+单行输入框"行，固定最小行高，保证与其它行同高。
struct FieldEditorRow: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var alignment: TextAlignment = .trailing
    var mode: IMESafeTextInputMode = .text
    var maxFieldWidth: CGFloat = 260

    var body: some View {
        AppLabeledContentRow(title) {
            IMESafeTextField(prompt: prompt, text: $text, alignment: alignment, mode: mode)
                .frame(maxWidth: maxFieldWidth)
        }
    }
}

/// 编辑页"标签+日期选择器"行，固定最小行高，与 `FieldEditorRow`/`PickerFieldRow` 同高。
struct DateFieldRow: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    @Binding var date: Date
    var displayedComponents: DatePicker.Components = .date

    var body: some View {
        AppLabeledContentRow(title) {
            DatePicker("", selection: $date, displayedComponents: displayedComponents)
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(height: AppListMetrics.minimumRowHeight(fontScale: fontScale))
        }
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
        AppLabeledContentRow(title) {
            Picker("", selection: $selection) {
                content()
            }
            .labelsHidden()
            .frame(height: AppListMetrics.minimumRowHeight(fontScale: fontScale))
        }
    }
}

/// 编辑页“标签 + 开关”行。隐藏原生 Toggle 标签，避免 Toggle 自己的整行高度
/// 与 Form 的统一行高叠加。
struct ToggleFieldRow: View {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        AppLabeledContentRow(title) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .frame(height: AppListMetrics.minimumRowHeight(fontScale: fontScale))
        }
    }
}

/// 编辑页"标签+数值/算式输入框"行；可选算式支持与计算结果预览（预览文案由调用处的 `previewFormatter` 提供，避免 Core 依赖具体模块的货币格式化规则）。焦点绑定由调用处自行附加。
struct NumericFieldRow: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var allowsExpression = false
    var maxFieldWidth: CGFloat = 260
    var previewFormatter: ((Decimal) -> String)?

    var body: some View {
        AppLabeledContentRow(title) {
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
    }
}
