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

    static var sportsLotteryRefreshTaskIdentifier: String {
        "\(bundleIdentifier).sports-lottery-refresh"
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
    static let accountSortOrder = "account-sort-order-v2"
    static let stockSortCriterion = "stock-sort-criterion-v2"
    static let stockSortDirection = "stock-sort-direction-v2"
    static let secretSortOrder = "secret-sort-order-v1"
    static let sportsLotteryLeagues = "sports-lottery-leagues-v2"
    static let sportsLotteryMatchOrder = "sports-lottery-match-order-v1"
}
