#if MYTOOLS_FEATURE_FOOD_MAP
import MapKit
import SwiftUI

struct FoodPlacesMapView: View {
    @EnvironmentObject private var store: FoodMapStore
    @StateObject private var locationManager = MapLocationPermissionManager()
    @State private var selectedPlaceID: UUID?
    @State private var position: MapCameraPosition = .automatic
    @State private var hasCenteredOnUser = false

    private var places: [FoodPlace] {
        store.places
            .filter { $0.coordinate?.isValid == true }
            .sorted { lhs, rhs in
                AppAlphabeticalSort.isOrderedBefore(
                    lhs.displayTitle,
                    rhs.displayTitle,
                    lhsTieBreaker: lhs.id.uuidString,
                    rhsTieBreaker: rhs.id.uuidString
                )
            }
    }

    private var selectedPlace: FoodPlace? {
        places.first { $0.id == selectedPlaceID }
    }

    var body: some View {
        Map(position: $position) {
            if let coordinate = locationManager.coordinate {
                Annotation("当前位置", coordinate: coordinate) {
                    Image(systemName: "location.fill")
                        .appFont(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.blue, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(radius: 2, y: 1)
                        .accessibilityLabel("当前位置")
                }
            }

            ForEach(places) { place in
                if let coordinate = place.coordinate {
                    Annotation(
                        place.shopName.isEmpty ? place.displayTitle : place.shopName,
                        coordinate: coordinate.mapCoordinate
                    ) {
                        Button {
                            selectedPlaceID = place.id
                        } label: {
                            if let photo = place.photos.first {
                                FoodPhotoThumbnail(url: store.photoURL(for: photo), size: 42)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(place.status.tint, lineWidth: 3))
                                    .shadow(radius: 2, y: 1)
                            } else {
                                Image(systemName: "fork.knife.circle.fill")
                                    .appFont(.title)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(place.status.tint, Color.white)
                                    .shadow(radius: 2, y: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(place.displayTitle)，\(place.locationSummary)")
                    }
                }
            }
        }
        .overlay {
            if places.isEmpty, locationManager.coordinate == nil {
                ContentUnavailableView(
                    "暂无地图定位",
                    systemImage: "map",
                    description: Text("允许定位或为美食记录选择地图位置后会显示在这里。")
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    centerOnUserLocation()
                } label: {
                    Image(systemName: "location.fill")
                }
                .disabled(locationManager.coordinate == nil)
                .accessibilityLabel("回到当前位置")
                .help("回到当前位置")

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
        .task {
            fitAllPlaces()
            locationManager.requestPermission()
        }
        .onChange(of: locationManager.coordinate?.latitude) { _, _ in
            guard !hasCenteredOnUser else { return }
            centerOnUserLocation()
            hasCenteredOnUser = true
        }
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
        var coordinates = places.compactMap(\.coordinate)
        if let userCoordinate = locationManager.coordinate {
            coordinates.append(FoodCoordinate(
                latitude: userCoordinate.latitude,
                longitude: userCoordinate.longitude
            ))
        }
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

    private func centerOnUserLocation() {
        guard let coordinate = locationManager.coordinate else { return }
        position = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        ))
    }
}

#endif
