import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
func commitPendingTextInput(then action: @escaping @MainActor () -> Void) {
#if os(iOS)
    // 先结束组合输入，避免拼音候选中的最后一段文字被 SwiftUI 重绘覆盖。
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
#elseif os(macOS)
    NSApp.keyWindow?.makeFirstResponder(nil)
#endif
    Task { @MainActor in
        await Task.yield()
        await Task.yield()
        action()
    }
}

enum IMESafeTextInputMode {
    case text
    case asciiUppercase
}

struct IMESafeTextField: View {
    let prompt: String
    @Binding var text: String
    var alignment: TextAlignment = .leading
    var mode: IMESafeTextInputMode = .text

    var body: some View {
#if os(iOS)
        IMESafeUITextField(prompt: prompt, text: $text, alignment: alignment, mode: mode)
#else
        TextField(prompt, text: $text)
            .multilineTextAlignment(alignment)
#endif
    }
}

struct IMESafeMultilineTextField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
#if os(iOS)
        IMESafeUITextView(prompt: prompt, text: $text)
            .frame(minHeight: 76)
#else
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(3...6)
#endif
    }
}

#if os(iOS)
private struct IMESafeUITextField: UIViewRepresentable {
    let prompt: String
    @Binding var text: String
    let alignment: TextAlignment
    let mode: IMESafeTextInputMode

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.clearButtonMode = .whileEditing
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        applyConfiguration(to: textField)
        textField.text = text
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        applyConfiguration(to: textField)
        guard !textField.isFirstResponder, textField.markedTextRange == nil else { return }
        if textField.text != text { textField.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 34)
    }

    private func applyConfiguration(to textField: UITextField) {
        textField.placeholder = prompt
        textField.textAlignment = alignment == .trailing ? .right : .left
        switch mode {
        case .text:
            textField.keyboardType = .default
            textField.autocapitalizationType = .sentences
            textField.autocorrectionType = .default
        case .asciiUppercase:
            textField.keyboardType = .asciiCapable
            textField.autocapitalizationType = .allCharacters
            textField.autocorrectionType = .no
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: IMESafeUITextField
        init(parent: IMESafeUITextField) { self.parent = parent }

        @objc func textChanged(_ textField: UITextField) {
            guard textField.markedTextRange == nil else { return }
            commit(textField.text ?? "")
        }

        func textFieldDidEndEditing(_ textField: UITextField) { commit(textField.text ?? "") }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        private func commit(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
        }
    }
}

private final class IMEPlaceholderTextView: UITextView {
    let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5)
        ])
        updatePlaceholder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updatePlaceholder() { placeholderLabel.isHidden = !text.isEmpty }
}

private struct IMESafeUITextView: UIViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> IMEPlaceholderTextView {
        let textView = IMEPlaceholderTextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.placeholderLabel.text = prompt
        textView.text = text
        textView.updatePlaceholder()
        return textView
    }

    func updateUIView(_ textView: IMEPlaceholderTextView, context: Context) {
        context.coordinator.parent = self
        textView.placeholderLabel.text = prompt
        guard !textView.isFirstResponder, textView.markedTextRange == nil else {
            textView.updatePlaceholder()
            return
        }
        if textView.text != text { textView.text = text }
        textView.updatePlaceholder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IMESafeUITextView
        init(parent: IMESafeUITextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? IMEPlaceholderTextView)?.updatePlaceholder()
            guard textView.markedTextRange == nil else { return }
            commit(textView.text)
        }

        func textViewDidEndEditing(_ textView: UITextView) { commit(textView.text) }

        private func commit(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
        }
    }
}
#endif
