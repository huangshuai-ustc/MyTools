#if MYTOOLS_FEATURE_FOOD_MAP
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum FoodNavigationApplication: String, CaseIterable, Identifiable, Sendable {
    case appleMaps
    case amap
    case baiduMaps
    case tencentMaps
    case googleMaps

    var id: Self { self }

    var title: String {
        switch self {
        case .appleMaps: return "Apple 地图"
        case .amap: return "高德地图"
        case .baiduMaps: return "百度地图"
        case .tencentMaps: return "腾讯地图"
        case .googleMaps: return "Google 地图"
        }
    }

    var systemImage: String {
        switch self {
        case .appleMaps: return "map.fill"
        case .amap, .baiduMaps, .tencentMaps, .googleMaps: return "location.fill"
        }
    }
}

@MainActor
enum FoodNavigationService {
    static func availableApplications(for place: FoodPlace) -> [FoodNavigationApplication] {
        guard place.coordinate?.isValid == true else { return [] }
        return FoodNavigationApplication.allCases.filter { application in
            guard let url = url(for: application, place: place) else { return false }
#if os(iOS)
            return application == .appleMaps || UIApplication.shared.canOpenURL(url)
#elseif os(macOS)
            return application == .appleMaps || NSWorkspace.shared.urlForApplication(toOpen: url) != nil
#else
            return application == .appleMaps
#endif
        }
    }

    @discardableResult
    static func open(_ application: FoodNavigationApplication, for place: FoodPlace) -> Bool {
        guard let url = url(for: application, place: place) else { return false }
#if os(iOS)
        UIApplication.shared.open(url)
        return true
#elseif os(macOS)
        return NSWorkspace.shared.open(url)
#else
        return false
#endif
    }

    static func url(for application: FoodNavigationApplication, place: FoodPlace) -> URL? {
        guard let coordinate = place.coordinate, coordinate.isValid else { return nil }
        let name = place.shopName.isEmpty ? place.displayTitle : place.shopName
        let coordinateText = "\(coordinate.latitude),\(coordinate.longitude)"

        switch application {
        case .appleMaps:
            return makeURL(
                scheme: "maps",
                host: nil,
                path: "",
                queryItems: [
                    URLQueryItem(name: "daddr", value: coordinateText),
                    URLQueryItem(name: "q", value: name),
                    URLQueryItem(name: "dirflg", value: "d")
                ]
            )
        case .amap:
            return makeURL(
                scheme: "iosamap",
                host: "navi",
                path: "",
                queryItems: [
                    URLQueryItem(name: "sourceApplication", value: AppMetadata.appName),
                    URLQueryItem(name: "poiname", value: name),
                    URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                    URLQueryItem(name: "lon", value: String(coordinate.longitude)),
                    URLQueryItem(name: "dev", value: "0"),
                    URLQueryItem(name: "style", value: "2")
                ]
            )
        case .baiduMaps:
            return makeURL(
                scheme: "baidumap",
                host: "map",
                path: "/direction",
                queryItems: [
                    URLQueryItem(name: "destination", value: "latlng:\(coordinateText)|name:\(name)"),
                    URLQueryItem(name: "mode", value: "driving"),
                    URLQueryItem(name: "coord_type", value: "gcj02"),
                    URLQueryItem(name: "src", value: AppMetadata.bundleIdentifier)
                ]
            )
        case .tencentMaps:
            return makeURL(
                scheme: "qqmap",
                host: "map",
                path: "/routeplan",
                queryItems: [
                    URLQueryItem(name: "type", value: "drive"),
                    URLQueryItem(name: "to", value: name),
                    URLQueryItem(name: "tocoord", value: coordinateText),
                    URLQueryItem(name: "referer", value: AppMetadata.bundleIdentifier)
                ]
            )
        case .googleMaps:
            return makeURL(
                scheme: "comgooglemaps",
                host: nil,
                path: "",
                queryItems: [
                    URLQueryItem(name: "daddr", value: coordinateText),
                    URLQueryItem(name: "directionsmode", value: "driving")
                ]
            )
        }
    }

    private static func makeURL(
        scheme: String,
        host: String?,
        path: String,
        queryItems: [URLQueryItem]
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = queryItems
        return components.url
    }
}

#endif
