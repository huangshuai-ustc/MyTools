import SwiftUI

enum AppListMetrics {
    static let rowVerticalInset: CGFloat = 10
    static let rowHorizontalInset: CGFloat = 16
    static let minimumRowHeight: CGFloat = 46
    static let recordContentSpacing: CGFloat = 10
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
        presentationDetents([.large])
            .presentationDragIndicator(.visible)
#else
        self
#endif
    }

    @ViewBuilder
    func iOSAuthenticationSheet() -> some View {
#if os(iOS)
        presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
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
