import SwiftUI
import Foundation

enum AppTagSupport {
    static let inputSeparator = "，"

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
            .font(.caption2.weight(.medium))
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
