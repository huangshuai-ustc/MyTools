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
    @EnvironmentObject private var store: DocumentsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var typeFilter: CredentialTypeFilter = .all
    @State private var statusFilter: CredentialStatusFilter = .all
    @State private var versionStatusFilter: CredentialVersionStatusFilter = .all
    @State private var selectedTag = ""
    @State private var isUnlocked = false
    @State private var showingSensitiveAccess = false
    @State private var editingDocument: CredentialDocument?

    private var canAccess: Bool { auth.isAdmin || isUnlocked }

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
                CredentialDocument.versionDisplayPrecedes(
                    lhs.representative,
                    rhs.representative
                )
            }
    }

    var body: some View {
        List {
            if !store.documents.isEmpty {
                Section("筛选") {
                    Picker("类型", selection: $typeFilter) {
                        Text(CredentialTypeFilter.all.title).tag(CredentialTypeFilter.all)
                        ForEach(CredentialDocumentType.allCases) { type in
                            Text(type.title).tag(CredentialTypeFilter.type(type))
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("有效期", selection: $statusFilter) {
                        ForEach(CredentialStatusFilter.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("证照状态", selection: $versionStatusFilter) {
                        Text(CredentialVersionStatusFilter.all.title)
                            .tag(CredentialVersionStatusFilter.all)
                        ForEach(CredentialVersionStatus.allCases) { status in
                            Text(status.title)
                                .tag(CredentialVersionStatusFilter.status(status))
                        }
                    }
                    .pickerStyle(.menu)
                    if !availableTags.isEmpty {
                        AppTagFilterCapsules(tags: availableTags, selectedTag: $selectedTag)
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
                ForEach(visibleGroups) { group in
                    documentLink(group)
                }
            }
        }
        .appNavigationTitle(ToolModule.documents.title)
        .iOSLabeledBackButton("工具")
        .searchable(text: $query, prompt: "搜索名称、号码、持有人或标签")
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !canAccess {
                    Button {
                        showingSensitiveAccess = true
                    } label: {
                        Image(systemName: "faceid")
                    }
                    .accessibilityLabel("验证身份后查看证照信息")
                }
                AdminEditAccessButton()
                if auth.isAdmin {
                    Button {
                        editingDocument = CredentialDocument()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加证照")
                }
            }
        }
        .sheet(isPresented: $showingSensitiveAccess) {
            SensitiveAccessView { isUnlocked = true }
                .iOSAuthenticationSheet()
        }
        .sheet(item: $editingDocument) { document in
            CredentialEditorView(document: document)
                .id(document.id)
                .iOSLargeSheet()
        }
        .onChange(of: auth.isAdmin) { _, isAdmin in
            isUnlocked = isAdmin
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isUnlocked = false }
        }
        .onChange(of: availableTags) { _, tags in
            if !selectedTag.isEmpty, !tags.contains(selectedTag) {
                selectedTag = ""
            }
        }
    }

    private func documentLink(_ group: CredentialDocumentGroup) -> some View {
        NavigationLink {
            CredentialDetailView(documentID: group.representative.id, isUnlocked: $isUnlocked)
        } label: {
            CredentialDocumentRow(
                document: group.representative,
                versionCount: group.versionCount
            )
        }
        .appListRowStyle()
        .appDeleteSwipeAction(isEnabled: auth.isAdmin) {
            store.delete(ids: [group.id])
        }
    }

}

private struct CredentialDocumentRow: View {
    let document: CredentialDocument
    let versionCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.type.systemImage)
                .appFont(.title3)
                .foregroundStyle(.teal)
                .frame(width: 42, height: 42)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text(document.listDisplayTitle)
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
                AppTagCapsules(tags: document.tags, limit: 3)
            }
            Spacer(minLength: 4)
            Image(systemName: "lock.fill")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#endif
