#if MYTOOLS_FEATURE_FOOD_MAP
import Foundation

struct DianpingImportCandidate: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var rating: Double?
    var reviewCount: Int?
    var pricePerPerson: Int?
    var businessArea: String
    var category: String
    var address: String
    var city: String
    var sourceURL: String
    var shopURL: String
    var imageURL: String

    init(
        name: String,
        rating: Double? = nil,
        reviewCount: Int? = nil,
        pricePerPerson: Int? = nil,
        businessArea: String = "",
        category: String = "",
        address: String = "",
        city: String = "",
        sourceURL: String = "",
        shopURL: String = "",
        imageURL: String = ""
    ) {
        self.name = name
        self.rating = rating
        self.reviewCount = reviewCount
        self.pricePerPerson = pricePerPerson
        self.businessArea = businessArea
        self.category = category
        self.address = address
        self.city = city
        self.sourceURL = sourceURL
        self.shopURL = shopURL
        self.imageURL = imageURL
        self.id = Self.shopIdentifier(in: shopURL)
            ?? Self.shopIdentifier(in: sourceURL)
            ?? [name, address].joined(separator: "|")
    }

    static func shopIdentifier(in sourceURL: String) -> String? {
        let supportedPaths = ["/shopinfo/", "/appshare/shop/", "/shop/"]
        for path in supportedPaths {
            guard let range = sourceURL.range(of: path) else { continue }
            let suffix = sourceURL[range.upperBound...]
            let identifier = suffix.prefix { $0 != "?" && $0 != "&" && $0 != "/" && $0 != "#" }
            if !identifier.isEmpty { return String(identifier) }
        }
        return nil
    }

    func matchesExisting(_ place: FoodPlace) -> Bool {
        let candidateShopURL = shopURL.isEmpty ? sourceURL : shopURL
        let existingShopURL = place.shopURL.isEmpty ? place.sourceURL : place.shopURL
        if let shopID = Self.shopIdentifier(in: candidateShopURL),
           let existingShopID = Self.shopIdentifier(in: existingShopURL) {
            if shopID == existingShopID { return true }
            // Older imports may have captured a stale or incorrect shop URL.
            // Keep matching by the human-readable identity instead of making
            // that historical URL a permanent refresh blocker.
        }

        guard Self.normalizedShopName(place.displayTitle) == Self.normalizedShopName(name) else {
            return false
        }

        let existingCity = place.administrativeLocation?.city ?? ""
        return city.isEmpty
            || existingCity.isEmpty
            || Self.normalizedShopName(city) == Self.normalizedShopName(existingCity)
    }

    private static func normalizedShopName(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DianpingWebPageItem: Codable, Equatable, Sendable {
    var text: String
    var imageURL: String
    var shopURL: String = ""
}

enum DianpingImportParser {
    static func parseSharedText(_ input: String) -> [DianpingImportCandidate] {
        let text = input
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\&", with: "&")
        let lines = meaningfulLines(in: text)
        guard let sourceURL = firstDianpingURL(in: text) else { return [] }

        if isCollectionPageURL(sourceURL) {
            return []
        }

        let bracketName = firstCapture(in: text, pattern: "【([^】]+)】")
        let name = bracketName ?? lines.first(where: { !$0.contains("http") && !$0.hasPrefix("★") }) ?? ""
        guard !name.isEmpty else { return [] }

        let rating = parseRating(in: text)
        let reviewCount = parseReviewCount(in: text)
        let price = firstCapture(in: text, pattern: "[¥￥]\\s*([0-9]+)\\s*/?人")
            .flatMap(Int.init)
        let metadataLine = lines.first {
            !$0.contains(name) && !$0.contains("http") && !$0.contains("/人")
                && !$0.contains("条") && !$0.hasPrefix("★")
        } ?? ""
        let address = lines.last(where: {
            !$0.contains(name) && $0 != metadataLine && !$0.contains("http")
                && !$0.contains("/人") && !$0.contains("条") && !$0.hasPrefix("★")
        }) ?? ""
        let metadata = splitMetadata(metadataLine)

        return [DianpingImportCandidate(
            name: name,
            rating: rating,
            reviewCount: reviewCount,
            pricePerPerson: price,
            businessArea: metadata.area,
            category: metadata.category,
            address: address,
            sourceURL: canonicalURL(sourceURL),
            shopURL: canonicalURL(sourceURL)
        )]
    }

    static func parseWebItems(_ items: [DianpingWebPageItem], sourceURL: String) -> [DianpingImportCandidate] {
        items.compactMap { item in
            let lines = meaningfulLines(in: item.text)
            guard let name = lines.first, !name.contains("登录") else { return nil }
            let rating = parseRating(in: item.text)
            let reviewCount = parseReviewCount(in: item.text)
            let price = firstCapture(in: item.text, pattern: "[¥￥]\\s*([0-9]+)\\s*/?人")
                .flatMap(Int.init)
            let metadata = lines.dropFirst().filter { !isStatisticOrFacilityLine($0) }
            let category = metadata.first ?? ""
            let area = metadata.indices.contains(1) ? metadata[1] : ""
            let city = metadata.indices.contains(2) ? metadata[2] : ""
            return DianpingImportCandidate(
                name: name,
                rating: rating,
                reviewCount: reviewCount,
                pricePerPerson: price,
                businessArea: area,
                category: category,
                address: area,
                city: city,
                sourceURL: canonicalURL(sourceURL),
                shopURL: item.shopURL.isEmpty ? "" : canonicalURL(item.shopURL),
                imageURL: item.imageURL
            )
        }
        .uniqued(by: \.id)
    }

    private static let facilityTerms = [
        "有包厢", "无包厢", "有大桌", "付费停车", "免费停车", "有宝宝椅",
        "有无障碍设施", "免费Wi-Fi", "可预订"
    ]

    private static func isStatisticOrFacilityLine(_ line: String) -> Bool {
        if facilityTerms.contains(line) { return true }
        if line.contains("条") || line.contains("/人") || line.contains("收藏") { return true }
        if line.contains("歇业") || line.contains("暂停营业") { return true }
        if line.range(of: "^[¥￥]", options: .regularExpression) != nil { return true }
        if line.range(of: "^[0-9.]+\\s*(?:km|m)$", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if line.range(of: "[★☆]", options: .regularExpression) != nil { return true }
        if let value = Double(line), (0...5).contains(value) { return true }
        return false
    }

    private static func parseReviewCount(in text: String) -> Int? {
        let pattern = "([0-9]+(?:\\.[0-9]+)?)(万)?\\s*条"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Double(text[valueRange]) else { return nil }
        let hasTenThousandUnit = match.range(at: 2).location != NSNotFound
        return Int((value * (hasTenThousandUnit ? 10_000 : 1)).rounded())
    }

    private static func parseRating(in text: String) -> Double? {
        firstCapture(
            in: text,
            pattern: "(?:[★☆]\\s*)*(?<![0-9])([0-5](?:\\.[0-9])?)(?![0-9])"
        ).flatMap(Double.init)
    }

    private static func meaningfulLines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "打开App" && $0 != "发现好去处" }
    }

    private static func firstDianpingURL(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "https://[^\\s\\)\\]]+") else {
            return nil
        }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            guard let components = URLComponents(string: value),
                  let host = components.host?.lowercased(),
                  host == "dianping.com" || host.hasSuffix(".dianping.com") else { continue }
            return value
        }
        return nil
    }

    static func isCollectionPageURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.path.localizedCaseInsensitiveContains("collectionlist")
    }

    private static func canonicalURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        if DianpingImportCandidate.shopIdentifier(in: value) != nil {
            components.query = nil
            components.fragment = nil
        }
        return components.url?.absoluteString ?? value
    }

    private static func splitMetadata(_ line: String) -> (area: String, category: String) {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let category = parts.last else { return ("", "") }
        return (parts.dropLast().joined(separator: " "), category)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

protocol FoodPlaceSourceAdapter: Sendable {
    var sourceTitle: String { get }
    func refreshURL(for place: FoodPlace) -> String?
    func fallbackRefreshURL(for place: FoodPlace) -> String?
    func candidates(from items: [DianpingWebPageItem], pageURL: String) -> [DianpingImportCandidate]
}

extension FoodPlaceSourceAdapter {
    func fallbackRefreshURL(for place: FoodPlace) -> String? { nil }
}

struct DianpingFoodPlaceSourceAdapter: FoodPlaceSourceAdapter {
    let sourceTitle = "大众点评"

    func refreshURL(for place: FoodPlace) -> String? {
        // Refresh the information source first. Collection imports share this URL, so the
        // batch refresher fetches each collection once and matches all of its shops locally.
        let sourceURL = place.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSupportedURL(sourceURL) { return sourceURL }
        let shopURL = place.shopURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSupportedURL(shopURL) ? shopURL : nil
    }

    func fallbackRefreshURL(for place: FoodPlace) -> String? {
        let shopURL = place.shopURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSupportedURL(shopURL), shopURL != refreshURL(for: place) else { return nil }
        return shopURL
    }

    private func isSupportedURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.lowercased().hasSuffix("dianping.com") == true else { return false }
        return true
    }

    func candidates(
        from items: [DianpingWebPageItem],
        pageURL: String
    ) -> [DianpingImportCandidate] {
        DianpingImportParser.parseWebItems(items, sourceURL: pageURL)
    }
}

enum FoodPlaceSourceAdapters {
    /// New sources such as Meituan only need to add another adapter here. The batch-refresh
    /// flow and local merge policy remain unchanged.
    static let all: [any FoodPlaceSourceAdapter] = [DianpingFoodPlaceSourceAdapter()]
}

enum FoodPlaceSourceRefreshMerge {
    static func merging(_ candidate: DianpingImportCandidate, into place: FoodPlace) -> FoodPlace {
        var result = place
        if !candidate.name.isEmpty { result.shopName = candidate.name }
        if !candidate.shopURL.isEmpty { result.shopURL = candidate.shopURL }
        if result.sourceTitle.isEmpty { result.sourceTitle = "大众点评" }
        if result.sourceURL.isEmpty { result.sourceURL = candidate.sourceURL }
        if let rating = candidate.rating { result.rating = rating }
        if let reviewCount = candidate.reviewCount { result.reviewCount = reviewCount }
        if let pricePerPerson = candidate.pricePerPerson {
            result.averagePrice = Decimal(pricePerPerson)
            result.averagePriceCurrency = .cny
        }
        if !candidate.category.isEmpty { result.specialty = candidate.category }

        // Collection pages expose a business area rather than a full street address. Never
        // replace a richer address or a user-selected map coordinate with that shorter value.
        if result.address.isEmpty, !candidate.address.isEmpty {
            result.address = candidate.address
        }
        if result.administrativeLocation == nil {
            result.administrativeLocation = ChinaAdministrativeDivisions.infer(
                from: [candidate.city, candidate.address].joined(separator: " ")
            )
        }
        return result
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

#endif
