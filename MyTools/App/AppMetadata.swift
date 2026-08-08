import Foundation

enum AppMetadata {
    static let appName = "方寸"
    static let fallbackBundleIdentifier = "com.fjwyz.PersonalToolBox"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    static var stockRefreshTaskIdentifier: String {
        "\(bundleIdentifier).stock-refresh"
    }

    static var backupTypeIdentifier: String {
        "\(bundleIdentifier).backup"
    }

    static var iCloudContainerIdentifier: String {
        "iCloud.\(bundleIdentifier)"
    }

    static var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未标记版本"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "未标记构建"
        return "\(version) (\(build))"
    }
}

enum AppStorageKey {
    static let appearanceMode = "app-appearance-mode-v1"
    static let fontSize = "app-font-size-v2"
}
