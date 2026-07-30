import SwiftUI
#if os(iOS)
import UIKit
import QuickLook
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
struct AttachmentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

struct AdminEditAccessButton: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var showingAuthentication = false

    var body: some View {
        Button {
            if auth.isAdmin {
                auth.lock()
            } else {
                auth.beginAuthenticationPresentation()
                showingAuthentication = true
            }
        } label: {
            AdminModeIcon(isActive: auth.isAdmin)
        }
        .accessibilityLabel(auth.isAdmin ? "退出编辑模式" : "进入编辑模式")
        .help(auth.isAdmin ? "退出编辑模式" : "验证身份后编辑")
        .sheet(isPresented: $showingAuthentication, onDismiss: {
            auth.endAuthenticationPresentation()
        }) {
            AuthenticationView().iOSAuthenticationSheet()
        }
    }
}

struct AdminModeIndicator: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        if auth.isAdmin {
            Button { auth.lock() } label: {
                AdminModeIcon(isActive: true)
            }
            .accessibilityLabel("管理员模式已开启，点按退出")
            .help("退出管理员模式")
        }
    }
}

private struct AdminModeIcon: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: isActive ? "pencil.circle.fill" : "pencil.circle")
            .foregroundStyle(isActive ? Color.green : Color.primary)
    }
}

private struct AdminModeIndicatorModifier: ViewModifier {
    @EnvironmentObject private var auth: AuthManager

    func body(content: Content) -> some View {
        content.toolbar {
            if auth.isAdmin {
                ToolbarItem(placement: .primaryAction) {
                    AdminModeIndicator()
                }
            }
        }
    }
}

extension View {
    func adminModeIndicator() -> some View {
        modifier(AdminModeIndicatorModifier())
    }
}

struct ProtectedValueRow: View {
    let title: String
    let value: String
    let concealedValue: String
    let isRevealed: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(displayValue)
                    .fontDesign(isRevealed ? .monospaced : .default)
                    .multilineTextAlignment(.trailing)
                    .copyableText(isRevealed ? value : nil)
            }
        }
    }

    private var displayValue: String {
        guard !value.isEmpty else { return "未填写" }
        return isRevealed ? value : concealedValue
    }
}

struct CopyableValueRow: View {
    let title: String
    let value: String
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

    private var valueView: some View {
        Text(value.isEmpty ? emptyValue : value)
            .multilineTextAlignment(alignment)
            .frame(
                maxWidth: .infinity,
                alignment: alignment == .leading ? .leading : .trailing
            )
            .copyableText(value.isEmpty ? nil : value)
    }
}

@MainActor
final class CopyToastCenter {
    static let shared = CopyToastCenter()

    private var dismissalTask: Task<Void, Never>?

    func show() {
        dismissalTask?.cancel()
        CopyToastPresenter.shared.show()
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        CopyToastPresenter.shared.dismiss()
    }
}

private struct CopyToastBanner: View {
    var body: some View {
        Label("已复制到剪贴板", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("已复制到剪贴板")
    }
}

#if os(iOS)
@MainActor
private final class CopyToastPresenter {
    static let shared = CopyToastPresenter()

    private var window: CopyToastWindow?

    func show() {
        guard let windowScene = activeWindowScene else { return }

        let toastWindow: CopyToastWindow
        if let window, window.windowScene === windowScene {
            toastWindow = window
        } else {
            window?.isHidden = true
            toastWindow = CopyToastWindow(windowScene: windowScene)
            window = toastWindow
        }

        // Keep the banner above sheets and form presentations in the same scene.
        toastWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        let controller = UIHostingController(rootView: CopyToastOverlay())
        controller.view.backgroundColor = .clear
        toastWindow.rootViewController = controller
        toastWindow.isHidden = false
    }

    func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    private var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return scenes.first(where: { scene in
            scene.windows.contains(where: { $0.isKeyWindow })
        }) ?? scenes.first
    }
}

private final class CopyToastWindow: UIWindow {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}

private struct CopyToastOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            VStack {
                Spacer(minLength: proxy.size.height * 0.80)
                CopyToastBanner()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
#elseif os(macOS)
@MainActor
private final class CopyToastPresenter {
    static let shared = CopyToastPresenter()

    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CopyToastBanner())
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.minY + visibleFrame.height * 0.35
            )
        )
    }
}
#endif

private struct CopyableTextModifier: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value, !value.isEmpty {
            content
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 24) {
                    copy(value)
                }
                .accessibilityHint("长按复制")
                .accessibilityAction(named: "复制") {
                    copy(value)
                }
        } else {
            content
        }
    }

    private func copy(_ value: String) {
#if os(iOS)
        UIPasteboard.general.string = value
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
#endif
        Task { @MainActor in
            CopyToastCenter.shared.show()
        }
    }
}

extension View {
    func copyableText(_ value: String?) -> some View {
        modifier(CopyableTextModifier(value: value))
    }
}
