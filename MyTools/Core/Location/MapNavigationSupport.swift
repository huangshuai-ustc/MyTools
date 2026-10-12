import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AppMapNavigationApplication: String, CaseIterable, Identifiable, Sendable {
    case appleMaps, amap, baiduMaps, tencentMaps, googleMaps

    var id: Self { self }
    var title: String {
        switch self {
        case .appleMaps: "Apple 地图"
        case .amap: "高德地图"
        case .baiduMaps: "百度地图"
        case .tencentMaps: "腾讯地图"
        case .googleMaps: "Google 地图"
        }
    }
    var systemImage: String {
        switch self {
        case .appleMaps: "map.fill"
        default: "location.fill"
        }
    }
}

struct AppMapNavigationTarget: Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 }
}

enum AppMapNavigationService {
    static func url(for application: AppMapNavigationApplication, target: AppMapNavigationTarget) -> URL? {
        guard target.isValid else { return nil }
        let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "地图位置" : target.name
        let coordinate = "\(target.latitude),\(target.longitude)"
        func make(_ scheme: String, _ host: String?, _ path: String = "", _ items: [URLQueryItem]) -> URL? {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.path = path
            components.queryItems = items
            return components.url
        }
        switch application {
        case .appleMaps:
            return make("maps", nil, "", [URLQueryItem(name: "q", value: name), URLQueryItem(name: "ll", value: coordinate)])
        case .amap:
            return make("iosamap", "viewMap", "", [
                URLQueryItem(name: "sourceApplication", value: AppMetadata.appName),
                URLQueryItem(name: "poiname", value: name), URLQueryItem(name: "lat", value: String(target.latitude)),
                URLQueryItem(name: "lon", value: String(target.longitude)), URLQueryItem(name: "dev", value: "0")
            ])
        case .baiduMaps:
            return make("baidumap", "map/geocoder", "", [URLQueryItem(name: "location", value: coordinate), URLQueryItem(name: "name", value: name)])
        case .tencentMaps:
            return make("qqmap", "map", "/routeplan", [URLQueryItem(name: "type", value: "drive"), URLQueryItem(name: "to", value: name), URLQueryItem(name: "tocoord", value: coordinate), URLQueryItem(name: "referer", value: AppMetadata.bundleIdentifier)])
        case .googleMaps:
            return make("comgooglemaps", nil, "", [URLQueryItem(name: "q", value: name), URLQueryItem(name: "center", value: coordinate)])
        }
    }

    @MainActor
    @discardableResult
    static func open(_ application: AppMapNavigationApplication, target: AppMapNavigationTarget) -> Bool {
        guard let url = url(for: application, target: target) else { return false }
#if os(iOS)
        UIApplication.shared.open(url)
        return true
#elseif os(macOS)
        return NSWorkspace.shared.open(url)
#else
        return false
#endif
    }
}
