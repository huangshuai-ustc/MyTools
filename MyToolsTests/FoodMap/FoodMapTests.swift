import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MyTools

@MainActor
struct FoodMapTests {
    @Test func storeNormalizesValuesAndOwnsPhotoLifecycle() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("FoodMapTests-\(UUID().uuidString)", isDirectory: true)
        let attachmentStore = AttachmentStore(
            fileManager: fileManager,
            directoryURL: directoryURL
        )
        defer { try? fileManager.removeItem(at: directoryURL) }

        let retainedPhoto = try attachmentStore.save(
            data: Data("retained".utf8),
            originalFileName: "retained.jpg",
            contentType: .jpeg
        )
        let removedPhoto = try attachmentStore.save(
            data: Data("removed".utf8),
            originalFileName: "removed.jpg",
            contentType: .jpeg
        )
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let original = FoodPlace(
            foodName: "Original",
            status: .tried,
            visitedAt: Date(),
            photos: [retainedPhoto, removedPhoto],
            createdAt: createdAt
        )
        let store = FoodMapStore(places: [original], attachmentStore: attachmentStore)
        var edited = original
        edited.foodName = "  小笼包  "
        edited.shopName = "  示例店  "
        edited.administrativeLocation = ChinaAdministrativeLocation(
            province: " 广东省 ",
            city: " 深圳市 "
        )
        edited.address = "  示例路 1 号  "
        edited.sourceTitle = "  朋友推荐  "
        edited.sourceURL = "  https://example.com/food  "
        edited.note = "  下次再来  "
        edited.tags = [" 沪菜 ", "沪菜", " 朋友推荐 ", "  "]
        edited.status = .wantToTry
        edited.coordinate = FoodCoordinate(latitude: 100, longitude: 20)
        edited.photos = [retainedPhoto]

        store.upsert(edited)

        let stored = try #require(store.places.first)
        #expect(stored.foodName == "小笼包")
        #expect(stored.shopName == "示例店")
        #expect(stored.administrativeLocation == ChinaAdministrativeLocation(
            province: "广东省",
            city: "深圳市"
        ))
        #expect(stored.administrativeArea == "广东省 深圳市")
        #expect(stored.address == "示例路 1 号")
        #expect(stored.sourceTitle == "朋友推荐")
        #expect(stored.sourceURL == "https://example.com/food")
        #expect(stored.note == "下次再来")
        #expect(stored.tags == ["沪菜", "朋友推荐"])
        #expect(stored.visitedAt == nil)
        #expect(stored.coordinate == nil)
        #expect(stored.createdAt == createdAt)
        #expect(fileManager.fileExists(atPath: attachmentStore.url(for: retainedPhoto).path))
        #expect(!fileManager.fileExists(atPath: attachmentStore.url(for: removedPhoto).path))

        store.delete(ids: [original.id])

        #expect(store.places.isEmpty)
        #expect(!fileManager.fileExists(atPath: attachmentStore.url(for: retainedPhoto).path))
    }

    @Test func cleanupRemovesVisitedDateOnlyFromUnvisitedStatuses() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let store = FoodMapStore(
            places: [
                FoodPlace(foodName: "想吃", status: .wantToTry, visitedAt: date),
                FoodPlace(foodName: "吃过", status: .tried, visitedAt: date)
            ],
            attachmentStore: AttachmentStore()
        )

        let findings = store.scanRedundantData()
        store.cleanupRedundantData()

        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "unvisited-date")
        #expect(findings.first?.affectedFieldCount == 1)
        #expect(store.places[0].visitedAt == nil)
        #expect(store.places[1].visitedAt == date)
    }

    @Test func vaultWithoutFoodPlacesDecodesAsEmpty() throws {
        let vault = try JSONDecoder().decode(VaultData.self, from: Data("{}".utf8))

        #expect(vault.foodPlaces.isEmpty)
    }

    @Test func provinceCityCatalogIsCompleteAndInfersChineseAddresses() throws {
        let provinces = ChinaAdministrativeDivisions.provinces

        #expect(provinces.count == 34)
        #expect(Set(provinces.map(\.name)).count == provinces.count)
        #expect(provinces.allSatisfy { !$0.cities.isEmpty })
        #expect(ChinaAdministrativeDivisions.infer(
            from: "上海市徐汇区襄阳南路"
        ) == ChinaAdministrativeLocation(province: "上海市", city: "上海市"))
        #expect(ChinaAdministrativeDivisions.infer(
            from: "广东省深圳市南山区"
        ) == ChinaAdministrativeLocation(province: "广东省", city: "深圳市"))
        #expect(ChinaAdministrativeDivisions.infer(
            from: "上海徐汇"
        ) == ChinaAdministrativeLocation(province: "上海市", city: "上海市"))
        #expect(ChinaAdministrativeDivisions.infer(
            from: "深圳南山"
        ) == ChinaAdministrativeLocation(province: "广东省", city: "深圳市"))
        #expect(ChinaAdministrativeDivisions.infer(from: "Tokyo, Japan") == nil)
    }

    @Test func backupRestoresFoodMapPhotosOnlyWhenModuleIsEnabled() async throws {
        let attachmentStore = AttachmentStore()
        let photoData = Data("food-photo".utf8)
        let photo = try attachmentStore.save(
            data: photoData,
            originalFileName: "food.jpg",
            contentType: .jpeg
        )
        defer { attachmentStore.delete(photo) }

        let place = FoodPlace(
            foodName: "生煎",
            coordinate: FoodCoordinate(latitude: 31.2304, longitude: 121.4737),
            photos: [photo]
        )
        let processor = AppStoreBackupProcessor()
        let backup = try await processor.makeBackup(
            vault: VaultData(foodPlaces: [place]),
            secrets: [],
            includedModules: [.foodMap],
            password: "test-password"
        )
        attachmentStore.delete(photo)

        let restored = try await processor.restorePayload(
            from: backup,
            password: "test-password",
            enabledModules: [.foodMap]
        )
        let restoredPlace = try #require(restored.vault.foodPlaces.first)
        let restoredPhoto = try #require(restoredPlace.photos.first)
        #expect(restored.includedModules == [.foodMap])
        #expect(try attachmentStore.data(for: restoredPhoto) == photoData)
        #expect(restoredPhoto.backupData == nil)

        let excluded = try await processor.restorePayload(
            from: backup,
            password: "test-password",
            enabledModules: [.personalFinance]
        )
        #expect(excluded.includedModules.isEmpty)
        #expect(excluded.vault.foodPlaces.isEmpty)
    }

    @Test func cloudSnapshotKeepsFoodMapEntityAndAttachmentInModuleBoundary() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("FoodMapCloudTests-\(UUID().uuidString)", isDirectory: true)
        let attachmentStore = AttachmentStore(
            fileManager: fileManager,
            directoryURL: directoryURL
        )
        defer { try? fileManager.removeItem(at: directoryURL) }
        let photo = try attachmentStore.save(
            data: Data("cloud-photo".utf8),
            originalFileName: "cloud.jpg",
            contentType: .jpeg
        )
        var photoWithBackupData = photo
        photoWithBackupData.backupData = Data([1, 2, 3])
        let place = FoodPlace(foodName: "云端美食", photos: [photoWithBackupData])

        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(foodPlaces: [place]),
            secrets: [],
            attachmentStore: attachmentStore,
            enabledModules: [.foodMap]
        )
        let placeItem = try #require(snapshot.items.first { $0.kind == .foodPlace })
        let attachmentItem = try #require(snapshot.items.first { $0.kind == .attachment })
        let syncedPlace = try CloudSyncCoding.decoder().decode(FoodPlace.self, from: placeItem.payload)
        let syncedAttachment = try CloudSyncCoding.decoder().decode(
            FileAttachment.self,
            from: attachmentItem.payload
        )

        #expect(snapshot.participatingModules == [.foodMap])
        #expect(placeItem.module == .foodMap)
        #expect(attachmentItem.module == .foodMap)
        #expect(attachmentItem.assetURL == attachmentStore.url(for: photo))
        #expect(syncedPlace.photos.first?.backupData == nil)
        #expect(syncedAttachment.backupData == nil)

        let excluded = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(foodPlaces: [place]),
            secrets: [],
            attachmentStore: attachmentStore,
            enabledModules: [.personalFinance]
        )
        #expect(excluded.items.allSatisfy { $0.kind != .foodPlace && $0.kind != .attachment })
    }

    @Test func cloudChangesForDisabledFoodMapAreIgnored() throws {
        let local = FoodPlace(foodName: "本地")
        var remote = local
        remote.foodName = "远端"
        let payload = try CloudSyncCoding.encoder().encode(remote)

        let result = try CloudSyncMerger.apply(
            [.upsert(kind: .foodPlace, id: remote.id, payload: payload)],
            to: VaultData(foodPlaces: [local]),
            secrets: [],
            enabledModules: [.personalFinance]
        )

        #expect(result.vault.foodPlaces == [local])
    }

    @Test func navigationURLsContainDestinationAndRejectMissingCoordinates() throws {
        let place = FoodPlace(
            foodName: "烤鸭",
            shopName: "示例烤鸭店",
            coordinate: FoodCoordinate(latitude: 39.9042, longitude: 116.4074)
        )

        let appleURL = try #require(
            FoodNavigationService.url(for: .appleMaps, place: place)
        )
        let appleComponents = try #require(
            URLComponents(url: appleURL, resolvingAgainstBaseURL: false)
        )
        let appleQuery = Dictionary(
            uniqueKeysWithValues: (appleComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(appleComponents.scheme == "maps")
        #expect(appleQuery["daddr"] == "39.9042,116.4074")
        #expect(appleQuery["q"] == "示例烤鸭店")

        let amapURL = try #require(
            FoodNavigationService.url(for: .amap, place: place)
        )
        let amapComponents = try #require(
            URLComponents(url: amapURL, resolvingAgainstBaseURL: false)
        )
        let amapQuery = Dictionary(
            uniqueKeysWithValues: (amapComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(amapComponents.scheme == "iosamap")
        #expect(amapQuery["lat"] == "39.9042")
        #expect(amapQuery["lon"] == "116.4074")
        #expect(amapQuery["poiname"] == "示例烤鸭店")

        #expect(FoodNavigationService.url(for: .appleMaps, place: FoodPlace()) == nil)
    }
}
