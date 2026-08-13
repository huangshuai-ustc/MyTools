#if MYTOOLS_FEATURE_FOOD_MAP
import MapKit
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension FoodPlaceStatus {
    var tint: Color {
        switch self {
        case .tried: return .green
        case .wantToTry: return .pink
        }
    }
}

extension FoodCoordinate {
    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct FoodStatusLabel: View {
    let status: FoodPlaceStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption)
            .foregroundStyle(status.tint)
            .accessibilityElement(children: .combine)
    }
}

struct FoodNavigationMenu: View {
    let place: FoodPlace

    private var applications: [FoodNavigationApplication] {
        FoodNavigationService.availableApplications(for: place)
    }

    var body: some View {
        Menu {
            ForEach(applications) { application in
                Button {
                    FoodNavigationService.open(application, for: place)
                } label: {
                    Label(application.title, systemImage: application.systemImage)
                }
            }
        } label: {
            Label("路线", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
        }
        .disabled(applications.isEmpty)
        .help("选择导航应用")
    }
}

struct FoodLocationCard: View {
    let place: FoodPlace

    var body: some View {
        if let coordinate = place.coordinate, coordinate.isValid {
            VStack(alignment: .leading, spacing: 0) {
                Map(
                    initialPosition: .region(Self.region(around: coordinate)),
                    interactionModes: []
                ) {
                    Marker(
                        place.shopName.isEmpty ? place.displayTitle : place.shopName,
                        coordinate: coordinate.mapCoordinate
                    )
                    .tint(place.status.tint)
                }
                .frame(height: 210)
                .accessibilityLabel("\(place.locationSummary)的地图位置")

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.shopName.isEmpty ? place.displayTitle : place.shopName)
                            .font(.headline)
                            .lineLimit(1)
                        if !place.address.isEmpty {
                            Text(place.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    FoodNavigationMenu(place: place)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("选择导航应用")
                }
                .padding(12)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 0.5)
            }
        }
    }

    static func region(around coordinate: FoodCoordinate) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate.mapCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }
}

struct FoodPhotoThumbnail: View {
    let url: URL
    var size: CGFloat = 64

#if os(iOS)
    @State private var platformImage: UIImage?
#elseif os(macOS)
    @State private var platformImage: NSImage?
#endif

    var body: some View {
        Group {
#if os(iOS)
            if let platformImage {
                Image(uiImage: platformImage).resizable()
            } else {
                placeholder
            }
#elseif os(macOS)
            if let platformImage {
                Image(nsImage: platformImage).resizable()
            } else {
                placeholder
            }
#endif
        }
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .clipped()
        .task(id: url) {
            await loadImage()
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }

    @MainActor
    private func loadImage() async {
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let data else { return }
#if os(iOS)
        platformImage = UIImage(data: data)
#elseif os(macOS)
        platformImage = NSImage(data: data)
#endif
    }
}

enum FoodSourceLink {
    static func url(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }
}

#endif
