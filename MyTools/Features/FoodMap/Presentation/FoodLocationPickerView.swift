#if MYTOOLS_FEATURE_FOOD_MAP
import MapKit
import SwiftUI

struct FoodLocationSelection: Sendable {
    let name: String
    let address: String
    let coordinate: FoodCoordinate
    let administrativeLocation: ChinaAdministrativeLocation?
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
        } else {
            _selectedLocation = State(initialValue: nil)
            _position = State(initialValue: .automatic)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("搜索店名或地址", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    Button(action: search) {
                        if isSearching {
                            ProgressView()
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    .accessibilityLabel("搜索地点")
                }
                .padding(12)

                MapReader { proxy in
                    Map(position: $position) {
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
                            selectedLocation = FoodLocationSelection(
                                name: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                address: "",
                                coordinate: FoodCoordinate(
                                    latitude: coordinate.latitude,
                                    longitude: coordinate.longitude
                                ),
                                administrativeLocation: nil
                            )
                        }
                    )
                }
                .frame(minHeight: 280, idealHeight: 360)

                if !results.isEmpty {
                    List(results, id: \.self) { item in
                        Button {
                            select(item)
                        } label: {
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
                    .disabled(selectedLocation == nil)
                }
            }
            .onDisappear { searchTask?.cancel() }
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
        selectedLocation = selection
        position = .region(FoodLocationCard.region(around: selection.coordinate))
    }
}

#endif
