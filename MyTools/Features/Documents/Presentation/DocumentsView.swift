#if MYTOOLS_FEATURE_DOCUMENTS
import SwiftUI

private enum CredentialTypeFilter: Hashable {
    case all
    case type(CredentialDocumentType)

    var title: String {
        switch self {
        case .all: return "全部类型"
        case .type(let type): return type.title
        }
    }

    func includes(_ document: CredentialDocument) -> Bool {
        switch self {
        case .all: return true
        case .type(let type): return document.type == type
        }
    }
}

private enum CredentialStatusFilter: String, CaseIterable, Identifiable {
    case all
    case valid
    case expiringSoon
    case expired
    case unspecified

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .valid: return "有效"
        case .expiringSoon: return "即将到期"
        case .expired: return "已过期"
        case .unspecified: return "未设置期限"
        }
    }

    func includes(_ document: CredentialDocument) -> Bool {
        switch (self, document.validityStatus()) {
        case (.all, _): return true
        case (.valid, .valid), (.valid, .permanent): return true
        case (.expiringSoon, .expiringSoon): return true
        case (.expired, .expired): return true
        case (.unspecified, .unspecified): return true
        default: return false
        }
    }
}

private enum CredentialVersionStatusFilter: Hashable, Identifiable {
    case all
    case status(CredentialVersionStatus)

    var id: String {
        switch self {
        case .all: return "all"
        case .status(let status): return status.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: return "全部证照状态"
        case .status(let status): return status.title
        }
    }

    func includes(_ document: CredentialDocument) -> Bool {
        switch self {
        case .all: return true
        case .status(let status): return document.versionStatus == status
        }
    }
}

private struct CredentialDocumentGroup: Identifiable {
    let id: UUID
    let representative: CredentialDocument
    let documents: [CredentialDocument]

    var versionCount: Int { documents.count }
}

struct DocumentsView: View {
    private static let pageSize = 30
    @EnvironmentObject private var store: DocumentsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var typeFilter: CredentialTypeFilter = .all
    @State private var statusFilter: CredentialStatusFilter = .all
    @State private var versionStatusFilter: CredentialVersionStatusFilter = .all
    @State private var selectedTag = ""
    @State private var isUnlocked = false
    @State private var editingDocument: CredentialDocument?
    @State private var pagination = AppListPagination(pageSize: DocumentsView.pageSize)
    @State private var showsFilters = false

    private var canAccess: Bool { isUnlocked }

    private var availableTags: [String] {
        AppTagSupport.normalize(store.documents.flatMap(\.tags)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var visibleGroups: [CredentialDocumentGroup] {
        let matchingDocuments = store.documents
            .filter(typeFilter.includes)
            .filter(statusFilter.includes)
            .filter(versionStatusFilter.includes)
            .filter { selectedTag.isEmpty || $0.tags.contains(selectedTag) }
            .filter { $0.matches(query) }
        let matchingByRootID = Dictionary(grouping: matchingDocuments, by: \.rootDocumentID)
        let allByRootID = Dictionary(grouping: store.documents, by: \.rootDocumentID)
        return matchingByRootID.compactMap { rootID, matches in
            guard let representative = CredentialDocument.preferredVersion(in: matches) else {
                return nil
            }
            return CredentialDocumentGroup(
                id: rootID,
                representative: representative,
                documents: allByRootID[rootID, default: []]
            )
        }
            .sorted { lhs, rhs in
                AppAlphabeticalSort.isOrderedBefore(
                    lhs.representative.displayTitle,
                    rhs.representative.displayTitle,
                    lhsTieBreaker: lhs.id.uuidString,
                    rhsTieBreaker: rhs.id.uuidString
                )
            }
    }

    private var pagedGroups: [CredentialDocumentGroup] {
        pagination.visibleItems(from: visibleGroups)
    }

    var body: some View {
        List {
            Section {
                documentsOverview
                    .appListRowStyle()
            }
            if !store.documents.isEmpty {
                Section {
                    HStack {
                        Label(filterSummary, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(filterIsActive ? Color.accentColor : Color.secondary)
                        Spacer()
                        Button("筛选", systemImage: "chevron.right") { showsFilters = true }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            Section("证照") {
                if visibleGroups.isEmpty {
                    ContentUnavailableView(
                        store.documents.isEmpty ? "暂无证照" : "没有匹配的证照",
                        systemImage: store.documents.isEmpty ? "person.text.rectangle" : "magnifyingglass"
                    )
                }
                ForEach(pagedGroups) { group in
                    documentLink(group)
                        .onAppear { loadMoreIfNeeded(group) }
                }
            }
        }
        .appNavigationTitle(ToolModule.documents.title)
        .diagnosticScreen("证照")
        .iOSLabeledBackButton("工具")
#if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索名称、号码、持有人或标签")
#else
        .searchable(text: $query, prompt: "搜索名称、号码、持有人或标签")
#endif
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !canAccess {
                    Button {
                        Task { if await auth.verifyWithBiometrics() { isUnlocked = true } }
                    } label: {
                        Image(systemName: "faceid")
                    }
                    .accessibilityLabel("验证身份后查看证照信息")
                }
                Button {
                    editingDocument = CredentialDocument()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加证照")
            }
        }
        .sheet(item: $editingDocument) { document in
            CredentialEditorView(document: document)
                .id(document.id)
                .iOSLargeSheet()
        }
        .sheet(isPresented: $showsFilters) {
            DocumentsFilterSheet(
                typeFilter: $typeFilter,
                statusFilter: $statusFilter,
                versionStatusFilter: $versionStatusFilter,
                selectedTag: $selectedTag,
                availableTags: availableTags
            )
            .iOSLargeSheet()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isUnlocked = false }
        }
        .onChange(of: availableTags) { _, tags in
            if !selectedTag.isEmpty, !tags.contains(selectedTag) {
                selectedTag = ""
            }
        }
        .onChange(of: query) { _, _ in pagination.reset() }
        .onChange(of: typeFilter) { _, _ in pagination.reset() }
        .onChange(of: statusFilter) { _, _ in pagination.reset() }
        .onChange(of: versionStatusFilter) { _, _ in pagination.reset() }
        .onChange(of: selectedTag) { _, _ in pagination.reset() }
    }

    private var filterIsActive: Bool {
        typeFilter != .all || statusFilter != .all || versionStatusFilter != .all || !selectedTag.isEmpty
    }

    private var filterSummary: String {
        if !filterIsActive { return "筛选" }
        var parts: [String] = []
        if typeFilter != .all { parts.append(typeFilter.title) }
        if statusFilter != .all { parts.append(statusFilter.title) }
        if versionStatusFilter != .all { parts.append("证照" + versionStatusFilter.title) }
        if !selectedTag.isEmpty { parts.append(selectedTag) }
        return parts.joined(separator: " · ")
    }

    private var documentsOverview: some View {
        let normal = store.documents.filter {
            if case .valid = $0.validityStatus() { return true }
            return $0.validityStatus() == .permanent
        }.count
        let expiring = store.documents.filter {
            if case .expiringSoon = $0.validityStatus() { return true }
            return false
        }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("证照概览", systemImage: "person.text.rectangle.fill")
                    .font(.headline)
                Spacer()
                if !canAccess {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                overviewMetric("全部", value: store.documents.count, color: .accentColor)
                overviewMetric("正常", value: normal, color: .green)
                overviewMetric("临近到期", value: expiring, color: .orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func overviewMetric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func documentLink(_ group: CredentialDocumentGroup) -> some View {
        NavigationLink {
            CredentialDetailView(documentID: group.representative.id, isUnlocked: $isUnlocked)
        } label: {
            CredentialDocumentRow(
                document: group.representative,
                versionCount: group.versionCount,
                isHolderRevealed: canAccess
            )
        }
        .appListRowStyle()
        .appDeleteSwipeAction(isEnabled: true) {
            store.delete(ids: [group.id])
        }
    }

    private func loadMoreIfNeeded(_ group: CredentialDocumentGroup) {
        pagination.loadMoreIfNeeded(
            currentItemID: group.id,
            lastVisibleItemID: pagedGroups.last?.id,
            totalItemCount: visibleGroups.count
        )
    }

}

private struct CredentialDocumentRow: View {
    let document: CredentialDocument
    let versionCount: Int
    let isHolderRevealed: Bool

    private var protectedDisplayTitle: String {
        let type = document.typeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let holder = document.holderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !holder.isEmpty else { return type }
        return "\(type)-\(isHolderRevealed ? holder : "••••••")"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.type.systemImage)
                .appFont(.title3)
                .foregroundStyle(.teal)
                .frame(width: 42, height: 42)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(protectedDisplayTitle)
                    .appFont(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(document.typeTitle)
                        .appFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if versionCount > 1 {
                        Text("\(versionCount) 个版本")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    CredentialVersionStatusLabel(status: document.versionStatus)
                    CredentialStatusLabel(status: document.validityStatus())
                }
                if let expiration = document.expirationDate(), document.validity.kind != .permanent {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                        Text(AppDateFormatter.string(from: expiration))
                    }
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .layoutPriority(1)
                        .foregroundStyle({
                            if case .expired = document.validityStatus() { return Color.red }
                            if case .expiringSoon = document.validityStatus() { return Color.orange }
                            return Color.secondary
                        }())
                }
            }
            Spacer(minLength: 4)
            Image(systemName: isHolderRevealed ? "lock.open.fill" : "lock.fill")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DocumentsFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var typeFilter: CredentialTypeFilter
    @Binding var statusFilter: CredentialStatusFilter
    @Binding var versionStatusFilter: CredentialVersionStatusFilter
    @Binding var selectedTag: String
    let availableTags: [String]

    var body: some View {
        NavigationStack {
            Form {
                PickerFieldRow(title: "类型", selection: $typeFilter) {
                    Text(CredentialTypeFilter.all.title).tag(CredentialTypeFilter.all)
                    ForEach(CredentialDocumentType.allCases) { type in Text(type.title).tag(CredentialTypeFilter.type(type)) }
                }
                PickerFieldRow(title: "有效期", selection: $statusFilter) {
                    ForEach(CredentialStatusFilter.allCases) { status in Text(status.title).tag(status) }
                }
                PickerFieldRow(title: "证照状态", selection: $versionStatusFilter) {
                    Text(CredentialVersionStatusFilter.all.title).tag(CredentialVersionStatusFilter.all)
                    ForEach(CredentialVersionStatus.allCases) { status in Text(status.title).tag(CredentialVersionStatusFilter.status(status)) }
                }
                if !availableTags.isEmpty {
                    Section("标签") { AppTagFilterCapsules(tags: availableTags, selectedTag: $selectedTag) }
                }
                Section {
                    Button("清除筛选", systemImage: "xmark.circle") {
                        typeFilter = .all; statusFilter = .all; versionStatusFilter = .all; selectedTag = ""
                    }.foregroundStyle(.red)
                }
            }
            .appNavigationTitle("筛选证照")
            .diagnosticScreen("筛选证照")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

#endif
