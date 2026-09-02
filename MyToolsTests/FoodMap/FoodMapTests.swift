import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MyTools

@MainActor
struct FoodMapTests {
    @Test func manuallyCreatedFoodPlaceHasNoDefaultSource() {
        let place = FoodPlace()

        #expect(place.sourceTitle.isEmpty)
        #expect(place.sourceURL.isEmpty)
        #expect(place.shopURL.isEmpty)
    }

    @Test func compactMetricsUseOnlyCurrencySymbolAndValue() {
        #expect(FoodPlaceValueFormatter.compactPrice(92, currency: .cny) == "¥92")
        #expect(FoodPlaceValueFormatter.compactPrice(25.5, currency: .usd) == "$25.5")
    }

    @Test func dianpingSingleShopShareTextParsesImportFields() throws {
        let text = """
        【花潮料理艺食馆(福州泰禾广场店)】
        ★★★★☆ 4.6
        ¥410/人
        东二环泰禾广场 日式自助
        连江北路泰禾广场西区22号楼6楼607
        https://m.dianping.com/shopinfo/k9uGtL4B82xcPDxk?msource=Appshare2021\\&utm_source=shop_share
        """

        let candidate = try #require(DianpingImportParser.parseSharedText(text).first)

        #expect(candidate.name == "花潮料理艺食馆(福州泰禾广场店)")
        #expect(candidate.rating == 4.6)
        #expect(candidate.pricePerPerson == 410)
        #expect(candidate.businessArea == "东二环泰禾广场")
        #expect(candidate.category == "日式自助")
        #expect(candidate.address == "连江北路泰禾广场西区22号楼6楼607")
        #expect(candidate.sourceURL == "https://m.dianping.com/shopinfo/k9uGtL4B82xcPDxk")
        #expect(candidate.shopURL == "https://m.dianping.com/shopinfo/k9uGtL4B82xcPDxk")
        #expect(candidate.id == "k9uGtL4B82xcPDxk")
    }

    @Test func dianpingCollectionPageItemsParseAndDeduplicateShops() throws {
        let item = DianpingWebPageItem(
            text: """
            很久以前羊肉串(西北旺万象汇店)
            4.9
            1201条
            ¥92/人
            烤串
            西北旺
            北京
            有大桌
            """,
            imageURL: "https://img.meituan.net/example.jpg",
            shopURL: "https://m.dianping.com/shopinfo/example-shop?utm_source=collection"
        )

        let candidates = DianpingImportParser.parseWebItems(
            [item, item],
            sourceURL: "https://h5.dianping.com/app/commonplatform-collection-static/collectionlist.html?shareid=example"
        )
        let candidate = try #require(candidates.first)

        #expect(candidates.count == 1)
        #expect(candidate.name == "很久以前羊肉串(西北旺万象汇店)")
        #expect(candidate.rating == 4.9)
        #expect(candidate.reviewCount == 1201)
        #expect(candidate.pricePerPerson == 92)
        #expect(candidate.category == "烤串")
        #expect(candidate.businessArea == "西北旺")
        #expect(candidate.address == "西北旺")
        #expect(candidate.city == "北京")
        #expect(candidate.imageURL == "https://img.meituan.net/example.jpg")
        #expect(candidate.sourceURL == "https://h5.dianping.com/app/commonplatform-collection-static/collectionlist.html?shareid=example")
        #expect(candidate.shopURL == "https://m.dianping.com/shopinfo/example-shop")
    }

    @Test func dianpingCollectionCandidatesSharingOneURLAreNotTreatedAsTheSameShop() {
        let collectionURL = "https://h5.dianping.com/app/commonplatform-collection-static/collectionlist.html?shareid=example"
        let first = DianpingImportCandidate(
            name: "第一家店",
            city: "福州",
            sourceURL: collectionURL
        )
        let second = DianpingImportCandidate(
            name: "第二家店",
            city: "南京",
            sourceURL: collectionURL
        )
        let storedFirst = FoodPlace(
            shopName: first.name,
            sourceTitle: "大众点评",
            sourceURL: collectionURL
        )

        #expect(first.matchesExisting(storedFirst))
        #expect(!second.matchesExisting(storedFirst))
    }

    @Test func dianpingAppShareShopURLKeepsStableShopIdentifier() throws {
        let text = """
        【示例餐厅】
        https://m.dianping.com/appshare/shop/k9uGtL4B82xcPDxk?utm_source=sharecollectionlist
        """

        let candidate = try #require(DianpingImportParser.parseSharedText(text).first)

        #expect(candidate.id == "k9uGtL4B82xcPDxk")
        #expect(candidate.shopURL == "https://m.dianping.com/appshare/shop/k9uGtL4B82xcPDxk")
    }

    @Test func sourceRefreshAdapterPrefersInformationSourceAndFallsBackToShopURL() {
        let adapter = DianpingFoodPlaceSourceAdapter()
        let collectionURL = "https://h5.dianping.com/app/commonplatform-collection-static/collectionlist.html?schemaid=example"
        let shopURL = "https://m.dianping.com/appshare/shop/example"
        let collectionPlace = FoodPlace(
            shopName: "收藏店铺",
            sourceURL: collectionURL,
            shopURL: shopURL
        )

        #expect(adapter.refreshURL(for: collectionPlace) == collectionURL)
        #expect(adapter.fallbackRefreshURL(for: collectionPlace) == shopURL)
        let singleShopSourceURL = "https://m.dianping.com/shopinfo/example"
        let singleShopPlace = FoodPlace(
            shopName: "单店分享",
            sourceURL: singleShopSourceURL,
            shopURL: ""
        )
        #expect(adapter.refreshURL(for: singleShopPlace) == singleShopSourceURL)
        #expect(adapter.fallbackRefreshURL(for: singleShopPlace) == nil)
        #expect(adapter.refreshURL(for: FoodPlace(
            shopName: "手工记录",
            shopURL: "https://m.dianping.com/appshare/shop/example"
        )) == "https://m.dianping.com/appshare/shop/example")
    }

    @Test func sourceRefreshUpdatesRemoteFieldsAndPreservesPersonalFields() {
        let visitedAt = Date(timeIntervalSince1970: 10_000)
        let place = FoodPlace(
            shopName: "旧店名",
            recommendedFood: "用户推荐菜",
            address: "完整街道地址 88 号",
            coordinate: FoodCoordinate(latitude: 39.9, longitude: 116.4),
            status: .tried,
            visitedAt: visitedAt,
            sourceTitle: "大众点评",
            sourceURL: "https://h5.dianping.com/app/commonplatform-collection-static/collectionlist.html?schemaid=example",
            shopURL: "https://m.dianping.com/appshare/shop/example",
            rating: 4.0,
            reviewCount: 100,
            averagePrice: 50,
            specialty: "旧分类",
            tags: ["约会"],
            note: "保留备注"
        )
        let candidate = DianpingImportCandidate(
            name: "新店名",
            rating: 4.8,
            reviewCount: 1234,
            pricePerPerson: 92,
            businessArea: "商圈",
            category: "新分类",
            address: "商圈",
            city: "北京",
            sourceURL: place.sourceURL,
            shopURL: place.shopURL
        )

        let refreshed = FoodPlaceSourceRefreshMerge.merging(candidate, into: place)

        #expect(refreshed.shopName == "新店名")
        #expect(refreshed.rating == 4.8)
        #expect(refreshed.reviewCount == 1234)
        #expect(refreshed.averagePrice == 92)
        #expect(refreshed.specialty == "新分类")
        #expect(refreshed.address == "完整街道地址 88 号")
        #expect(refreshed.coordinate == place.coordinate)
        #expect(refreshed.recommendedFood == "用户推荐菜")
        #expect(refreshed.status == .tried)
        #expect(refreshed.visitedAt == visitedAt)
        #expect(refreshed.tags == ["约会"])
        #expect(refreshed.note == "保留备注")
    }

    @Test func dianpingSingleShopCandidatesDeduplicateByShopIdentifier() {
        let candidate = DianpingImportCandidate(
            name: "新名称",
            sourceURL: "https://h5.dianping.com/share/example",
            shopURL: "https://m.dianping.com/shopinfo/shop-123?utm_source=share"
        )
        let existing = FoodPlace(
            shopName: "旧名称",
            sourceTitle: "大众点评",
            sourceURL: "https://h5.dianping.com/share/older",
            shopURL: "https://m.dianping.com/shopinfo/shop-123"
        )

        #expect(candidate.matchesExisting(existing))
    }

    @Test func sourceRefreshMatchesShopAcrossFullWidthPunctuationAndRicherLocalAddress() {
        let candidate = DianpingImportCandidate(
            name: "很久以前羊肉串(西北旺万象汇店)",
            address: "西北旺",
            city: "北京",
            sourceURL: "https://h5.dianping.com/collection/example",
            shopURL: "https://m.dianping.com/appshare/shop/k3zrztytMiDhzPo0"
        )
        let existing = FoodPlace(
            shopName: "很久以前羊肉串（西北旺万象汇店）",
            administrativeLocation: ChinaAdministrativeLocation(
                province: "北京市",
                city: "北京",
                district: "海淀区"
            ),
            address: "永丰路西北旺万象汇六层",
            sourceTitle: "大众点评",
            sourceURL: "https://h5.dianping.com/collection/example"
        )

        #expect(candidate.matchesExisting(existing))
        let refreshed = FoodPlaceSourceRefreshMerge.merging(candidate, into: existing)
        #expect(refreshed.shopURL == "https://m.dianping.com/appshare/shop/k3zrztytMiDhzPo0")
    }

    @Test func sourceRefreshFallsBackToNameWhenLegacyShopIdentifierIsWrong() {
        let candidate = DianpingImportCandidate(
            name: "很久以前羊肉串(西北旺万象汇店)",
            city: "北京",
            sourceURL: "https://h5.dianping.com/collection/example",
            shopURL: "https://m.dianping.com/appshare/shop/k3zrztytMiDhzPo0"
        )
        let existing = FoodPlace(
            shopName: "很久以前羊肉串（西北旺万象汇店）",
            administrativeLocation: ChinaAdministrativeLocation(province: "北京市", city: "北京"),
            sourceTitle: "大众点评",
            sourceURL: "https://h5.dianping.com/collection/example",
            shopURL: "https://m.dianping.com/shopinfo/legacy-wrong-id"
        )

        #expect(candidate.matchesExisting(existing))
    }

    @Test func structuredCollectionStatisticsDoNotShiftLocationFields() throws {
        let item = DianpingWebPageItem(
            text: "很久以前羊肉串(西北旺万象汇店)\n4.9\n1202条\n¥92/人\n烤串\n西北旺\n北京",
            imageURL: "",
            shopURL: "https://m.dianping.com/appshare/shop/k3zrztytMiDhzPo0"
        )

        let candidate = try #require(DianpingImportParser.parseWebItems(
            [item],
            sourceURL: "https://h5.dianping.com/collection/example"
        ).first)
        #expect(candidate.rating == 4.9)
        #expect(candidate.reviewCount == 1202)
        #expect(candidate.pricePerPerson == 92)
        #expect(candidate.category == "烤串")
        #expect(candidate.businessArea == "西北旺")
        #expect(candidate.city == "北京")
    }

    @Test func foodStatusesOnlyExposeTriedAndWantToTry() {
        #expect(FoodPlaceStatus.allCases == [.tried, .wantToTry])
    }

    @Test func legacyFoodNamesMigrateToShopAndRecommendedFood() throws {
        let namedShop = try JSONDecoder().decode(
            FoodPlace.self,
            from: Data("{\"foodName\":\"烤鸭\",\"shopName\":\"示例烤鸭店\"}".utf8)
        )
        #expect(namedShop.shopName == "示例烤鸭店")
        #expect(namedShop.recommendedFood == "烤鸭")

        let legacyTitleOnly = try JSONDecoder().decode(
            FoodPlace.self,
            from: Data("{\"foodName\":\"只有旧标题\"}".utf8)
        )
        #expect(legacyTitleOnly.shopName == "只有旧标题")
        #expect(legacyTitleOnly.recommendedFood.isEmpty)
    }

    @Test func redesignedFoodFieldsRoundTrip() throws {
        let place = FoodPlace(
            shopName: "很久以前羊肉串（西北旺万象汇店）",
            recommendedFood: "羊肉串",
            address: "西北旺",
            sourceTitle: "大众点评",
            sourceURL: "https://h5.dianping.com/collection/example",
            shopURL: "https://m.dianping.com/shopinfo/example",
            rating: 4.9,
            reviewCount: 1201,
            averagePrice: 92,
            averagePriceCurrency: .cny,
            specialty: "烤串"
        )

        let decoded = try JSONDecoder().decode(
            FoodPlace.self,
            from: JSONEncoder().encode(place)
        )

        #expect(decoded == place)
        #expect(decoded.displayTitle == place.shopName)
    }

    @Test func legacyDianpingSourceURLMigratesToIndependentShopURL() throws {
        let place = try JSONDecoder().decode(
            FoodPlace.self,
            from: Data("{\"shopName\":\"旧记录\",\"sourceTitle\":\"大众点评\",\"sourceURL\":\"https://m.dianping.com/shopinfo/legacy-shop?utm_source=old\"}".utf8)
        )

        #expect(place.sourceURL.contains("utm_source=old"))
        #expect(place.shopURL == "https://m.dianping.com/shopinfo/legacy-shop")
    }

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
            shopName: "Original",
            status: .tried,
            visitedAt: Date(),
            photos: [retainedPhoto, removedPhoto],
            createdAt: createdAt
        )
        let store = FoodMapStore(places: [original], attachmentStore: attachmentStore)
        var edited = original
        edited.shopName = "  示例店  "
        edited.recommendedFood = "  小笼包  "
        edited.administrativeLocation = ChinaAdministrativeLocation(
            province: " 广东省 ",
            city: " 深圳市 ",
            district: " 南山区 "
        )
        edited.address = "  示例路 1 号  "
        edited.sourceTitle = "  朋友推荐  "
        edited.sourceURL = "  https://example.com/food  "
        edited.shopURL = "  https://example.com/shop  "
        edited.specialty = "  江南点心  "
        edited.note = "  下次再来  "
        edited.tags = [" 沪菜 ", "沪菜", " 朋友推荐 ", "  "]
        edited.status = .wantToTry
        edited.coordinate = FoodCoordinate(latitude: 100, longitude: 20)
        edited.photos = [retainedPhoto]

        store.upsert(edited)

        let stored = try #require(store.places.first)
        #expect(stored.shopName == "示例店")
        #expect(stored.recommendedFood == "小笼包")
        #expect(stored.administrativeLocation == ChinaAdministrativeLocation(
            province: "广东省",
            city: "深圳市",
            district: "南山区"
        ))
        #expect(stored.administrativeArea == "广东省 深圳市 南山区")
        #expect(stored.address == "示例路 1 号")
        #expect(stored.sourceTitle == "朋友推荐")
        #expect(stored.sourceURL == "https://example.com/food")
        #expect(stored.shopURL == "https://example.com/shop")
        #expect(stored.specialty == "江南点心")
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
                FoodPlace(shopName: "想吃", status: .wantToTry, visitedAt: date),
                FoodPlace(shopName: "吃过", status: .tried, visitedAt: date)
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

    @Test func administrativeLocationKeepsDistrictAndDecodesLegacyData() throws {
        let location = try #require(ChinaAdministrativeDivisions.location(
            province: "广东省",
            city: "深圳市",
            district: "南山区"
        ))
        #expect(location.displayName == "广东省 深圳市 南山区")
        #expect(ChinaAdministrativeDivisions.canonicalProvince("广东") == "广东省")

        let legacy = try JSONDecoder().decode(
            ChinaAdministrativeLocation.self,
            from: Data("{\"province\":\"广东省\",\"city\":\"深圳市\"}".utf8)
        )
        #expect(legacy.district == nil)
        #expect(legacy.displayName == "广东省 深圳市")
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
            shopName: "生煎",
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
        let place = FoodPlace(shopName: "云端美食", photos: [photoWithBackupData])

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
        let local = FoodPlace(shopName: "本地")
        var remote = local
        remote.shopName = "远端"
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
            shopName: "示例烤鸭店",
            recommendedFood: "烤鸭",
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
