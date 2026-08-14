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
    var foodName = ""
    var shopName = ""
    var administrativeLocation: ChinaAdministrativeLocation?
    var address = ""
    var coordinate: FoodCoordinate?
    var status: FoodPlaceStatus = .wantToTry
    var visitedAt: Date?
    var photos: [FileAttachment] = []
    var sourceTitle = ""
    var sourceURL = ""
    var tags: [String] = []
    var note = ""
    var createdAt = Date()
    var updatedAt = Date()

    init(
        id: UUID = UUID(),
        foodName: String = "",
        shopName: String = "",
        administrativeLocation: ChinaAdministrativeLocation? = nil,
        address: String = "",
        coordinate: FoodCoordinate? = nil,
        status: FoodPlaceStatus = .wantToTry,
        visitedAt: Date? = nil,
        photos: [FileAttachment] = [],
        sourceTitle: String = "",
        sourceURL: String = "",
        tags: [String] = [],
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.foodName = foodName
        self.shopName = shopName
        self.administrativeLocation = administrativeLocation
        self.address = address
        self.coordinate = coordinate
        self.status = status
        self.visitedAt = visitedAt
        self.photos = photos
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.tags = tags
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        let food = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !food.isEmpty { return food }
        let shop = shopName.trimmingCharacters(in: .whitespacesAndNewlines)
        return shop.isEmpty ? "未命名美食" : shop
    }

    var locationSummary: String {
        let values = [shopName, administrativeArea, address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "未记录地点" : values.joined(separator: " · ")
    }

    var administrativeArea: String {
        administrativeLocation?.displayName ?? ""
    }

    func matches(_ searchTerm: String) -> Bool {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return foodName.localizedCaseInsensitiveContains(term)
            || shopName.localizedCaseInsensitiveContains(term)
            || administrativeLocation?.province.localizedCaseInsensitiveContains(term) == true
            || administrativeLocation?.city.localizedCaseInsensitiveContains(term) == true
            || administrativeLocation?.district?.localizedCaseInsensitiveContains(term) == true
            || address.localizedCaseInsensitiveContains(term)
            || sourceTitle.localizedCaseInsensitiveContains(term)
            || note.localizedCaseInsensitiveContains(term)
            || tags.contains { $0.localizedCaseInsensitiveContains(term) }
    }
}

#endif
