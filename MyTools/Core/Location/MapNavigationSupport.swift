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
    @MainActor
    static var availableApplications: [AppMapNavigationApplication] {
        applications { url in
#if os(iOS)
            UIApplication.shared.canOpenURL(url)
#elseif os(macOS)
            NSWorkspace.shared.urlForApplication(toOpen: url) != nil
#else
            false
#endif
        }
    }

    static func applications(canOpen: (URL) -> Bool) -> [AppMapNavigationApplication] {
        AppMapNavigationApplication.allCases.filter { application in
            guard let url = searchURL(for: application, query: "地图") else { return false }
            return canOpen(url)
        }
    }

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
            return make("baidumap", "map", "/marker", [
                URLQueryItem(name: "location", value: coordinate), URLQueryItem(name: "title", value: name),
                URLQueryItem(name: "content", value: name), URLQueryItem(name: "coord_type", value: "gcj02"),
                URLQueryItem(name: "src", value: "ios.\(AppMetadata.bundleIdentifier)"), URLQueryItem(name: "zoom", value: "16")
            ])
        case .tencentMaps:
            return make("qqmap", "map", "/marker", [
                URLQueryItem(name: "marker", value: "coord:\(coordinate);title:\(name);addr:\(name)"),
                URLQueryItem(name: "referer", value: AppMetadata.bundleIdentifier)
            ])
        case .googleMaps:
            return make("comgooglemaps", "", "", [URLQueryItem(name: "q", value: coordinate), URLQueryItem(name: "center", value: coordinate), URLQueryItem(name: "zoom", value: "16")])
        }
    }

    /// Name-only search for places without saved coordinates; the map app searches around the user's current location.
    static func searchURL(for application: AppMapNavigationApplication, query: String) -> URL? {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return nil }
        var components = URLComponents()
        switch application {
        case .appleMaps:
            components.scheme = "maps"
            components.queryItems = [URLQueryItem(name: "q", value: keyword)]
        case .amap:
            components.scheme = "iosamap"
            components.host = "poi"
            components.queryItems = [URLQueryItem(name: "sourceApplication", value: AppMetadata.appName), URLQueryItem(name: "name", value: keyword)]
        case .baiduMaps:
            components.scheme = "baidumap"
            components.host = "map"
            components.path = "/place/search"
            components.queryItems = [URLQueryItem(name: "query", value: keyword), URLQueryItem(name: "src", value: AppMetadata.bundleIdentifier)]
        case .tencentMaps:
            components.scheme = "qqmap"
            components.host = "map"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "keyword", value: keyword), URLQueryItem(name: "referer", value: AppMetadata.bundleIdentifier)]
        case .googleMaps:
            components.scheme = "comgooglemaps"
            components.host = ""
            components.queryItems = [URLQueryItem(name: "q", value: keyword)]
        }
        return components.url
    }

    @MainActor
    @discardableResult
    static func open(_ application: AppMapNavigationApplication, target: AppMapNavigationTarget) -> Bool {
        guard let url = url(for: application, target: target) else { return false }
        return open(url)
    }

    @MainActor
    @discardableResult
    static func open(_ url: URL) -> Bool {
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
