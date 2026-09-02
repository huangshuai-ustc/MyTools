#if MYTOOLS_FEATURE_FOOD_MAP
import Foundation

enum FoodPlaceStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case tried
    case wantToTry

    var id: Self { self }

    var title: String {
        switch self {
        case .tried: return "吃过"
        case .wantToTry: return "想吃"
        }
    }

    var systemImage: String {
        switch self {
        case .tried: return "checkmark.circle.fill"
        case .wantToTry: return "heart.fill"
        }
    }
}

struct FoodCoordinate: Codable, Equatable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

struct FoodPlace: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var shopName = ""
    var recommendedFood = ""
    var administrativeLocation: ChinaAdministrativeLocation?
    var address = ""
    var coordinate: FoodCoordinate?
    var status: FoodPlaceStatus = .wantToTry
    var visitedAt: Date?
    var photos: [FileAttachment] = []
    var sourceTitle = ""
    var sourceURL = ""
    var shopURL = ""
    var rating: Double?
    var reviewCount: Int?
    var averagePrice: Decimal?
    var averagePriceCurrency: CurrencyCode = .cny
    var specialty = ""
    var tags: [String] = []
    var note = ""
    var createdAt = Date()
    var updatedAt = Date()

    init(
        id: UUID = UUID(),
        shopName: String = "",
        recommendedFood: String = "",
        administrativeLocation: ChinaAdministrativeLocation? = nil,
        address: String = "",
        coordinate: FoodCoordinate? = nil,
        status: FoodPlaceStatus = .wantToTry,
        visitedAt: Date? = nil,
        photos: [FileAttachment] = [],
        sourceTitle: String = "",
        sourceURL: String = "",
        shopURL: String = "",
        rating: Double? = nil,
        reviewCount: Int? = nil,
        averagePrice: Decimal? = nil,
        averagePriceCurrency: CurrencyCode = .cny,
        specialty: String = "",
        tags: [String] = [],
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.shopName = shopName
        self.recommendedFood = recommendedFood
        self.administrativeLocation = administrativeLocation
        self.address = address
        self.coordinate = coordinate
        self.status = status
        self.visitedAt = visitedAt
        self.photos = photos
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.shopURL = shopURL
        self.rating = rating
        self.reviewCount = reviewCount
        self.averagePrice = averagePrice
        self.averagePriceCurrency = averagePriceCurrency
        self.specialty = specialty
        self.tags = tags
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        let shop = shopName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shop.isEmpty { return shop }
        let food = recommendedFood.trimmingCharacters(in: .whitespacesAndNewlines)
        return food.isEmpty ? "未命名店铺" : food
    }

    var locationSummary: String {
        let values = [administrativeArea, address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "未记录地址" : values.joined(separator: " · ")
    }

    var administrativeArea: String {
        administrativeLocation?.displayName ?? ""
    }

    func matches(_ searchTerm: String) -> Bool {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return shopName.localizedCaseInsensitiveContains(term)
            || recommendedFood.localizedCaseInsensitiveContains(term)
            || administrativeLocation?.province.localizedCaseInsensitiveContains(term) == true
            || administrativeLocation?.city.localizedCaseInsensitiveContains(term) == true
            || administrativeLocation?.district?.localizedCaseInsensitiveContains(term) == true
            || address.localizedCaseInsensitiveContains(term)
            || sourceTitle.localizedCaseInsensitiveContains(term)
            || specialty.localizedCaseInsensitiveContains(term)
            || note.localizedCaseInsensitiveContains(term)
            || tags.contains { $0.localizedCaseInsensitiveContains(term) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case foodName
        case shopName
        case recommendedFood
        case administrativeLocation
        case address
        case coordinate
        case status
        case visitedAt
        case photos
        case sourceTitle
        case sourceURL
        case shopURL
        case rating
        case reviewCount
        case averagePrice
        case averagePriceCurrency
        case specialty
        case tags
        case note
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        let decodedShopName = try container.decodeIfPresent(String.self, forKey: .shopName) ?? ""
        if container.contains(.recommendedFood) {
            shopName = decodedShopName
            recommendedFood = try container.decodeIfPresent(String.self, forKey: .recommendedFood) ?? ""
        } else {
            let legacyFoodName = try container.decodeIfPresent(String.self, forKey: .foodName) ?? ""
            if decodedShopName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shopName = legacyFoodName
                recommendedFood = ""
            } else {
                shopName = decodedShopName
                recommendedFood = legacyFoodName == decodedShopName ? "" : legacyFoodName
            }
        }

        administrativeLocation = try container.decodeIfPresent(
            ChinaAdministrativeLocation.self,
            forKey: .administrativeLocation
        )
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        coordinate = try container.decodeIfPresent(FoodCoordinate.self, forKey: .coordinate)
        status = try container.decodeIfPresent(FoodPlaceStatus.self, forKey: .status) ?? .wantToTry
        visitedAt = try container.decodeIfPresent(Date.self, forKey: .visitedAt)
        photos = try container.decodeIfPresent([FileAttachment].self, forKey: .photos) ?? []
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle) ?? ""
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        if container.contains(.shopURL) {
            shopURL = try container.decodeIfPresent(String.self, forKey: .shopURL) ?? ""
        } else {
            shopURL = Self.legacyShopURL(from: sourceURL)
        }
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount)
        averagePrice = try container.decodeIfPresent(Decimal.self, forKey: .averagePrice)
        averagePriceCurrency = try container.decodeIfPresent(
            CurrencyCode.self,
            forKey: .averagePriceCurrency
        ) ?? .cny
        specialty = try container.decodeIfPresent(String.self, forKey: .specialty) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(shopName, forKey: .shopName)
        try container.encode(recommendedFood, forKey: .recommendedFood)
        try container.encodeIfPresent(administrativeLocation, forKey: .administrativeLocation)
        try container.encode(address, forKey: .address)
        try container.encodeIfPresent(coordinate, forKey: .coordinate)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(visitedAt, forKey: .visitedAt)
        try container.encode(photos, forKey: .photos)
        try container.encode(sourceTitle, forKey: .sourceTitle)
        try container.encode(sourceURL, forKey: .sourceURL)
        try container.encode(shopURL, forKey: .shopURL)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(reviewCount, forKey: .reviewCount)
        try container.encodeIfPresent(averagePrice, forKey: .averagePrice)
        try container.encode(averagePriceCurrency, forKey: .averagePriceCurrency)
        try container.encode(specialty, forKey: .specialty)
        try container.encode(tags, forKey: .tags)
        try container.encode(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func legacyShopURL(from sourceURL: String) -> String {
        guard var components = URLComponents(string: sourceURL),
              components.host?.lowercased().hasSuffix("dianping.com") == true,
              components.path.contains("/shopinfo/") else { return "" }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? sourceURL
    }
}

#endif
