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
    @EnvironmentObject private var store: FoodMapStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var statusFilter: FoodStatusFilter = .all
    @State private var selectedTag: String?
    @State private var editingPlace: FoodPlace?

    private var locatedPlaceCount: Int {
        store.places.lazy.filter { $0.coordinate?.isValid == true }.count
    }

    private var availableTags: [String] {
        Set(store.places.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var visiblePlaces: [FoodPlace] {
        store.places
            .filter(statusFilter.includes)
            .filter { selectedTag == nil || $0.tags.contains(selectedTag!) }
            .filter { $0.matches(query) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
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
                    Picker("状态", selection: $statusFilter) {
                        Text(FoodStatusFilter.all.title).tag(FoodStatusFilter.all)
                        ForEach(FoodPlaceStatus.allCases) { status in
                            Text(status.title).tag(FoodStatusFilter.status(status))
                        }
                    }
                    .pickerStyle(.menu)

                    if !availableTags.isEmpty {
                        Picker("标签", selection: $selectedTag) {
                            Text("全部标签").tag(nil as String?)
                            ForEach(availableTags, id: \.self) { tag in
                                Text(tag).tag(tag as String?)
                            }
                        }
                        .pickerStyle(.menu)
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

                if auth.isAdmin {
                    ForEach(visiblePlaces) { place in
                        placeLink(place)
                    }
                    .onDelete(perform: delete)
                } else {
                    ForEach(visiblePlaces) { place in
                        placeLink(place)
                    }
                }
            }
        }
        .navigationTitle(ToolModule.foodMap.title)
        .iOSLabeledBackButton("工具")
        .searchable(text: $query, prompt: "搜索美食、店名、地点或标签")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NavigationLink {
                    FoodPlacesMapView()
                } label: {
                    Image(systemName: "map")
                }
                .accessibilityLabel("查看全部美食地点")
                .help("查看全部美食地点")

                AdminEditAccessButton()

                if auth.isAdmin {
                    Button {
                        editingPlace = FoodPlace()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加美食记录")
                }
            }
        }
        .sheet(item: $editingPlace) { place in
            FoodPlaceEditorView(place: place)
                .id(place.id)
                .iOSLargeSheet()
        }
        .onChange(of: availableTags) { _, tags in
            if let selectedTag, !tags.contains(selectedTag) {
                self.selectedTag = nil
            }
        }
    }

    private func placeLink(_ place: FoodPlace) -> some View {
        NavigationLink {
            FoodPlaceDetailView(placeID: place.id)
        } label: {
            FoodPlaceRow(place: place)
        }
        .appListRowStyle()
    }

    private func delete(at offsets: IndexSet) {
        let ids = Set(offsets.map { visiblePlaces[$0].id })
        store.delete(ids: ids)
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
                    .font(.title3)
                    .foregroundStyle(place.status.tint)
                    .frame(width: 58, height: 58)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(place.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    FoodStatusLabel(status: place.status)
                }
                if !place.shopName.isEmpty, place.shopName != place.displayTitle {
                    Text(place.shopName)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                Text(place.locationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

#endif
