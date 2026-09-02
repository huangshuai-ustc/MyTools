import CoreLocation
import Foundation
import MapKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum MapLocationSearchService {
    static func search(query: String, region: MKCoordinateRegion? = nil) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region {
            request.region = region
        }
        let response = try await MKLocalSearch(request: request).start()
        try Task.checkCancellation()
        if !response.mapItems.isEmpty {
            return Array(response.mapItems.prefix(12))
        }

        let normalizedQuery = query
            .replacingOccurrences(of: "\n", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let geocodingRequest = MKGeocodingRequest(addressString: normalizedQuery) else {
            return []
        }
        let mapItems = try await geocodingRequest.mapItems
        try Task.checkCancellation()
        return Array(mapItems.prefix(12))
    }
}

struct MapLocationSearchResultRow: View {
    let item: MKMapItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? "未命名地点")
                    .appFont(.headline)
                    .foregroundStyle(.primary)
                Text(address)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .appFont(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                    .accessibilityLabel("已选中")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var address: String {
        item.address?.fullAddress
            ?? item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? ""
    }
}

struct MapLocationSelection {
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D
    var administrativeContext: String
}

struct MapLocationPickerConfiguration {
    var title: String
    var searchPlaceholder: String
    var markerTitle: String
    var initialSearchText: String = ""
    var initialSelection: MapLocationSelection?
    var defaultCoordinate: CLLocationCoordinate2D?
    var centersOnUserLocation = false
}

final class MapLocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
#if os(iOS)
            manager.requestWhenInUseAuthorization()
#else
            manager.requestAlwaysAuthorization()
#endif
        } else if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        self.coordinate = coordinate
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }
}

struct MapLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationManager = MapLocationPermissionManager()
    let configuration: MapLocationPickerConfiguration
    let onSave: (MapLocationSelection) -> Void

    @State private var position: MapCameraPosition
    @State private var searchText: String
    @State private var results: [MKMapItem] = []
    @State private var selection: MapLocationSelection?
    @State private var isSearching = false
    @State private var isResolving = false
    @State private var hasCenteredOnUser = false
    @State private var searchTask: Task<Void, Never>?
    @State private var reverseGeocodeTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    init(configuration: MapLocationPickerConfiguration, onSave: @escaping (MapLocationSelection) -> Void) {
        self.configuration = configuration
        self.onSave = onSave
        _searchText = State(initialValue: configuration.initialSearchText)
        _selection = State(initialValue: configuration.initialSelection)
        let center = configuration.initialSelection?.coordinate ?? configuration.defaultCoordinate
        if let center {
            _position = State(initialValue: .region(Self.region(around: center)))
        } else {
            _position = State(initialValue: .automatic)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                searchBar

                ScrollView {
                    VStack(spacing: 12) {
                        map
                        if !results.isEmpty {
                            resultList
                        }
                    }
                }
#if os(iOS)
                .scrollDismissesKeyboard(.interactively)
#endif

                Button {
                    guard let selection else { return }
                    onSave(selection)
                    dismiss()
                } label: {
                    Text(isResolving ? "正在解析地址..." : "使用此位置")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil || isResolving)
            }
            .padding()
            .appNavigationTitle(configuration.title)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            if configuration.centersOnUserLocation {
                locationManager.requestPermission()
            }
        }
        .onChange(of: locationManager.coordinate?.latitude) { _, _ in
            centerOnUserLocationIfNeeded()
        }
        .onDisappear {
            searchTask?.cancel()
            reverseGeocodeTask?.cancel()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(configuration.searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { performSearch() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    results = []
                    searchTask?.cancel()
                    searchFocused = false
                    dismissKeyboard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Button { performSearch() } label: {
                if isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                }
            }
            .buttonStyle(.plain)
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            .accessibilityLabel("搜索")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let selection {
                    Marker(selection.name.isEmpty ? configuration.markerTitle : selection.name,
                           coordinate: selection.coordinate)
                }
#if os(iOS)
                UserAnnotation()
#endif
            }
            .mapControls {
#if os(iOS)
                MapUserLocationButton()
#endif
                MapCompass()
            }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                let value = MapLocationSelection(
                    name: configuration.markerTitle,
                    address: "",
                    coordinate: coordinate,
                    administrativeContext: ""
                )
                selection = value
                resolveAddress(for: value)
            }
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var resultList: some View {
        LazyVStack(spacing: 0) {
            ForEach(results, id: \.self) { item in
                Button { select(item) } label: {
                    MapLocationSearchResultRow(item: item, isSelected: isSelected(item))
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if item != results.last {
                    Divider()
                }
            }
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchFocused = false
        dismissKeyboard()
        searchTask?.cancel()
        isSearching = true
        searchTask = Task { @MainActor in
            defer { isSearching = false }
            do {
                results = try await MapLocationSearchService.search(query: query)
            } catch is CancellationError {
                return
            } catch {
                results = []
            }
        }
    }

    private func select(_ item: MKMapItem) {
        searchFocused = false
        dismissKeyboard()
        let coordinate = item.location.coordinate
        let selectedName = item.name ?? configuration.markerTitle
        let address = item.address?.fullAddress
            ?? item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? ""
        searchText = selectedName
        selection = MapLocationSelection(
            name: selectedName,
            address: address,
            coordinate: coordinate,
            administrativeContext: [
                address,
                item.addressRepresentations?.cityWithContext,
                item.addressRepresentations?.cityName,
                item.addressRepresentations?.regionName
            ].compactMap { $0 }.joined(separator: " ")
        )
        position = .region(Self.region(around: coordinate))
    }

    private func dismissKeyboard() {
#if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
#endif
    }

    private func resolveAddress(for value: MapLocationSelection) {
        reverseGeocodeTask?.cancel()
        isResolving = true
        reverseGeocodeTask = Task { @MainActor in
            defer { isResolving = false }
            do {
                guard let request = MKReverseGeocodingRequest(
                    location: CLLocation(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude)
                ) else { return }
                let items = try await request.mapItems
                guard let item = items.first,
                      !Task.isCancelled,
                      coordinatesMatch(selection?.coordinate, value.coordinate) else { return }
                select(item)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func isSelected(_ item: MKMapItem) -> Bool {
        coordinatesMatch(selection?.coordinate, item.location.coordinate)
    }

    private func centerOnUserLocationIfNeeded() {
        guard configuration.centersOnUserLocation,
              configuration.initialSelection == nil,
              !hasCenteredOnUser,
              let coordinate = locationManager.coordinate else { return }
        hasCenteredOnUser = true
        position = .region(Self.region(around: coordinate))
    }

    private func coordinatesMatch(_ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.latitude - rhs.latitude) < 0.000001
            && abs(lhs.longitude - rhs.longitude) < 0.000001
    }

    private static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )
    }
}
