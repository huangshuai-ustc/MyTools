#if MYTOOLS_FEATURE_FOOD_MAP
import CoreLocation
import Foundation
import MapKit
import SwiftUI

struct FoodLocationSelection: Sendable {
    let name: String
    let address: String
    let coordinate: FoodCoordinate
    let administrativeLocation: ChinaAdministrativeLocation?
}

final class FoodLocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager: CLLocationManager

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
#if os(iOS)
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
#else
        authorizationStatus == .authorized
#endif
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
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

struct FoodLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (FoodLocationSelection) -> Void
    @State private var query: String
    @State private var results: [MKMapItem] = []
    @State private var selectedLocation: FoodLocationSelection?
    @State private var position: MapCameraPosition
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var selectionTask: Task<Void, Never>?
    @State private var isResolvingSelection = false
    @State private var didCenterOnNearby = false
    @StateObject private var locationManager = FoodLocationPermissionManager()

    init(place: FoodPlace, onSelect: @escaping (FoodLocationSelection) -> Void) {
        self.onSelect = onSelect
        _query = State(initialValue: place.shopName)
        if let coordinate = place.coordinate, coordinate.isValid {
            let selection = FoodLocationSelection(
                name: place.shopName,
                address: place.address,
                coordinate: coordinate,
                administrativeLocation: place.administrativeLocation
            )
            _selectedLocation = State(initialValue: selection)
            _position = State(initialValue: .region(FoodLocationCard.region(around: coordinate)))
            _didCenterOnNearby = State(initialValue: true)
        } else {
            _selectedLocation = State(initialValue: nil)
            _position = State(initialValue: .automatic)
            _didCenterOnNearby = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索店名或地址", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit(search)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索内容")
                    }
                    Button(action: search) {
                        Group {
                            if isSearching {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    .accessibilityLabel("搜索地点")
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.separator.opacity(0.55), lineWidth: 0.5)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                MapReader { proxy in
                    Map(position: $position) {
                        if locationManager.isAuthorized {
                            UserAnnotation()
                        }
                        if let selectedLocation {
                            Marker(
                                selectedLocation.name.isEmpty ? "所选位置" : selectedLocation.name,
                                coordinate: selectedLocation.coordinate.mapCoordinate
                            )
                            .tint(.red)
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                            let selection = FoodLocationSelection(
                                name: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                address: "",
                                coordinate: FoodCoordinate(
                                    latitude: coordinate.latitude,
                                    longitude: coordinate.longitude
                                ),
                                administrativeLocation: nil
                            )
                            setSelection(selection, reverseGeocode: true)
                        }
                    )
#if os(iOS)
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                    }
#endif
                }
                .frame(minHeight: 280, idealHeight: 360)

                if !results.isEmpty {
                    List(results, id: \.self) { item in
                        Button {
                            select(item)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name ?? "未命名地点")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    if let address = item.address?.fullAddress, !address.isEmpty {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if isSelected(item) {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.blue)
                                        .accessibilityLabel("已选中")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: 160, maxHeight: 260)
                }
            }
            .navigationTitle("选择地图位置")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用此位置") {
                        guard let selectedLocation else { return }
                        onSelect(selectedLocation)
                    }
                    .disabled(selectedLocation == nil || isResolvingSelection)
                }
            }
            .onAppear { locationManager.requestPermission() }
            .onChange(of: locationManager.coordinate?.latitude) { _, _ in
                centerOnNearbyIfNeeded(locationManager.coordinate)
            }
            .onDisappear {
                searchTask?.cancel()
                selectionTask?.cancel()
            }
            .alert(
                "无法搜索地点",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func search() {
        commitPendingTextInput { performSearch() }
    }

    private func performSearch() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchTask = Task { @MainActor in
            defer { isSearching = false }
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = term
                if let coordinate = locationManager.coordinate {
                    request.region = nearbyRegion(around: coordinate)
                }
                let response = try await MKLocalSearch(request: request).start()
                try Task.checkCancellation()
                results = Array(response.mapItems.prefix(12))
                if let first = results.first {
                    select(first)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func select(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        let address = item.address?.fullAddress ?? ""
        let locationContext = [
            address,
            item.addressRepresentations?.cityWithContext
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        let selection = FoodLocationSelection(
            name: item.name ?? query,
            address: address,
            coordinate: FoodCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
            administrativeLocation: ChinaAdministrativeDivisions.infer(from: locationContext)
        )
        setSelection(selection, reverseGeocode: true)
    }

    private func setSelection(_ selection: FoodLocationSelection, reverseGeocode: Bool) {
        selectedLocation = selection
        position = .region(FoodLocationCard.region(around: selection.coordinate))
        guard reverseGeocode else {
            isResolvingSelection = false
            return
        }
        selectionTask?.cancel()
        isResolvingSelection = true
        selectionTask = Task { @MainActor in
            defer { isResolvingSelection = false }
            await enrich(selection)
        }
    }

    private func enrich(_ selection: FoodLocationSelection) async {
        do {
            guard let request = MKReverseGeocodingRequest(
                location: CLLocation(latitude: selection.coordinate.latitude, longitude: selection.coordinate.longitude)
            ) else { return }
            let mapItems = try await request.mapItems
            guard let item = mapItems.first,
                  !Task.isCancelled,
                  selectedLocation?.coordinate == selection.coordinate else { return }
            selectedLocation = refinedSelection(selection, mapItem: item)
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func refinedSelection(
        _ selection: FoodLocationSelection,
        mapItem: MKMapItem
    ) -> FoodLocationSelection {
        let address = mapItem.address?.fullAddress
            ?? mapItem.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? ""
        let context = [
            selection.address,
            address,
            mapItem.addressRepresentations?.cityWithContext,
            mapItem.addressRepresentations?.cityName,
            mapItem.addressRepresentations?.regionName
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        let inferred = ChinaAdministrativeDivisions.infer(from: context)
        let administrativeLocation: ChinaAdministrativeLocation?
        if let inferred {
            administrativeLocation = ChinaAdministrativeDivisions.location(
                province: inferred.province,
                city: inferred.city,
                district: district(in: address, excluding: [inferred.province, inferred.city])
            )
        } else {
            administrativeLocation = nil
        }
        return FoodLocationSelection(
            name: selection.name,
            address: selection.address.isEmpty ? address : selection.address,
            coordinate: selection.coordinate,
            administrativeLocation: administrativeLocation
        )
    }

    private func district(in address: String, excluding values: [String]) -> String? {
        let normalizedValues = Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        let tail = addressTail(in: address, after: values)
        let patterns = [
            "[\\p{Han}A-Za-z0-9·]{1,24}(?:区|县|旗|林区)",
            "[\\p{Han}A-Za-z0-9·]{1,24}(?:镇|乡|街道)"
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(tail.startIndex..., in: tail)
            if let match = expression.firstMatch(in: tail, range: range),
               let matchRange = Range(match.range, in: tail) {
                let value = String(tail[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !normalizedValues.contains(value) {
                    return value
                }
            }
        }
        return nil
    }

    private func addressTail(in address: String, after values: [String]) -> String {
        for value in values.reversed() {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let candidates = [normalized, administrativeAlias(for: normalized)]
            for candidate in candidates where !candidate.isEmpty {
                if let range = address.range(of: candidate) {
                    return String(address[range.upperBound...])
                }
            }
        }
        return address
    }

    private func administrativeAlias(for value: String) -> String {
        for suffix in ["特别行政区", "自治区", "省", "市"] where value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
        return value
    }

    private func isSelected(_ item: MKMapItem) -> Bool {
        guard let selectedLocation else { return false }
        let coordinate = item.location.coordinate
        return abs(coordinate.latitude - selectedLocation.coordinate.latitude) < 0.000001
            && abs(coordinate.longitude - selectedLocation.coordinate.longitude) < 0.000001
    }

    private func centerOnNearbyIfNeeded(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate,
              selectedLocation == nil,
              !didCenterOnNearby else { return }
        position = .region(nearbyRegion(around: coordinate))
        didCenterOnNearby = true
    }

    private func nearbyRegion(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
        )
    }
}

#endif
