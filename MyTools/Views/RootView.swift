import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
func commitPendingTextInput(then action: @escaping @MainActor () -> Void) {
#if os(iOS)
    // 先让当前输入控件结束编辑，使拼音等带候选词的组合输入完整写回绑定。
    // 调用方不能提前清除 FocusState，否则最后一段 marked text 可能被丢弃。
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
        IMESafeUITextField(
            prompt: prompt,
            text: $text,
            alignment: alignment,
            mode: mode
        )
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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

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

        // 输入过程中 UIKit 持有 marked text。此时任何 SwiftUI -> UIKit 的反向赋值
        // 都可能清除拼音候选，因此只在没有编辑时同步外部状态。
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

        init(parent: IMESafeUITextField) {
            self.parent = parent
        }

        @objc func textChanged(_ textField: UITextField) {
            // 拼音候选尚未确认时不触碰 Binding，避免 SwiftUI 重绘后覆盖 marked text。
            guard textField.markedTextRange == nil else { return }
            commit(textField.text ?? "")
        }

        func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            commit(textField.text ?? "")
        }

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }
}

private struct IMESafeUITextView: UIViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

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

        init(parent: IMESafeUITextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? IMEPlaceholderTextView)?.updatePlaceholder()
            guard textView.markedTextRange == nil else { return }
            commit(textView.text)
        }

        func textViewShouldEndEditing(_ textView: UITextView) -> Bool {
            return true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            commit(textView.text)
        }

        private func commit(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
        }
    }
}
#endif

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: CardStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ToolboxView()
                .tabItem { Label("工具箱", systemImage: "square.grid.2x2") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
#if os(iOS)
        .tint(.blue)
        .toolbarBackground(.visible, for: .tabBar)
#endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, auth.isAdmin { auth.lock() }
        }
        .onChange(of: auth.isAdmin) { _, isAdmin in
            if isAdmin { store.loadEncryptedVaultAfterAuthentication() }
        }
    }
}

enum ToolModule: String, CaseIterable, Identifiable {
    case personalFinance
    case myStocks

    var id: Self { self }

    var title: String {
        switch self {
        case .personalFinance: return "个人金融"
        case .myStocks: return "我的股票"
        }
    }

    var subtitle: String {
        switch self {
        case .personalFinance: return "银行账户与银行卡"
        case .myStocks: return "A 股与美股持仓"
        }
    }

    var systemImage: String {
        switch self {
        case .personalFinance: return "building.columns.fill"
        case .myStocks: return "chart.line.uptrend.xyaxis"
        }
    }

    var tint: Color {
        switch self {
        case .personalFinance: return .blue
        case .myStocks: return .green
        }
    }

    var visibilityKey: String { "tool-module-\(rawValue)-visible" }
}

@MainActor
final class ToolModuleSettings: ObservableObject {
    @Published private var visibility: [String: Bool] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for module in ToolModule.allCases where defaults.object(forKey: module.visibilityKey) != nil {
            visibility[module.rawValue] = defaults.bool(forKey: module.visibilityKey)
        }
    }

    func isVisible(_ module: ToolModule) -> Bool {
        visibility[module.rawValue] ?? true
    }

    func setVisible(_ isVisible: Bool, for module: ToolModule) {
        visibility[module.rawValue] = isVisible
        defaults.set(isVisible, forKey: module.visibilityKey)
    }
}

@MainActor
final class StockAppearanceSettings: ObservableObject {
    static let aShareKey = "stock-color-scheme-a-share-v1"
    static let unitedStatesKey = "stock-color-scheme-us-v1"

    @Published private(set) var aShareScheme: StockRiseFallColorScheme
    @Published private(set) var unitedStatesScheme: StockRiseFallColorScheme
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        aShareScheme = Self.savedScheme(forKey: Self.aShareKey, market: .aShare, defaults: defaults)
        unitedStatesScheme = Self.savedScheme(forKey: Self.unitedStatesKey, market: .unitedStates, defaults: defaults)
    }

    func scheme(for market: StockMarket) -> StockRiseFallColorScheme {
        market == .aShare ? aShareScheme : unitedStatesScheme
    }

    func setScheme(_ scheme: StockRiseFallColorScheme, for market: StockMarket) {
        switch market {
        case .aShare:
            aShareScheme = scheme
            defaults.set(scheme.rawValue, forKey: Self.aShareKey)
        case .unitedStates:
            unitedStatesScheme = scheme
            defaults.set(scheme.rawValue, forKey: Self.unitedStatesKey)
        }
    }

    private static func savedScheme(
        forKey key: String,
        market: StockMarket,
        defaults: UserDefaults
    ) -> StockRiseFallColorScheme {
        guard let saved = defaults.string(forKey: key),
              let scheme = StockRiseFallColorScheme(rawValue: saved) else {
            return .defaultScheme(for: market)
        }
        return scheme
    }
}

private struct ToolboxView: View {
    @EnvironmentObject private var store: CardStore
    @EnvironmentObject private var moduleSettings: ToolModuleSettings

    private var visibleModules: [ToolModule] {
        ToolModule.allCases.filter(moduleSettings.isVisible)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("工具") {
                    ForEach(visibleModules) { module in
                        NavigationLink {
                            destination(for: module)
                        } label: {
                            moduleRow(module)
                        }
                    }
                }
            }
            .overlay {
                if visibleModules.isEmpty {
                    ContentUnavailableView("暂无已启用功能", systemImage: "square.grid.2x2")
                }
            }
            .navigationTitle("我的工具箱")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.insetGrouped)
#endif
        }
    }

    private func moduleRow(_ module: ToolModule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: module.systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(module.tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title)
                    .font(.headline)
                Text(module.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(moduleSummary(module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func destination(for module: ToolModule) -> some View {
        switch module {
        case .personalFinance:
            HomeView()
        case .myStocks:
            StocksView()
        }
    }

    private func moduleSummary(_ module: ToolModule) -> String {
        switch module {
        case .personalFinance:
            return "\(store.currentBankCount) 家银行 · \(store.currentCardCount) 张卡"
        case .myStocks:
            return "\(store.stocks.count) 只股票 · \(store.openStockCount) 只持仓"
        }
    }
}

extension View {
    func iOSLabeledBackButton(_ title: String) -> some View {
        modifier(IOSLabeledBackButtonModifier(title: title))
    }

    @ViewBuilder
    func iOSLargeSheet() -> some View {
#if os(iOS)
        presentationDetents([.large])
            .presentationDragIndicator(.visible)
#else
        self
#endif
    }
}

struct AdminEditAccessButton: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var showingAuthentication = false
    var onAccessGranted: (() -> Void)? = nil

    var body: some View {
        Button {
            if auth.isAdmin {
                auth.lock()
            } else {
                showingAuthentication = true
            }
        } label: {
            Image(systemName: auth.isAdmin ? "pencil.circle.fill" : "pencil.circle")
                .foregroundStyle(auth.isAdmin ? Color.green : Color.primary)
        }
        .accessibilityLabel(auth.isAdmin ? "退出编辑模式" : "进入编辑模式")
        .help(auth.isAdmin ? "退出编辑模式" : "验证身份后编辑")
        .sheet(isPresented: $showingAuthentication) {
            AuthenticationView()
                .iOSLargeSheet()
        }
        .onChange(of: auth.isAdmin) { wasAdmin, isAdmin in
            if !wasAdmin, isAdmin { onAccessGranted?() }
        }
    }
}

struct ProtectedValueRow: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var showingAuthentication = false
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(displayValue)
                    .fontDesign(auth.isAdmin ? .monospaced : .default)
                    .textSelection(.enabled)
                Button {
                    if auth.isAdmin {
                        auth.lock()
                    } else {
                        showingAuthentication = true
                    }
                } label: {
                    Image(systemName: auth.isAdmin ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(auth.isAdmin ? "隐藏\(title)" : "验证身份后查看\(title)")
            }
        }
        .sheet(isPresented: $showingAuthentication) {
            AuthenticationView()
                .iOSLargeSheet()
        }
    }

    private var displayValue: String {
        guard !value.isEmpty else { return "未填写" }
        return auth.isAdmin ? value : "••••••"
    }
}

private struct IOSLabeledBackButtonModifier: ViewModifier {
    let title: String

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        content
            // 使用系统返回按钮才能保留 iPhone 左侧边缘的交互式滑动返回。
            // 系统会根据 NavigationStack 中上一页的标题显示返回层级名称。
            .navigationBarBackButtonHidden(false)
#else
        content
#endif
    }
}
