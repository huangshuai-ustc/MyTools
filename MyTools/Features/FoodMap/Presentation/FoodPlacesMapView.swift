#if MYTOOLS_FEATURE_FOOD_MAP
import MapKit
import SwiftUI

struct FoodPlacesMapView: View {
    @EnvironmentObject private var store: FoodMapStore
    @State private var selectedPlaceID: UUID?
    @State private var position: MapCameraPosition = .automatic

    private var places: [FoodPlace] {
        store.places
            .filter { $0.coordinate?.isValid == true }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    private var selectedPlace: FoodPlace? {
        places.first { $0.id == selectedPlaceID }
    }

    var body: some View {
        Map(position: $position) {
            ForEach(places) { place in
                if let coordinate = place.coordinate {
                    Annotation(
                        place.shopName.isEmpty ? place.displayTitle : place.shopName,
                        coordinate: coordinate.mapCoordinate
                    ) {
                        Button {
                            selectedPlaceID = place.id
                        } label: {
                            Image(systemName: "fork.knife.circle.fill")
                                .appFont(.title)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(place.status.tint, Color.white)
                                .shadow(radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(place.displayTitle)，\(place.locationSummary)")
                    }
                }
            }
        }
        .overlay {
            if places.isEmpty {
                ContentUnavailableView(
                    "暂无地图定位",
                    systemImage: "map",
                    description: Text("为美食记录选择地图位置后会显示在这里。")
                )
                .background(.background.opacity(0.9))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selectedPlace {
                selectedPlaceBar(selectedPlace)
            }
        }
        .appNavigationTitle("全部美食地点")
        .iOSLabeledBackButton("美食地图")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    fitAllPlaces()
                } label: {
                    Image(systemName: "viewfinder")
                }
                .disabled(places.isEmpty)
                .accessibilityLabel("显示全部地点")
                .help("显示全部地点")
            }
        }
        .onAppear(perform: fitAllPlaces)
        .onChange(of: places.map(\.id)) { _, _ in
            if let selectedPlaceID, !places.contains(where: { $0.id == selectedPlaceID }) {
                self.selectedPlaceID = nil
            }
            fitAllPlaces()
        }
    }

    private func selectedPlaceBar(_ place: FoodPlace) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(place.displayTitle).appFont(.headline).lineLimit(1)
                    FoodStatusLabel(status: place.status)
                }
                Text(place.locationSummary)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FoodNavigationMenu(place: place)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .accessibilityLabel("选择导航应用")
            NavigationLink {
                FoodPlaceDetailView(placeID: place.id)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("查看美食详情")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func fitAllPlaces() {
        let coordinates = places.compactMap(\.coordinate)
        guard let first = coordinates.first else {
            position = .automatic
            return
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minimumLatitude = latitudes.min() ?? first.latitude
        let maximumLatitude = latitudes.max() ?? first.latitude
        let minimumLongitude = longitudes.min() ?? first.longitude
        let maximumLongitude = longitudes.max() ?? first.longitude
        let latitudeDelta = max((maximumLatitude - minimumLatitude) * 1.4, 0.025)
        let longitudeDelta = max((maximumLongitude - minimumLongitude) * 1.4, 0.025)
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        ))
    }
}

#endif
