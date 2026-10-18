import CoreLocation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MyTools

@MainActor
struct ModuleStoreTests {
    // Sanitized published v3 shape, kept literal so new encoders cannot redefine the fixture.
    private var paymentV3Fixture: Data { Data("""
    {"id":"11111111-1111-1111-1111-111111111111","name":"美元账户","currencies":["USD"],"accountNumber":"TEST1234","status":"normal","note":"历史备注","receivingProfile":{"id":"22222222-2222-2222-2222-222222222222","accountID":"11111111-1111-1111-1111-111111111111","details":{"name":"旧收款资料","currencies":["USD"],"fields":[],"note":"旧资料备注"}}}
    """.utf8) }

    @Test func paymentProfilesMigrateAndRoundTripWithoutLosingIdentity() async throws {
        var account = try JSONDecoder().decode(PaymentAccount.self, from: paymentV3Fixture)
        #expect(account.receivingProfiles.count == 1)
        let first = try #require(account.receivingProfiles.first)
        #expect(first.id.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(first.accountID == account.id)
        var second = FinanceReceivingMethod(accountID: account.id)
        second.details.name = "另一套收款"
        account.receivingProfiles.append(second)
        var institution = FinancialInstitution(kind: .payment)
        institution.paymentAccounts = [account]
        try institution.validate()
        let restored = try JSONDecoder().decode(FinancialInstitution.self, from: JSONEncoder().encode(institution))
        #expect(restored == institution)
        #expect(restored.receivingMethods.map(\.id) == [first.id, second.id])
        var edited = restored
        edited.removeReceivingMethod(id: first.id)
        #expect(edited.receivingMethods == [second])
        try edited.validate()
        let snapshot = try CloudSyncSnapshotBuilder.make(vault: VaultData(financialInstitutions: [institution]), secrets: [], attachmentStore: AttachmentStore(), enabledModules: [.personalFinance])
        let item = try #require(snapshot.items.first { $0.kind == .financialInstitution })
        let merged = try CloudSyncMerger.apply([.upsert(kind: item.kind, id: item.id, payload: item.payload)], to: VaultData(), secrets: [], enabledModules: [.personalFinance])
        #expect(merged.vault.financialInstitutions.first?.paymentAccounts == [account])
        let processor = AppStoreBackupProcessor()
        let backup = try await processor.makeBackup(vault: VaultData(financialInstitutions: [institution]), secrets: [], includedModules: [.personalFinance], password: "test-password")
        let restoredBackup = try await processor.restorePayload(from: backup, password: "test-password")
        #expect(restoredBackup.vault.financialInstitutions.first?.paymentAccounts == [account])
    }

    @Test func paymentProfilesMissingEmptyUnknownAndCorruptFields() throws {
        var json = try #require(JSONSerialization.jsonObject(with: paymentV3Fixture) as? [String: Any])
        json["unknownFutureField"] = "preserves decoding compatibility"
        json.removeValue(forKey: "receivingProfile")
        let missing = try JSONDecoder().decode(PaymentAccount.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(missing.receivingProfiles.isEmpty)
        json = try #require(JSONSerialization.jsonObject(with: paymentV3Fixture) as? [String: Any])
        json["receivingProfiles"] = []
        #expect(try JSONDecoder().decode(PaymentAccount.self, from: JSONSerialization.data(withJSONObject: json)).receivingProfiles.isEmpty)
        json["receivingProfiles"] = [["id": "broken"]]
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PaymentAccount.self, from: corrupt) }
        // The institution decoder must not retry a malformed current collection as a legacy account.
        let details = try JSONSerialization.data(withJSONObject: ["accounts": [json]])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PaymentInstitutionDetails.self, from: details) }
    }

    @Test func mapsUseCoordinatePinsAndOnlyAvailableApplications() throws {
        let target = AppMapNavigationTarget(name: "测试开户网点", latitude: 31.2, longitude: 121.5)
        let baidu = try #require(AppMapNavigationService.url(for: .baiduMaps, target: target))
        #expect(baidu.host == "map")
        #expect(baidu.path == "/marker")
        let google = try #require(AppMapNavigationService.url(for: .googleMaps, target: target))
        #expect(google.absoluteString.hasPrefix("comgooglemaps://?"))
        let items = try #require(URLComponents(url: google, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "q" }?.value == "31.2,121.5")
        let available = AppMapNavigationService.applications { ["maps", "baidumap"].contains($0.scheme ?? "") }
        #expect(available == [.appleMaps, .baiduMaps])
        #expect(AppMapNavigationService.url(for: .googleMaps, target: .init(name: "bad", latitude: .nan, longitude: 0)) == nil)
    }

    @Test func financeSchema3InstitutionSavesRoundTripsAndRejectsUnknownVersion() throws {
        var institution = FinancialInstitution()
        institution.name = "Example"
        institution.branchName = "Existing branch"
        let store = FinanceStore(attachmentStore: AttachmentStore())
        #expect(try store.saveInstitution(institution, cards: [], expected: nil, expectedCards: []))
        let restored = try JSONDecoder().decode(FinancialInstitution.self, from: JSONEncoder().encode(store.financialInstitutions[0]))
        #expect(restored == institution)
        #expect(restored.schemaVersion == FinancialInstitution.currentSchemaVersion)
        var invalid = restored
        invalid.schemaVersion = 999
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.schemaVersion = FinancialInstitution.currentSchemaVersion - 1
        try invalid.validate()
    }

    // AUDIT-088：券商账户只有 BrokerageAccount 一种类型；旧版借用银行账户结构的数据仍可迁移。
    @Test func legacyBrokerageAccountsMigrateIntoBrokerageAccount() throws {
        let id = UUID()
        let json = """
        {"platform":"IBKR","accounts":[{"id":"\(id.uuidString)","name":"主账户","kind":"securities","accountNumber":"U1234567",
        "currencies":["HKD"],"status":"normal","brokerage":{"accountType":"margin","baseCurrency":"USD","legalEntity":"","ownership":"联名"}}]}
        """
        let details = try JSONDecoder().decode(BrokerageInstitutionDetails.self, from: Data(json.utf8))
        let account = try #require(details.accounts.first)
        #expect(account.id == id)
        #expect(account.accountNumber == "U1234567")
        #expect(account.accountType == .margin)
        #expect(account.baseCurrency == .usd)
        #expect(account.ownership == "联名")
    }

    // AUDIT-062：悬挂的入金资料引用、重复附件 ID 均被拒绝。
    @Test func financeValidateRejectsDanglingFundingProfilesAndDuplicateAttachments() throws {
        var brokerage = FinancialInstitution(kind: .brokerage)
        var account = BrokerageAccount()
        account.fundingProfileIDs = [UUID()]
        brokerage.brokerageAccounts = [account]
        #expect(throws: (any Error).self) { try brokerage.validate() }
        let route = FinanceReceivingMethod()
        brokerage.receivingMethods = [route]
        brokerage.brokerageAccounts[0].fundingProfileIDs = [route.id]
        try brokerage.validate()

        let attachment = FileAttachment()
        brokerage.documents = [
            FinanceDocument(title: "A", attachment: attachment),
            FinanceDocument(title: "B", attachment: attachment)
        ]
        #expect(throws: (any Error).self) { try brokerage.validate() }
    }

    @Test func financeCardReplacementCyclesAreRejected() throws {
        let profile = FinancialInstitution()
        var first = BankCard()
        var second = BankCard()
        first.accountID = profile.id
        second.accountID = profile.id
        first.replacedByCardID = second.id
        second.replacedByCardID = first.id
        #expect(throws: (any Error).self) { try profile.validate(cards: [first, second]) }
        second.replacedByCardID = nil
        try profile.validate(cards: [first, second])
    }
    @Test func stockListsSortByCodeInsteadOfDisplayName() {
        var first = StockHolding(market: .hongKong, symbol: "00002")
        first.name = "Z Company"
        var second = StockHolding(market: .hongKong, symbol: "00010")
        second.name = "A Company"
        #expect([second, first].sorted(by: StockCodeOrdering.precedes).map(\.symbol) == ["00002", "00010"])
        let american = [StockHolding(market: .unitedStates, symbol: "MSFT"), StockHolding(market: .unitedStates, symbol: "AAPL")]
        #expect(american.sorted(by: StockCodeOrdering.precedes).map(\.symbol) == ["AAPL", "MSFT"])
    }
    @Test func financeAccountTypesAreIndependentAndChangingTypeOverridesLegacyLabel() {
        #expect(FinanceAccountKind.current.title == "往来账户")
        #expect(FinanceAccountKind.checking.title == "支票账户")
        #expect(FinanceAccountKind.investment.title == "投资账户")
        #expect(FinanceAccountKind.foreignExchange.title == "外汇账户")
        var account = FinancialAccount()
        account.kind = .other
        account.customType = "旧类型"
        #expect(account.typeTitle == "旧类型")
        account.kind = .pension
        #expect(account.typeTitle == FinanceAccountKind.pension.title)
    }

    @Test func newCardInheritsInstitutionBranchButDoesNotOverwriteExplicitBranch() {
        var institution = FinancialInstitution()
        var profile = FinancialInstitution()
        profile.branchName = "机构开户网点"
        profile.branchLocation = BankBranchLocation(latitude: 31.2, longitude: 121.4)
        institution.financialProfile = profile
        var card = BankCard()
        card.applyDefaultOpeningBranch(from: institution)
        #expect(card.branchName == profile.branchName)
        #expect(card.branchLocation == profile.branchLocation)
        card.branchName = "用户指定网点"
        card.applyDefaultOpeningBranch(from: institution)
        #expect(card.branchName == "用户指定网点")
    }

    @Test func institutionWithOnlyLoginInformationStaysVisible() {
        var institution = FinancialInstitution()
        var profile = FinancialInstitution()
        profile.logins = [FinanceLogin()]
        institution.financialProfile = profile
        #expect(!institution.isInactiveFinanceArchive(cards: []))
    }

    @Test func gaodeBankBranchURLUsesSearchNavigationEndpoint() throws {
        let location = BankBranchLocation(latitude: 39.9042, longitude: 116.4074)
        let url = try #require(BankBranchNavigationService.url(for: .amap, branchName: "Test Bank", location: location))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.scheme == "iosamap")
        #expect(components.host == "viewMap")
        #expect(query["poiname"] == "Test Bank")
        #expect(query["lat"] == "39.9042")
        #expect(query["lon"] == "116.4074")
    }

    // AUDIT-026：无坐标时按名称搜索，不再导航到天安门默认点。
    @Test func branchWithoutCoordinateSearchesByNameInsteadOfDefaultPoint() throws {
        let url = try #require(BankBranchNavigationService.url(for: .amap, branchName: "测试支行", location: nil))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "poi")
        #expect(components.queryItems?.contains { $0.name == "lat" } == false)
        #expect(components.queryItems?.first { $0.name == "name" }?.value == "测试支行")
        #expect(BankBranchNavigationService.url(for: .appleMaps, branchName: " ", location: nil) == nil)
    }
    @Test func financeDraftConflictDoesNotOverwriteUpdatedCardsOrRecreateDeletedAccount() {
        let account = FinancialInstitution()
        var card = BankCard()
        card.accountID = account.id
        let store = FinanceStore(accounts: [account], cards: [card], attachmentStore: AttachmentStore())
        var updated = card
        updated.holderName = "Changed elsewhere"
        store.replaceAccount(account, cards: [updated], expected: store.financialInstitutions[0])
        let accepted = store.replaceAccount(account, cards: [card], expected: account, expectedCards: [card])
        #expect(!accepted)
        #expect(store.cards == [updated])
        #expect(!store.updateCard(card, expected: card))
        store.deleteAccount(id: account.id)
        let resurrected = store.replaceAccount(account, cards: [card], expected: account)
        #expect(!resurrected)
        #expect(store.financialInstitutions.isEmpty)
    }

    @Test func explicitEmptyFinanceTemplatesSurviveReloadAndVaultRoundTrip() throws {
        let store = FinanceStore(attachmentStore: AttachmentStore())
        for template in store.domesticLoginFieldTemplates { store.deleteLoginFieldTemplate(template, for: .domestic) }
        let vault = VaultData(domesticBankLoginFieldTemplates: store.domesticLoginFieldTemplates,
                              overseasBankLoginFieldTemplates: store.overseasLoginFieldTemplates)
        let restored = try JSONDecoder().decode(VaultData.self, from: JSONEncoder().encode(vault))
        store.replace(financialInstitutions: [], domesticLoginFieldTemplates: restored.domesticBankLoginFieldTemplates,
                      overseasLoginFieldTemplates: restored.overseasBankLoginFieldTemplates)
        #expect(store.domesticLoginFieldTemplates.isEmpty)
        #expect(!store.overseasLoginFieldTemplates.isEmpty)
        let legacy = try JSONDecoder().decode(VaultData.self, from: Data("{}".utf8))
        #expect(!legacy.domesticBankLoginFieldTemplates.isEmpty)
        #expect(!legacy.overseasBankLoginFieldTemplates.isEmpty)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VaultData.self, from: Data("{\"domesticBankLoginFieldTemplates\":[{\"name\":123}]}".utf8))
        }
    }
    @Test func financeSubaccountTypesMatchTheirBankRegion() {
        #expect(DomesticAccountType.allCases.map(\.title) == [
            "储蓄账户",
            "投资账户",
            "外汇账户",
            "个人养老金账户",
            "社保账户",
            "公积金账户",
            "其他账户"
        ])
        #expect(ForeignAccountType.allCases.map(\.title) == [
            "储蓄账户",
            "往来账户",
            "定存账户",
            "外汇账户",
            "投资账户",
            "支票账户",
            "智能账户",
            "其他账户"
        ])
    }

    @Test func removedDomesticPresetRemainsEditableAsACustomType() {
        #expect(DomesticAccountType.selection(for: "公积金账户") == .providentFund)
        #expect(DomesticAccountType.selection(for: "支票账户") == .other)
        #expect(DomesticAccountType.selection(for: "") == .savings)
    }

    @Test func bankWithOnlyAnOpenCreditCardIsNotInactive() {
        let account = FinancialInstitution()
        var creditCard = BankCard()
        creditCard.kind = .credit
        creditCard.status = .normal

        #expect(!account.isInactiveFinanceArchive(cards: [creditCard]))

        creditCard.status = .closed
        #expect(account.isInactiveFinanceArchive(cards: [creditCard]))
    }

    @Test func financeArchiveFollowsAccountAndCardClosure() {
        var institution = FinancialInstitution()
        var profile = FinancialInstitution()
        profile.name = "Example"
        institution.financialProfile = profile
        #expect(!institution.isInactiveFinanceArchive(cards: []))

        var financialAccount = FinancialAccount()
        financialAccount.status = .normal
        profile.accounts = [financialAccount]
        institution.financialProfile = profile
        #expect(!institution.isInactiveFinanceArchive(cards: []))

        financialAccount.status = .closed
        profile.accounts = [financialAccount]
        institution.financialProfile = profile
        // AUDIT-061 以代码为准：银行归档以卡片为准；没有卡片且机构状态正常时，唯一账户销户也不归档。
        #expect(!institution.isInactiveFinanceArchive(cards: []))
        institution.status = .closed
        #expect(institution.isInactiveFinanceArchive(cards: []))
        institution.status = .normal

        var card = BankCard()
        card.status = .normal
        #expect(!institution.isInactiveFinanceArchive(cards: [card]))
        card.status = .closed
        #expect(institution.isInactiveFinanceArchive(cards: [card]))
    }

    @Test func financeAccountNumberMasksBothEnds() {
        var account = FinancialAccount()
        #expect(account.maskedAccountNumber == "未填写账号")
        account.accountNumber = "1234 5678 9012 3456"
        #expect(account.maskedAccountNumber == "1234••••3456")
    }

    @Test func financeCurrencyChooserKeepsOnlyThreePrimaryCurrencies() {
        #expect(CurrencyCode.preferredFinanceCases(for: .domestic) == [.cny, .hkd, .usd])
        #expect(CurrencyCode.preferredFinanceCases(for: .overseas) == [.cny, .hkd, .usd])
        #expect(CurrencyCode.additionalFinanceCases(for: .overseas, including: [.eur]).contains(.eur))
    }

    @Test func receivingShareOmitsLegacyChannelButKeepsFields() {
        var details = FinanceReceivingDetails()
        details.name = "美元入金"
        details.fields = [FinanceReceivingField(kind: .bic, value: "TESTUS33")]
        #expect(details.shareText.contains("SWIFT / BIC：TESTUS33"))
        #expect(!details.shareText.contains("渠道："))
    }

    @Test func receivingCurrenciesDecodeLegacyAndRoundTripMultiple() throws {
        var legacy = FinanceReceivingDetails()
        legacy.currency = .usd
        let encoded = try JSONEncoder().encode(legacy)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "currencies")
        let oldData = try JSONSerialization.data(withJSONObject: json)
        var restored = try JSONDecoder().decode(FinanceReceivingDetails.self, from: oldData)
        #expect(restored.effectiveCurrencies == [.usd])
        restored.currencies = [.usd, .hkd]
        let roundTripped = try JSONDecoder().decode(FinanceReceivingDetails.self, from: JSONEncoder().encode(restored))
        #expect(roundTripped.effectiveCurrencies == [.hkd, .usd])
        #expect(roundTripped.shareText.contains("HKD · USD"))
    }

    @Test func bankCardOpeningBranchRoundTripsAndLegacyDataDefaultsToEmpty() throws {
        var card = BankCard()
        card.branchName = "中关村支行"
        card.branchLocation = BankBranchLocation(latitude: 39.98, longitude: 116.31)
        card.additionalCredentials = [BankCardCredential(
            name: "Visa 卡面",
            cardNumber: "4111111111111111",
            networks: [.visa],
            cvv: "123",
            currencies: [.usd],
            holderName: "HUANG SHUAI",
            status: .abnormal
        )]

        let encoded = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(BankCard.self, from: encoded)
        #expect(decoded.branchName == "中关村支行")
        #expect(decoded.branchLocation == BankBranchLocation(latitude: 39.98, longitude: 116.31))
        #expect(decoded.additionalCredentials.count == 1)
        #expect(decoded.additionalCredentials.first?.name == "Visa 卡面")
        #expect(decoded.additionalCredentials.first?.cardNumber == "4111111111111111")
        #expect(decoded.additionalCredentials.first?.networks == [.visa])
        #expect(decoded.additionalCredentials.first?.cvv == "123")
        #expect(decoded.additionalCredentials.first?.currencies == [.usd])
        #expect(decoded.additionalCredentials.first?.holderName == "HUANG SHUAI")
        #expect(decoded.additionalCredentials.first?.status == .abnormal)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "branchName")
        legacyObject.removeValue(forKey: "branchLocation")
        legacyObject.removeValue(forKey: "additionalCardCredentials")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyCard = try JSONDecoder().decode(BankCard.self, from: legacyData)
        #expect(legacyCard.branchName == nil)
        #expect(legacyCard.branchLocation == nil)
        #expect(legacyCard.additionalCredentials.isEmpty)

        let legacyCredential = try JSONDecoder().decode(
            BankCardCredential.self,
            from: Data("{\"name\":\"银联卡号\",\"cardNumber\":\"6222000000000000\"}".utf8)
        )
        #expect(legacyCredential.name == "银联卡号")
        #expect(legacyCredential.cardNumber == "6222000000000000")
        #expect(legacyCredential.networks.isEmpty)
        #expect(legacyCredential.currencies.isEmpty)
        #expect(legacyCredential.status == .normal)
    }

    @Test func domesticCardWithoutAnOpeningBranchDefaultsToItsAccountBranch() {
        var account = FinancialInstitution()
        account.region = .domestic
        account.branchName = "北京银行（中关村软件园支行）"
        account.branchLocation = BankBranchLocation(latitude: 40.052, longitude: 116.298)

        var card = BankCard()
        #expect(card.resolvedOpeningBranch(for: account) == BankBranchReference(
            name: "北京银行（中关村软件园支行）",
            location: BankBranchLocation(latitude: 40.052, longitude: 116.298)
        ))

        card.applyDefaultOpeningBranch(from: account)
        #expect(card.branchName == "北京银行（中关村软件园支行）")
        #expect(card.branchLocation == BankBranchLocation(latitude: 40.052, longitude: 116.298))

        card.branchName = "北京银行（永丰支行）"
        card.branchLocation = nil
        #expect(card.resolvedOpeningBranch(for: account) == BankBranchReference(
            name: "北京银行（永丰支行）",
            location: nil
        ))

        account.isOnlineBank = true
        #expect(card.resolvedOpeningBranch(for: account) == BankBranchReference(
            name: "网络银行",
            location: nil
        ))
        card.applyDefaultOpeningBranch(from: account)
        #expect(card.branchName == "北京银行（永丰支行）")
        #expect(card.branchLocation == nil)

        account.isOnlineBank = false
        account.region = .overseas
        card.branchName = nil
        #expect(card.resolvedOpeningBranch(for: account).name == account.branchName)
    }

    @Test func bankBranchMapSelectionKeepsTheMapItemNameAndIgnoresMarkerPlaceholder() {
        let coordinate = CLLocationCoordinate2D(latitude: 40.052, longitude: 116.298)
        let mapSelection = MapLocationSelection(
            name: "北京银行（中关村软件园支行）",
            address: "北京市海淀区西北旺东路",
            coordinate: coordinate,
            administrativeContext: "北京市 海淀区"
        )
        let branch = BankBranchSelection(
            mapSelection: mapSelection,
            markerFallback: "开卡网点"
        )

        #expect(branch.name == "北京银行（中关村软件园支行）")
        #expect(branch.location == BankBranchLocation(latitude: 40.052, longitude: 116.298))

        let manualPin = BankBranchSelection(
            mapSelection: MapLocationSelection(
                name: "开卡网点",
                address: "",
                coordinate: coordinate,
                administrativeContext: ""
            ),
            markerFallback: "开卡网点"
        )
        #expect(manualPin.name.isEmpty)

        let overseasBranch = BankBranchSelection(
            mapSelection: MapLocationSelection(
                name: "Bank of China (Hong Kong) Central District Branch",
                address: "1 Garden Road, Central, Hong Kong",
                coordinate: CLLocationCoordinate2D(latitude: 22.278, longitude: 114.164),
                administrativeContext: "Hong Kong Central"
            ),
            markerFallback: "分行/网点"
        )
        #expect(overseasBranch.name == "Bank of China (Hong Kong) Central District Branch")
    }

    @Test func moduleCatalogCoversEveryTopLevelModule() {
        #expect(ToolModuleCatalog.allModules == CompiledToolModules.set)
        #expect(Set(CompiledToolModules.ordered) == CompiledToolModules.set)
        #expect(CompiledToolModules.ordered.count == CompiledToolModules.set.count)
        #expect(ToolModule.allCases.allSatisfy { $0.definition.module == $0 })
    }

    @Test func moduleSettingsExposeOnlyCompiledModules() {
        let defaults = UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!
        let settings = ToolModuleSettings(defaults: defaults)
        var visibilityChanges: [ToolModule] = []
        settings.setVisibilityChangeHandler { module, _ in
            visibilityChanges.append(module)
        }

        #expect(settings.orderedModules == CompiledToolModules.ordered)
        #expect(settings.syncedModuleOrder.isEmpty)
        #expect(settings.syncedModuleVisibility.isEmpty)

        for module in ToolModule.allCases where !CompiledToolModules.contains(module) {
            settings.setVisible(true, for: module)
            #expect(!settings.isVisible(module))
            #expect(defaults.object(forKey: module.visibilityKey) == nil)
        }
        #expect(visibilityChanges.isEmpty)
    }

    // AUDIT-033：新设备只上传显式设置，默认值不会覆盖另一台设备的选择。
    @Test func moduleSettingsSyncOnlyExplicitChoices() throws {
        let module = try #require(CompiledToolModules.ordered.first)
        let deviceA = ToolModuleSettings(defaults: UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!)
        let deviceB = ToolModuleSettings(defaults: UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!)
        deviceA.setVisible(!module.defaultIsVisible, for: module)

        deviceA.applySyncedPreferences(
            order: deviceB.syncedModuleOrder,
            visibility: deviceB.syncedModuleVisibility
        )
        #expect(deviceA.isVisible(module) == !module.defaultIsVisible)

        deviceB.applySyncedPreferences(
            order: deviceA.syncedModuleOrder,
            visibility: deviceA.syncedModuleVisibility
        )
        #expect(deviceB.isVisible(module) == !module.defaultIsVisible)
        #expect(deviceB.syncedModuleVisibility == [module.rawValue: !module.defaultIsVisible])
        #expect(deviceB.syncedModuleOrder.isEmpty)
    }

    @Test func moduleSettingsUseCompileTimeDefaultsUntilOverridden() {
        let defaults = UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!
        let settings = ToolModuleSettings(defaults: defaults)

        for module in CompiledToolModules.ordered {
            #expect(settings.isVisible(module) == module.defaultIsVisible)
            #expect(defaults.object(forKey: module.visibilityKey) == nil)
        }

        guard let module = CompiledToolModules.ordered.first else { return }
        settings.setVisible(!module.defaultIsVisible, for: module)
        #expect(settings.isVisible(module) == !module.defaultIsVisible)
        #expect(defaults.bool(forKey: module.visibilityKey) == !module.defaultIsVisible)

        let restored = ToolModuleSettings(defaults: defaults)
        #expect(restored.isVisible(module) == !module.defaultIsVisible)
    }

    @Test func opaqueModuleValuesRoundTripAndRetainAttachmentReferences() throws {
        let source = Data(#"{"id":"item-1","count":3,"ratio":1.25,"active":true,"empty":null,"attachments":[{"storedFileName":"first.pdf"},{"nested":{"storedFileName":"second.jpg"}},{"storedFileName":""}]}"#.utf8)
        let decoded = try JSONDecoder().decode(OpaqueModuleValue.self, from: source)
        let encoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(OpaqueModuleValue.self, from: encoded)

        #expect(roundTripped == decoded)
        #expect(decoded.attachmentStoredFileNames == ["first.pdf", "second.jpg"])
    }

    @Test func lifecycleRegistryNotifiesOnlyInterestedParticipants() {
        let registry = ModuleLifecycleRegistry()
        let participant = RecordingModuleLifecycleParticipant(observedModules: [.myStocks])
        registry.register(participant)

        registry.notify(module: .healthRecords, isEnabled: false)
        registry.notify(module: .myStocks, isEnabled: false)

        #expect(participant.changes.map(\.0) == [.myStocks])
        #expect(participant.changes.map(\.1) == [false])
    }

    @Test func cleanupRegistryOnlyScansAndCleansEnabledModules() {
        let registry = ModuleDataCleanupRegistry()
        let finance = RecordingModuleDataCleanupParticipant(module: .personalFinance)
        let health = RecordingModuleDataCleanupParticipant(module: .healthRecords)
        registry.register(finance)
        registry.register(health)

        let report = registry.scan(enabledModules: [.healthRecords])
        let cleanupReport = registry.cleanup(enabledModules: [.healthRecords])

        #expect(report.findings.map(\.module) == [.healthRecords])
        #expect(cleanupReport == report)
        #expect(finance.scanCount == 0)
        #expect(finance.cleanupCount == 0)
        #expect(health.scanCount == 2)
        #expect(health.cleanupCount == 1)
    }

    @Test func financeStoreRetainsAttachmentsUntilPersistenceConfirmsRemoval() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("MyToolsTests-\(UUID().uuidString)", isDirectory: true)
        let attachmentStore = AttachmentStore(
            fileManager: fileManager,
            directoryURL: directoryURL
        )
        defer { try? fileManager.removeItem(at: directoryURL) }
        let attachment = try attachmentStore.save(
            data: Data("statement".utf8),
            originalFileName: "statement.pdf",
            contentType: .pdf
        )
        var account = FinancialInstitution()
        account.bankName = "Test Bank"
        var statement = CreditCardStatement()
        statement.attachment = attachment
        var card = BankCard()
        card.accountID = account.id
        card.statements = [statement]
        let store = FinanceStore(
            accounts: [account],
            cards: [card],
            attachmentStore: attachmentStore
        )

        store.replaceAccount(account, cards: [], expected: store.financialInstitutions[0])

        #expect(store.cards.isEmpty)
        #expect(fileManager.fileExists(atPath: attachmentStore.url(for: attachment).path))
    }

    @Test func financeCleanupRemovesOnlyFieldsThatDoNotApplyToTheCurrentType() throws {
        var domestic = FinancialInstitution()
        domestic.name = "境内银行"
        domestic.region = .domestic
        domestic.swift = "SWIFT"
        domestic.correspondenceAddressChinese = "境外通讯地址"
        domestic.remittanceInstructions = "汇款说明"
        var stale = FinancialAccount()
        stale.kind = .savings
        stale.customType = "旧类型"
        var custom = FinancialAccount()
        custom.kind = .other
        custom.customType = "贵金属账户"
        var staleChild = FinancialAccount()
        staleChild.kind = .termDeposit
        staleChild.customType = "旧子类型"
        stale.subaccounts = [staleChild]
        domestic.accounts = [stale, custom]
        var overseas = FinancialInstitution()
        overseas.region = .overseas
        overseas.swift = "KEEP"
        overseas.correspondenceAddressEnglish = "Keep address"
        var other = FinancialInstitution(kind: .other)
        var otherAccount = FinancialAccount()
        otherAccount.kind = .pension
        otherAccount.customType = "旧养老金类型"
        other.accounts = [otherAccount]
        let store = FinanceStore(
            accounts: [domestic, overseas, other],
            attachmentStore: AttachmentStore()
        )

        let report = RedundantDataCleanupReport(findings: store.scanRedundantData())
        #expect(report.findings.map(\.ruleID) == [
            "non-custom-account-type",
            "domestic-overseas-details"
        ])
        #expect(report.findings[0].items.map(\.id) == [
            "\(domestic.id.uuidString).\(stale.id.uuidString)",
            "\(domestic.id.uuidString).\(staleChild.id.uuidString)",
            "\(other.id.uuidString).\(otherAccount.id.uuidString)"
        ])
        #expect(report.findings[1].items.map(\.recordTitle) == ["境内银行"])
        #expect(report.findings[1].items.first?.fieldNames == ["SWIFT", "汇款说明", "通讯地址（中文）"])
        #expect(report.affectedFieldCount == 6)

        store.cleanupRedundantData()

        let cleanedDomestic = try #require(store.financialInstitutions.first)
        #expect(cleanedDomestic.swift.isEmpty)
        #expect(cleanedDomestic.correspondenceAddressChinese.isEmpty)
        #expect(cleanedDomestic.remittanceInstructions.isEmpty)
        #expect(cleanedDomestic.accounts[0].customType.isEmpty)
        #expect(cleanedDomestic.accounts[0].subaccounts[0].customType.isEmpty)
        #expect(cleanedDomestic.accounts[1].customType == "贵金属账户")
        let retainedOverseas = try #require(store.financialInstitutions.dropFirst().first)
        #expect(retainedOverseas.swift == "KEEP")
        #expect(retainedOverseas.correspondenceAddressEnglish == "Keep address")
        #expect(store.financialInstitutions.last?.accounts.first?.customType.isEmpty == true)
        #expect(store.scanRedundantData().isEmpty)
    }

    @Test func financeLoginTemplatesAreRegionSpecificAndPersistent() throws {
        let domestic = BankLoginFieldTemplate(name: "境内网银网址")
        let overseas = BankLoginFieldTemplate(name: "海外安全问题", isSensitive: true)
        var legacyAccount = FinancialInstitution()
        legacyAccount.boundPhoneNumber = "13800138000"
        legacyAccount.loginAccount = "legacy-user"
        legacyAccount.loginPassword = "legacy-password"
        let store = FinanceStore(
            accounts: [legacyAccount],
            domesticLoginFieldTemplates: [domestic],
            overseasLoginFieldTemplates: [overseas],
            attachmentStore: AttachmentStore()
        )

        #expect(store.makeLoginFields(for: .domestic).map(\.name) == ["境内网银网址"])
        #expect(store.makeLoginFields(for: .overseas).map(\.name) == ["海外安全问题"])
        #expect(store.makeLoginFields(for: .overseas).first?.isSensitive == true)

        // Schema 3 keeps the legacy accessors as views over additionalLoginFields.
        let migratedAccount = try #require(store.financialInstitutions.first)
        #expect(migratedAccount.boundPhoneNumber == "13800138000")
        #expect(migratedAccount.loginAccount == "legacy-user")
        #expect(migratedAccount.loginPassword == "legacy-password")
        #expect(migratedAccount.additionalLoginFields.contains {
            $0.name == "绑定手机号" && $0.value == "13800138000" && !$0.isSensitive
        })
        #expect(migratedAccount.additionalLoginFields.contains {
            $0.name == "登录账号" && $0.value == "legacy-user" && !$0.isSensitive
        })
        #expect(migratedAccount.additionalLoginFields.contains {
            $0.name == "登录密码" && $0.value == "legacy-password" && $0.isSensitive
        })

        var editedTemplate = domestic
        editedTemplate.isSensitive = true
        store.upsertLoginFieldTemplate(editedTemplate, for: .domestic)
        #expect(store.financialInstitutions.first?.additionalLoginFields.first { $0.name == "登录账号" }?.isSensitive == false)
    }

    @Test func secretStoreRejectsMutationsWhileBackupRestoreIsInProgress() {
        let original = SecretItem(title: "Original")
        let store = SecretStore(
            secretItems: [original],
            attachmentStore: AttachmentStore()
        )
        var edited = original
        edited.title = "Changed"

        store.backupRestoreStateChanged(isRestoring: true)
        store.upsertSecret(edited)
        store.deleteSecrets(ids: [original.id])

        #expect(store.secretItems.map(\.title) == ["Original"])

        store.backupRestoreStateChanged(isRestoring: false)
        store.upsertSecret(edited)

        #expect(store.secretItems.map(\.title) == ["Changed"])
    }

    @Test func currencyAlertDisablesItselfAfterSending() {
        let notifications = RecordingAlertNotificationRouter()
        let alert = CurrencyRateAlert(
            currency: .usd,
            amount: 100,
            direction: .above,
            threshold: 600,
            isEnabled: true
        )
        let store = CurrencyExchangeStore(
            rateAlerts: [alert],
            alertNotifications: notifications
        )

        store.exchangeRatesDidUpdate([.cny: 1, .usd: 7])

        #expect(notifications.sentRuleIDs == [alert.id])
        #expect(notifications.clearedRuleIDs == [alert.id])
        #expect(store.rateAlerts.first?.isEnabled == false)
    }

    @Test func healthStoreSynchronizesDataWhenModuleReopens() {
        let defaults = UserDefaults(suiteName: "MyToolsTests.\(UUID().uuidString)")!
        let settings = ToolModuleSettings(defaults: defaults)
        settings.setVisible(false, for: .healthRecords)
        var parent = MedicalRecord()
        parent.visitType = .inpatient
        parent.date = Self.date(day: 1)
        parent.inpatientEndDate = Self.date(day: 2)
        parent.hospital = "Test Hospital"
        let store = HealthStore(
            medicalRecords: [parent],
            attachmentStore: AttachmentStore(),
            isModuleVisible: settings.isVisible(.healthRecords)
        )

        store.synchronizeLoadedRecords()

        #expect(store.medicalRecords.count == 1)
        #expect(store.hospitalProfiles.isEmpty)

        settings.setVisible(true, for: .healthRecords)
        store.moduleVisibilityChanged(isVisible: true)

        #expect(store.medicalRecords.filter(\.isInpatientDailyRecord).count == 2)
        #expect(store.hospitalProfiles.map(\.name) == ["Test Hospital"])
    }

    @Test func healthCleanupRemovesFieldsThatDoNotApplyToTheVisitType() throws {
        var pharmacy = MedicalRecord()
        pharmacy.visitType = .pharmacyPurchase
        pharmacy.inpatientEndDate = Date()
        pharmacy.physicalExamDetails = PhysicalExamDetails(packageName: "旧套餐")
        pharmacy.hospitalLevel = .levelThree
        pharmacy.hospitalGrade = .classA
        pharmacy.hospitalCategory = .general
        var inpatient = MedicalRecord()
        inpatient.visitType = .inpatient
        inpatient.inpatientEndDate = Date()
        var exam = MedicalRecord(physicalExamOn: Date())
        exam.physicalExamDetails = PhysicalExamDetails(packageName: "保留套餐")
        let store = HealthStore(
            medicalRecords: [pharmacy, inpatient, exam],
            attachmentStore: AttachmentStore()
        )

        let report = RedundantDataCleanupReport(findings: store.scanRedundantData())
        store.cleanupRedundantData()

        #expect(report.findings.map(\.ruleID) == [
            "non-episode-discharge-date",
            "non-exam-details",
            "non-hospital-classification"
        ])
        #expect(report.affectedFieldCount == 5)
        let cleanedPharmacy = try #require(store.medicalRecords.first)
        #expect(cleanedPharmacy.inpatientEndDate == nil)
        #expect(cleanedPharmacy.physicalExamDetails == nil)
        #expect(cleanedPharmacy.hospitalLevel == .unspecified)
        #expect(cleanedPharmacy.hospitalGrade == .unspecified)
        #expect(cleanedPharmacy.hospitalCategory == .unspecified)
        #expect(store.medicalRecords[1].inpatientEndDate != nil)
        #expect(store.medicalRecords[2].physicalExamDetails?.packageName == "保留套餐")
    }

    private static func date(day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: day,
            hour: 12
        ))!
    }
}

@MainActor
private final class RecordingModuleLifecycleParticipant: ModuleLifecycleParticipant {
    let observedModules: Set<ToolModule>
    private(set) var changes: [(ToolModule, Bool)] = []

    init(observedModules: Set<ToolModule>) {
        self.observedModules = observedModules
    }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        changes.append((module, isEnabled))
    }
}

@MainActor
private final class RecordingModuleDataCleanupParticipant: ModuleDataCleanupParticipant {
    let cleanupModule: ToolModule
    private(set) var scanCount = 0
    private(set) var cleanupCount = 0

    init(module: ToolModule) {
        cleanupModule = module
    }

    func scanRedundantData() -> [RedundantDataFinding] {
        scanCount += 1
        return [RedundantDataFinding(
            ruleID: "test",
            module: cleanupModule,
            title: "Test",
            detail: "Test",
            affectedRecordCount: 1,
            affectedFieldCount: 1
        )]
    }

    func cleanupRedundantData() {
        cleanupCount += 1
    }
}

@MainActor
private final class RecordingAlertNotificationRouter: AlertNotificationRouting {
    private(set) var sentRuleIDs: [UUID] = []
    private(set) var clearedRuleIDs: [UUID] = []

    func send(title: String, body: String, ruleID: UUID) {
        sentRuleIDs.append(ruleID)
    }

    func shouldSend(for ruleID: UUID, condition: Bool) -> Bool {
        condition
    }

    func clearState(for ruleID: UUID) {
        clearedRuleIDs.append(ruleID)
    }
}
