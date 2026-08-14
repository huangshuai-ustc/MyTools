#if MYTOOLS_FEATURE_FOOD_MAP
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FoodMapStore: ObservableObject, ModuleDataCleanupParticipant {
    @Published private(set) var places: [FoodPlace]
    @Published private(set) var knownTags: [String]

    private let attachmentStore: AttachmentStore
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    var cleanupModule: ToolModule { .foodMap }

    init(
        places: [FoodPlace] = [],
        knownTags: [String] = [],
        attachmentStore: AttachmentStore
    ) {
        let normalizedPlaces = places.map(Self.normalizedTags(in:))
        self.places = normalizedPlaces
        self.knownTags = AppTagSupport.merged(knownTags, with: normalizedPlaces.flatMap(\.tags))
        self.attachmentStore = attachmentStore
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(places: [FoodPlace], knownTags: [String]? = nil) {
        let normalizedPlaces = places.map(Self.normalizedTags(in:))
        self.places = normalizedPlaces
        self.knownTags = AppTagSupport.merged(
            knownTags ?? self.knownTags,
            with: normalizedPlaces.flatMap(\.tags)
        )
    }

    func scanRedundantData() -> [RedundantDataFinding] {
        let recordCount = places.filter { $0.status != .tried && $0.visitedAt != nil }.count
        guard recordCount > 0 else { return [] }
        return [RedundantDataFinding(
            ruleID: "unvisited-date",
            module: .foodMap,
            title: "未吃过记录的吃过日期",
            detail: "只有“吃过”状态会使用吃过日期。",
            affectedRecordCount: recordCount,
            affectedFieldCount: recordCount
        )]
    }

    func cleanupRedundantData() {
        for index in places.indices where places[index].status != .tried {
            places[index].visitedAt = nil
        }
    }

    func upsert(_ place: FoodPlace) {
        var stored = place
        stored.foodName = normalizedText(place.foodName)
        stored.shopName = normalizedText(place.shopName)
        if let location = place.administrativeLocation {
            stored.administrativeLocation = ChinaAdministrativeDivisions.location(
                province: normalizedText(location.province),
                city: normalizedText(location.city),
                district: normalizedText(location.district ?? "")
            )
        }
        stored.address = normalizedText(place.address)
        stored.sourceTitle = normalizedText(place.sourceTitle)
        stored.sourceURL = normalizedText(place.sourceURL)
        stored.note = place.note.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.tags = normalizedTags(place.tags)
        knownTags = AppTagSupport.merged(knownTags, with: stored.tags)
        if stored.status != .tried {
            stored.visitedAt = nil
        }
        if stored.coordinate?.isValid != true {
            stored.coordinate = nil
        }
        stored.updatedAt = Date()

        if let index = places.firstIndex(where: { $0.id == stored.id }) {
            let retainedPhotoIDs = Set(stored.photos.map(\.id))
            for photo in places[index].photos where !retainedPhotoIDs.contains(photo.id) {
                attachmentStore.delete(photo)
            }
            stored.createdAt = places[index].createdAt
            places[index] = stored
        } else {
            stored.createdAt = stored.updatedAt
            places.append(stored)
        }
        didMutate()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for place in places where ids.contains(place.id) {
            place.photos.forEach(attachmentStore.delete)
        }
        places.removeAll { ids.contains($0.id) }
        didMutate()
    }

    func importPhoto(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .image) else {
            attachmentStore.delete(attachment)
            throw AttachmentStoreError.invalidFile
        }
        return attachment
    }

    func savePhoto(data: Data, fileName: String, contentType: UTType) throws -> FileAttachment {
        guard contentType.conforms(to: .image) else {
            throw AttachmentStoreError.invalidFile
        }
        return try attachmentStore.save(
            data: data,
            originalFileName: fileName,
            contentType: contentType
        )
    }

    func deleteUncommittedPhoto(_ photo: FileAttachment) {
        attachmentStore.delete(photo)
    }

    func restorePhotoLocation(_ photo: FileAttachment, to original: FileAttachment) throws {
        try attachmentStore.restoreLocation(of: photo, to: original)
    }

    func photoURL(for photo: FileAttachment) -> URL {
        attachmentStore.url(for: photo)
    }

    private func normalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        AppTagSupport.normalize(tags)
    }

    private static func normalizedTags(in place: FoodPlace) -> FoodPlace {
        var result = place
        result.tags = AppTagSupport.normalize(place.tags)
        return result
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
    }
}

#endif
