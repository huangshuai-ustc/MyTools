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

enum IMESafeTextInputMode: Equatable {
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
        context.coordinator.applyConfiguration(
            to: textField,
            prompt: prompt,
            alignment: alignment,
            mode: mode
        )
        textField.text = text
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyConfiguration(
            to: textField,
            prompt: prompt,
            alignment: alignment,
            mode: mode
        )
        guard !textField.isFirstResponder, textField.markedTextRange == nil else { return }
        if textField.text != text { textField.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 34)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: IMESafeUITextField
        private var appliedConfiguration: Configuration?

        init(parent: IMESafeUITextField) { self.parent = parent }

        func applyConfiguration(
            to textField: UITextField,
            prompt: String,
            alignment: TextAlignment,
            mode: IMESafeTextInputMode
        ) {
            let configuration = Configuration(
                prompt: prompt,
                alignment: alignment == .trailing ? .right : .left,
                mode: mode
            )
            guard appliedConfiguration != configuration else { return }

            appliedConfiguration = configuration
            textField.placeholder = configuration.prompt
            textField.textAlignment = configuration.alignment
            switch configuration.mode {
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

        @objc func textChanged(_ textField: UITextField) {
            guard textField.markedTextRange == nil else { return }
            commit(textField.text ?? "")
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            KeyboardLatencyDiagnostics.shared.editingBegan(
                control: textField,
                kind: "单行",
                mode: parent.mode,
                inputLanguage: textField.textInputMode?.primaryLanguage
            )
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            commit(textField.text ?? "")
            KeyboardLatencyDiagnostics.shared.editingEnded(control: textField, kind: "单行")
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        private func commit(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
        }

        private struct Configuration: Equatable {
            let prompt: String
            let alignment: NSTextAlignment
            let mode: IMESafeTextInputMode
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
        if textView.placeholderLabel.text != prompt {
            textView.placeholderLabel.text = prompt
        }
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

        func textViewDidBeginEditing(_ textView: UITextView) {
            KeyboardLatencyDiagnostics.shared.editingBegan(
                control: textView,
                kind: "多行",
                mode: .text,
                inputLanguage: textView.textInputMode?.primaryLanguage
            )
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            commit(textView.text)
            KeyboardLatencyDiagnostics.shared.editingEnded(control: textView, kind: "多行")
        }

        private func commit(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
        }
    }
}

@MainActor
private final class KeyboardLatencyDiagnostics: NSObject {
    static let shared = KeyboardLatencyDiagnostics()

    private var editingStartedAt: TimeInterval?
    private var activeControl: ObjectIdentifier?
    private var keyboardIsVisible = false
    private var hasObservedEditing = false

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
    }

    func editingBegan(
        control: UIView,
        kind: String,
        mode: IMESafeTextInputMode,
        inputLanguage: String?
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        editingStartedAt = now
        activeControl = ObjectIdentifier(control)
        let isFirst = !hasObservedEditing
        hasObservedEditing = true
        DiagnosticLogger.shared.log(
            .textInput,
            "开始编辑 kind=\(kind) mode=\(mode.diagnosticName) language=\(inputLanguage ?? "unknown") firstInSession=\(isFirst) keyboardVisible=\(keyboardIsVisible)"
        )
    }

    func editingEnded(control: UIView, kind: String) {
        guard activeControl == ObjectIdentifier(control) else { return }
        let duration = elapsedSinceEditingBegan()
        DiagnosticLogger.shared.log(
            .textInput,
            "结束编辑 kind=\(kind) duration=\(Self.milliseconds(duration))ms"
        )
        editingStartedAt = nil
        activeControl = nil
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        let elapsed = elapsedSinceEditingBegan()
        let animationDuration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        DiagnosticLogger.shared.log(
            .textInput,
            "键盘即将显示 focusToNotification=\(Self.milliseconds(elapsed))ms animation=\(Self.milliseconds(animationDuration))ms"
        )
    }

    @objc private func keyboardDidShow(_ notification: Notification) {
        keyboardIsVisible = true
        let elapsed = elapsedSinceEditingBegan()
        DiagnosticLogger.shared.log(
            .textInput,
            "键盘显示完成 focusToVisible=\(Self.milliseconds(elapsed))ms"
        )
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        keyboardIsVisible = false
        DiagnosticLogger.shared.log(.textInput, "键盘已隐藏")
    }

    private func elapsedSinceEditingBegan() -> Double? {
        editingStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    private static func milliseconds(_ duration: Double?) -> String {
        guard let duration else { return "unknown" }
        return String(format: "%.1f", duration * 1_000)
    }
}

private extension IMESafeTextInputMode {
    var diagnosticName: String {
        switch self {
        case .text: "text"
        case .asciiUppercase: "asciiUppercase"
        }
    }
}
#endif
