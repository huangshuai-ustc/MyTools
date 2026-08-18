import CoreLocation
import Foundation

#if MYTOOLS_FEATURE_FOOD_MAP
import SwiftUI

struct FoodLocationSelection: Sendable {
    let name: String
    let address: String
    let coordinate: FoodCoordinate
    let administrativeLocation: ChinaAdministrativeLocation?
}

struct FoodLocationPickerView: View {
    let place: FoodPlace
    let onSelect: (FoodLocationSelection) -> Void

    var body: some View {
        MapLocationPickerView(
            configuration: MapLocationPickerConfiguration(
                title: "选择地图位置",
                searchPlaceholder: "搜索店名、商圈或地址",
                markerTitle: place.shopName.isEmpty ? "选中位置" : place.shopName,
                initialSearchText: place.shopName,
                initialSelection: initialSelection,
                defaultCoordinate: nil,
                centersOnUserLocation: initialSelection == nil
            )
        ) { selection in
            onSelect(FoodLocationSelection(
                name: selection.name,
                address: selection.address,
                coordinate: FoodCoordinate(
                    latitude: selection.coordinate.latitude,
                    longitude: selection.coordinate.longitude
                ),
                administrativeLocation: administrativeLocation(for: selection)
                    ?? place.administrativeLocation
            ))
        }
    }

    private var initialSelection: MapLocationSelection? {
        guard let coordinate = place.coordinate, coordinate.isValid else { return nil }
        return MapLocationSelection(
            name: place.shopName,
            address: place.address,
            coordinate: CLLocationCoordinate2D(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ),
            administrativeContext: place.administrativeLocation?.displayName ?? ""
        )
    }

    private func administrativeLocation(
        for selection: MapLocationSelection
    ) -> ChinaAdministrativeLocation? {
        let context = [selection.address, selection.administrativeContext]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let inferred = ChinaAdministrativeDivisions.infer(from: context) else { return nil }
        return ChinaAdministrativeDivisions.location(
            province: inferred.province,
            city: inferred.city,
            district: district(
                in: selection.address,
                excluding: [inferred.province, inferred.city]
            )
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
            for candidate in [normalized, administrativeAlias(for: normalized)] where !candidate.isEmpty {
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
}

#endif
