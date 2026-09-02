#if MYTOOLS_FEATURE_FOOD_MAP
import SwiftUI

private enum FoodStatusFilter: Hashable {
    case all
    case status(FoodPlaceStatus)

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .status(let status): return status.title
        }
    }

    func includes(_ place: FoodPlace) -> Bool {
        switch self {
        case .all: return true
        case .status(let status): return place.status == status
        }
    }
}

struct FoodMapView: View {
    private static let pageSize = 30
    @EnvironmentObject private var store: FoodMapStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var statusFilter: FoodStatusFilter = .all
    @State private var selectedTag = ""
    @State private var editingPlace: FoodPlace?
    @State private var showingDianpingImport = false
    @State private var showingSourceRefresh = false
    @State private var pagination = AppListPagination(pageSize: FoodMapView.pageSize)

    private var locatedPlaceCount: Int {
        store.places.lazy.filter { $0.coordinate?.isValid == true }.count
    }

    private var availableTags: [String] {
        AppTagSupport.normalize(store.places.flatMap(\.tags))
            .sorted { AppAlphabeticalSort.isOrderedBefore($0, $1) }
    }

    private var visiblePlaces: [FoodPlace] {
        store.places
            .filter(statusFilter.includes)
            .filter { selectedTag.isEmpty || $0.tags.contains(selectedTag) }
            .filter { $0.matches(query) }
            .sorted { lhs, rhs in
                AppAlphabeticalSort.isOrderedBefore(
                    lhs.displayTitle,
                    rhs.displayTitle,
                    lhsTieBreaker: lhs.id.uuidString,
                    rhsTieBreaker: rhs.id.uuidString
                )
            }
    }

    private var pagedPlaces: [FoodPlace] {
        pagination.visibleItems(from: visiblePlaces)
    }

    var body: some View {
        List {
            Section("地点地图") {
                NavigationLink {
                    FoodPlacesMapView()
                } label: {
                    LabeledContent {
                        Text("\(locatedPlaceCount) 个地点")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("查看全部标记", systemImage: "map")
                    }
                }
                .appListRowStyle()
            }

            if !store.places.isEmpty {
                Section("筛选") {
                    PickerFieldRow(title: "状态", selection: $statusFilter) {
                        Text(FoodStatusFilter.all.title).tag(FoodStatusFilter.all)
                        ForEach(FoodPlaceStatus.allCases) { status in
                            Text(status.title).tag(FoodStatusFilter.status(status))
                        }
                    }

                    if !availableTags.isEmpty {
                        AppTagFilterCapsules(tags: availableTags, selectedTag: $selectedTag)
                    }
                }
            }

            Section("美食记录") {
                if visiblePlaces.isEmpty {
                    ContentUnavailableView(
                        store.places.isEmpty ? "暂无美食记录" : "没有匹配的记录",
                        systemImage: store.places.isEmpty ? "fork.knife" : "magnifyingglass"
                    )
                }

                ForEach(pagedPlaces) { place in
                    placeLink(place)
                        .onAppear { loadMoreIfNeeded(place) }
                }
            }
        }
        .appNavigationTitle(ToolModule.foodMap.title)
        .iOSLabeledBackButton("工具")
        .searchable(text: $query, prompt: "搜索店名、推荐食物、特色、地址或标签")
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingSourceRefresh = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("更新全部店铺资料")
                .help("更新全部店铺资料")

                AdminEditAccessButton()

                if auth.isAdmin {
                    Button {
                        editingPlace = FoodPlace()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加美食记录")
                    .contextMenu {
                        Button {
                            showingDianpingImport = true
                        } label: {
                            Label("从大众点评导入", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
        }
        .sheet(item: $editingPlace) { place in
            FoodPlaceEditorView(place: place)
                .id(place.id)
                .iOSLargeSheet()
        }
        .sheet(isPresented: $showingDianpingImport) {
            DianpingImportView()
                .iOSLargeSheet()
        }
        .sheet(isPresented: $showingSourceRefresh) {
            FoodPlaceSourceRefreshView()
                .iOSLargeSheet()
        }
        .onChange(of: availableTags) { _, tags in
            if !selectedTag.isEmpty, !tags.contains(selectedTag) {
                selectedTag = ""
            }
        }
        .onChange(of: query) { _, _ in pagination.reset() }
        .onChange(of: statusFilter) { _, _ in pagination.reset() }
        .onChange(of: selectedTag) { _, _ in pagination.reset() }
    }

    private func placeLink(_ place: FoodPlace) -> some View {
        NavigationLink {
            FoodPlaceDetailView(placeID: place.id)
        } label: {
            FoodPlaceRow(place: place)
        }
        .appListRowStyle()
        .appDeleteSwipeAction(isEnabled: auth.isAdmin) {
            store.delete(ids: [place.id])
        }
    }

    private func loadMoreIfNeeded(_ place: FoodPlace) {
        pagination.loadMoreIfNeeded(
            currentItemID: place.id,
            lastVisibleItemID: pagedPlaces.last?.id,
            totalItemCount: visiblePlaces.count
        )
    }

}

private struct FoodPlaceRow: View {
    @EnvironmentObject private var store: FoodMapStore
    let place: FoodPlace

    var body: some View {
        HStack(spacing: 12) {
            if let photo = place.photos.first {
                FoodPhotoThumbnail(url: store.photoURL(for: photo), size: 58)
            } else {
                Image(systemName: "fork.knife")
                    .appFont(.title3)
                    .foregroundStyle(place.status.tint)
                    .frame(width: 58, height: 58)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(place.displayTitle)
                        .appFont(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    FoodStatusLabel(status: place.status)
                }
                FoodPlaceMetricsView(place: place)
                if !place.specialty.isEmpty {
                    Label(place.specialty, systemImage: "sparkles")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(place.locationSummary)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !place.recommendedFood.isEmpty {
                    Text("推荐：\(place.recommendedFood)")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                AppTagCapsules(tags: place.tags, limit: 3)
            }
        }
    }
}

#endif
