import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
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

    @MainActor
    private func copy(_ value: String) {
#if os(iOS)
        UIPasteboard.general.string = value
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.prepare()
        feedback.impactOccurred()
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
