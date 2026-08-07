import SwiftUI

enum AppListMetrics {
    static let rowVerticalInset: CGFloat = 10
    static let rowHorizontalInset: CGFloat = 16
    static let minimumRowHeight: CGFloat = 46
    static let recordContentSpacing: CGFloat = 10
}

enum SortDirection {
    case ascending
    case descending

    var title: String {
        switch self {
        case .ascending: return "升序"
        case .descending: return "降序"
        }
    }

    var indicator: String {
        switch self {
        case .ascending: return "↑"
        case .descending: return "↓"
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
