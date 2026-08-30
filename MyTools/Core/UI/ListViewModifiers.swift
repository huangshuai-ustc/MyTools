import SwiftUI
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private struct SidebarCollapsedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSidebarCollapsed: Bool {
        get { self[SidebarCollapsedEnvironmentKey.self] }
        set { self[SidebarCollapsedEnvironmentKey.self] = newValue }
    }
}

private struct AppFontScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// A macOS-only user-selected scale. A nil value preserves the platform's
    /// native semantic fonts, which is also the behavior used on iOS/iPadOS.
    var appFontScale: CGFloat? {
        get { self[AppFontScaleEnvironmentKey.self] }
        set { self[AppFontScaleEnvironmentKey.self] = newValue }
    }
}

struct AppFontSpec {
    private enum TextStyle {
        case largeTitle, title, title2, title3
        case headline, body, subheadline, footnote, caption, caption2
        case fixed(CGFloat)
    }

    private let style: TextStyle
    private var weight: Font.Weight?
    private var usesMonospacedDesign = false
    private var usesMonospacedDigits = false

    static let largeTitle = Self(style: .largeTitle)
    static let title = Self(style: .title)
    static let title2 = Self(style: .title2)
    static let title3 = Self(style: .title3)
    static let headline = Self(style: .headline)
    static let body = Self(style: .body)
    static let subheadline = Self(style: .subheadline)
    static let footnote = Self(style: .footnote)
    static let caption = Self(style: .caption)
    static let caption2 = Self(style: .caption2)

    static func system(size: CGFloat) -> Self {
        Self(style: .fixed(size))
    }

    func weight(_ value: Font.Weight) -> Self {
        var copy = self
        copy.weight = value
        return copy
    }

    func bold() -> Self {
        weight(.bold)
    }

    func monospaced() -> Self {
        var copy = self
        copy.usesMonospacedDesign = true
        return copy
    }

    func monospacedDigit() -> Self {
        var copy = self
        copy.usesMonospacedDigits = true
        return copy
    }

    fileprivate func font(scale: CGFloat?) -> Font {
        var result: Font
#if os(macOS)
        if let scale {
            result = .system(
                size: basePointSize * scale,
                weight: weight,
                design: usesMonospacedDesign ? .monospaced : .default
            )
        } else {
            result = nativeSemanticFont
        }
#else
        result = nativeSemanticFont
#endif
        if usesMonospacedDesign {
            result = result.monospaced()
        }
        if usesMonospacedDigits {
            result = result.monospacedDigit()
        }
        return result
    }

    private var nativeSemanticFont: Font {
        let result: Font
        switch style {
        case .largeTitle: result = .largeTitle
        case .title: result = .title
        case .title2: result = .title2
        case .title3: result = .title3
        case .headline: result = .headline
        case .body: result = .body
        case .subheadline: result = .subheadline
        case .footnote: result = .footnote
        case .caption: result = .caption
        case .caption2: result = .caption2
        case .fixed(let size): result = .system(size: size)
        }
        guard let weight else { return result }
        return result.weight(weight)
    }

    private var basePointSize: CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .body: return 13
        case .subheadline: return 12
        case .footnote: return 11
        case .caption: return 10
        case .caption2: return 9
        case .fixed(let size): return size
        }
    }
}

private struct AppSemanticFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var scale
    let spec: AppFontSpec

    func body(content: Content) -> some View {
        content.font(spec.font(scale: scale))
    }
}

private struct AppNavigationTitleModifier: ViewModifier {
    @Environment(\.appFontScale) private var fontScale
    let title: String
    let displaysMacToolbarTitle: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        content
            // A native macOS navigation title is rendered beside the back
            // button and does not honor the app's font scale. Keep it empty so
            // it does not duplicate the scalable principal title.
            .navigationTitle("")
            .toolbar {
                if displaysMacToolbarTitle {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .appFont(.body.weight(.regular))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, navigationTitleVerticalPadding)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
#else
        content.navigationTitle(title)
#endif
    }

#if os(macOS)
    private var navigationTitleVerticalPadding: CGFloat {
        min(10, 4 + max(0, (fontScale ?? 1) - 1) * 4)
    }
#endif
}

extension View {
    func appFont(_ spec: AppFontSpec) -> some View {
        modifier(AppSemanticFontModifier(spec: spec))
    }

    func appNavigationTitle(
        _ title: String,
        displaysMacToolbarTitle: Bool = true
    ) -> some View {
        modifier(AppNavigationTitleModifier(
            title: title,
            displaysMacToolbarTitle: displaysMacToolbarTitle
        ))
    }
}

enum AppTagSupport {
    static let inputSeparator = "，"

    /// Trims whitespace from a single text value. Use this instead of writing
    /// `value.trimmingCharacters(in: .whitespacesAndNewlines)` directly inside
    /// Store `normalized` methods so the trimming rule stays in one place.
    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trims whitespace; returns `nil` when the result is empty.
    static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Accept legacy separators while always writing the canonical Chinese comma format.
    static func parse(_ text: String) -> [String] {
        normalize(text.split(whereSeparator: { ",，、".contains($0) }).map(String.init))
    }

    static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .flatMap { rawValue in
                rawValue.split(whereSeparator: { ",，、".contains($0) }).map(String.init)
            }
            .compactMap { rawValue in
                let tag = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { return nil }
                let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return seen.insert(key).inserted ? tag : nil
            }
    }

    static func joined(_ tags: [String]) -> String {
        normalize(tags).joined(separator: inputSeparator)
    }

    static func merged(_ stored: [String], with tags: [String]) -> [String] {
        normalize(stored + tags)
    }
}

struct AppTagCapsule: View {
    let title: String
    var isSelected = false

    var body: some View {
        Text(title)
            .appFont(.caption2.weight(.medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.14),
                in: Capsule()
            )
    }
}

struct AppTagCapsules: View {
    let tags: [String]
    var limit: Int?

    init(tags: [String], limit: Int? = nil) {
        self.tags = tags
        self.limit = limit
    }

    private var displayedTags: [String] {
        let normalized = AppTagSupport.normalize(tags)
        guard let limit else { return normalized }
        return Array(normalized.prefix(max(0, limit)))
    }

    var body: some View {
        if displayedTags.isEmpty {
            EmptyView()
        } else {
            AppTagFlowLayout(horizontalSpacing: 6, verticalSpacing: 5) {
                ForEach(displayedTags, id: \.self) { tag in
                    AppTagCapsule(title: tag)
                }
            }
        }
    }
}

struct AppTagFilterCapsules: View {
    let tags: [String]
    @Binding var selectedTag: String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                filterButton(title: "全部", value: "")
                ForEach(AppTagSupport.normalize(tags), id: \.self) { tag in
                    filterButton(title: tag, value: tag)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func filterButton(title: String, value: String) -> some View {
        Button { selectedTag = value } label: {
            AppTagCapsule(title: title, isSelected: selectedTag == value)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTag == value ? .isSelected : [])
    }
}

struct AppTagEditor: View {
    @Binding var text: String
    let suggestions: [String]

    private var currentTags: [String] { AppTagSupport.parse(text) }

    private var remainingSuggestions: [String] {
        let currentKeys = Set(currentTags.map(tagKey))
        return AppTagSupport.normalize(suggestions).filter { !currentKeys.contains(tagKey($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IMESafeTextField(prompt: "用中文逗号分隔", text: $text)
            if !currentTags.isEmpty {
                AppTagCapsules(tags: currentTags)
            }
            if !remainingSuggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(remainingSuggestions, id: \.self) { tag in
                            Button { append(tag) } label: {
                                AppTagCapsule(title: tag)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("添加标签 \(tag)")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func append(_ tag: String) {
        text = AppTagSupport.joined(currentTags + [tag])
    }

    private func tagKey(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct AppTagFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth > 0, currentWidth + horizontalSpacing + size.width > maxWidth {
                totalWidth = max(totalWidth, currentWidth)
                totalHeight += currentHeight + verticalSpacing
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentWidth = currentWidth == 0 ? size.width : currentWidth + horizontalSpacing + size.width
                currentHeight = max(currentHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, currentWidth)
        totalHeight += currentHeight
        return CGSize(width: proposal.width ?? totalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct AppSwipeActionStyle {
    let tint: Color
    let allowsFullSwipe: Bool
}

enum AppSwipeActions {
    static let delete = AppSwipeActionStyle(tint: .red, allowsFullSwipe: true)
    static let primary = AppSwipeActionStyle(tint: .teal, allowsFullSwipe: true)
    static let secondary = AppSwipeActionStyle(tint: .blue, allowsFullSwipe: false)
    static let visibility = AppSwipeActionStyle(tint: .blue, allowsFullSwipe: false)
    static let edit = AppSwipeActionStyle(tint: .orange, allowsFullSwipe: false)
    static let rename = AppSwipeActionStyle(tint: .blue, allowsFullSwipe: false)
}

struct TemplateFieldSwipeActionsModifier: ViewModifier {
    let isSensitive: Bool
    let toggleVisibility: () -> Void
    let onRename: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        content.appSwipeActions(edge: .leading, style: AppSwipeActions.secondary) {
            Button(action: toggleVisibility) {
                Label(
                    isSensitive ? "显示" : "隐藏",
                    systemImage: isSensitive ? "eye" : "eye.slash"
                )
            }
            .tint(AppSwipeActions.visibility.tint)
            Button(action: onRename) {
                Label("编辑名称", systemImage: "pencil")
            }
            .tint(AppSwipeActions.edit.tint)
        }
    }
}

struct TemplateFieldDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}

/// Shared incremental-loading state for record lists.
///
/// A feature owns one value and chooses its page size. The state owns the
/// initial limit, reset behavior, last-row trigger, and upper-bound clamping,
/// so feature views only decide how filtered records are grouped and drawn.
struct AppListPagination {
    let pageSize: Int
    private(set) var visibleItemCount: Int

    init(pageSize: Int) {
        let normalizedPageSize = max(1, pageSize)
        self.pageSize = normalizedPageSize
        visibleItemCount = normalizedPageSize
    }

    func visibleItems<Element>(from items: [Element]) -> [Element] {
        Array(items.prefix(visibleItemCount))
    }

    func canLoadMore(totalItemCount: Int) -> Bool {
        visibleItemCount < totalItemCount
    }

    mutating func reset() {
        visibleItemCount = pageSize
    }

    mutating func loadMore(totalItemCount: Int) {
        guard canLoadMore(totalItemCount: totalItemCount) else { return }
        visibleItemCount = min(
            visibleItemCount + pageSize,
            totalItemCount
        )
    }

    mutating func loadMoreIfNeeded<ID: Hashable>(
        currentItemID: ID,
        lastVisibleItemID: ID?,
        totalItemCount: Int
    ) {
        guard currentItemID == lastVisibleItemID else { return }
        loadMore(totalItemCount: totalItemCount)
    }
}

@MainActor
enum AppListMetrics {
    /// 系统当前 body 文本样式的行高。iOS 原生跟随 Dynamic Type；macOS 没有系统级
    /// Dynamic Type，改用 App 自己的 `appFontScale` 对基准行高做线性缩放。
    static func baseLineHeight(fontScale: CGFloat?) -> CGFloat {
#if os(iOS)
        UIFont.preferredFont(forTextStyle: .body).lineHeight
#elseif os(macOS)
        let base = NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height
        return base * (fontScale ?? 1)
#endif
    }

    /// 全局密度系数：小于 1 更紧凑，大于 1 更宽松。调整这一个值即可整体缩放所有行间距，
    /// 且不破坏“随字体自适应”的关系。具体数值由使用者自行微调。
    static let densityScale: CGFloat = 1.0
    /// 标准单行内容的最低高度。保持略高于当前 body 字体本身，让统一组件的视觉密度
    /// 接近裸 `LabeledContent`，同时为 TextField、Picker 和 DatePicker 提供相同基线。
    static func minimumRowHeight(fontScale: CGFloat?) -> CGFloat {
        let lineHeight = baseLineHeight(fontScale: fontScale)
#if os(iOS)
        let nativeContentFloor: CGFloat = 20
#else
        let nativeContentFloor: CGFloat = 17
#endif
        return max(nativeContentFloor, lineHeight * 1.05) * densityScale
    }

    /// `minimumRowHeight` 是标准单行内容本身的最低高度；SwiftUI 的 List/Form
    /// 还会在内容外叠加系统上下边距。全局列表地板需要包含这部分空间，否则带有
    /// 显式内容高度的输入/文本行会比裸 Picker、Badge 或按钮行更高。
    static func listRowHeightFloor(fontScale: CGFloat?) -> CGFloat {
        minimumRowHeight(fontScale: fontScale)
            + baseLineHeight(fontScale: fontScale) * 0.7 * densityScale
    }
    /// 单元格内容上下留白
    static func rowVerticalInset(fontScale: CGFloat?) -> CGFloat {
        baseLineHeight(fontScale: fontScale) * 0.6 * densityScale
    }

    /// 横向内边距与字体行高的关系较弱，暂保持固定值。单元格内容左右留白
    static let rowHorizontalInset: CGFloat = 16
    /// 单条记录内部元素间距
    static func recordContentSpacing(fontScale: CGFloat?) -> CGFloat {
        baseLineHeight(fontScale: fontScale) * 0.4 * densityScale
    }
}

private struct AppListSpacingModifier: ViewModifier {
    @Environment(\.appFontScale) private var fontScale

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .environment(
                \.defaultMinListRowHeight,
                AppListMetrics.listRowHeightFloor(fontScale: fontScale)
            )
#if os(iOS)
            .listSectionSpacing(.compact)
            .listRowSpacing(0)
#endif
    }
}

private struct AppListRowStyleModifier: ViewModifier {
    @Environment(\.appFontScale) private var fontScale

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: AppListMetrics.rowVerticalInset(fontScale: fontScale),
                leading: AppListMetrics.rowHorizontalInset,
                bottom: AppListMetrics.rowVerticalInset(fontScale: fontScale),
                trailing: AppListMetrics.rowHorizontalInset
            ))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }
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

#if os(macOS)
private enum MacSheetKind {
    case large
    case authentication
}

private struct MacAdaptiveSheetFrameModifier: ViewModifier {
    @Environment(\.appFontScale) private var fontScale
    let kind: MacSheetKind

    func body(content: Content) -> some View {
        content.frame(width: width, height: height)
    }

    private var effectiveScale: CGFloat {
        min(max(fontScale ?? 1, 1), 2.5)
    }

    private var width: CGFloat {
        switch kind {
        case .large:
            return min(1_100, 680 + (effectiveScale - 1) * 280)
        case .authentication:
            return min(920, 560 + (effectiveScale - 1) * 220)
        }
    }

    private var height: CGFloat {
        switch kind {
        case .large:
            return min(920, 720 + (effectiveScale - 1) * 140)
        case .authentication:
            return min(860, 520 + (effectiveScale - 1) * 200)
        }
    }
}
#endif
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
    func appAdaptiveLargeNavigationTitle() -> some View {
        modifier(AdaptiveLargeNavigationTitleModifier())
    }

    @ViewBuilder
    func appSwipeActions(
        edge: HorizontalEdge = .trailing,
        style: AppSwipeActionStyle,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        swipeActions(
            edge: edge,
            allowsFullSwipe: style.allowsFullSwipe,
            content: {
                content().tint(style.tint)
            }
        )
    }

    @ViewBuilder
    func appDeleteSwipeAction(
        edge: HorizontalEdge = .trailing,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        if isEnabled {
            appSwipeActions(edge: edge, style: AppSwipeActions.delete) {
                Button(role: .destructive, action: action) {
                    Label("删除", systemImage: "trash")
                }
                .tint(AppSwipeActions.delete.tint)
            }
        } else {
            self
        }
    }

    func appListRowStyle() -> some View {
        modifier(AppListRowStyleModifier())
    }

    func appListSpacing() -> some View {
        modifier(AppListSpacingModifier())
    }

    func appTemplateFieldSwipeActions(
        isSensitive: Bool,
        toggleVisibility: @escaping () -> Void,
        onRename: @escaping () -> Void
    ) -> some View {
        modifier(TemplateFieldSwipeActionsModifier(
            isSensitive: isSensitive,
            toggleVisibility: toggleVisibility,
            onRename: onRename
        ))
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
        modifier(MacAdaptiveSheetFrameModifier(kind: .large))
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
        modifier(MacAdaptiveSheetFrameModifier(kind: .authentication))
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

private struct AdaptiveLargeNavigationTitleModifier: ViewModifier {
    @Environment(\.isSidebarCollapsed) private var isSidebarCollapsed

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad && isSidebarCollapsed {
            content.navigationBarTitleDisplayMode(.inline)
        } else {
            content.navigationBarTitleDisplayMode(.large)
        }
#else
        content
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
