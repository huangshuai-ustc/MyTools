import SwiftUI

/// 给页面挂上诊断埋点：进入/离开各一行日志，并把页面名压进
/// `DiagnosticLogger` 的页面栈，这样卡顿与内存日志能直接报出「卡在哪一页」。
///
/// 页面栈是卡顿定位的关键：`AppHangMonitor` 在后台线程发现主线程停住时，主线程上的
/// 任何状态都取不到，只能读这个栈。所以新增页面时顺手加上 `.diagnosticScreen("名字")`。
private struct DiagnosticScreenModifier: ViewModifier {
    let name: String
    @State private var appearedAt: Date?

    func body(content: Content) -> some View {
        content
            .onAppear {
                appearedAt = Date()
                DiagnosticLogger.shared.markScreenAppeared(name)
            }
            .onDisappear {
                let duration = appearedAt.map { Date().timeIntervalSince($0) }
                appearedAt = nil
                DiagnosticLogger.shared.markScreenDisappeared(name, duration: duration)
            }
    }
}

extension View {
    func diagnosticScreen(_ name: String) -> some View {
        modifier(DiagnosticScreenModifier(name: name))
    }
}
