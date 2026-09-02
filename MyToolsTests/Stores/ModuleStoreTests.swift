import CoreLocation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MyTools

@MainActor
struct ModuleStoreTests {
    @Test func financeSubaccountTypesMatchTheirBankRegion() {
        #expect(DomesticAccountType.allCases.map(\.title) == [
            "储蓄账户",
            "投资账户",
            "外汇账户",
            "个人养老金账户",
            "社保账户",
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
        #expect(DomesticAccountType.selection(for: "公积金账户") == .other)
        #expect(DomesticAccountType.selection(for: "支票账户") == .other)
        #expect(DomesticAccountType.selection(for: "") == .savings)
    }

    @Test func bankWithOnlyAnOpenCreditCardIsNotInactive() {
        let account = BankAccount()
        var creditCard = BankCard()
        creditCard.kind = .credit
        creditCard.status = .normal

        #expect(!account.isInactiveFinanceArchive(cards: [creditCard]))

        creditCard.status = .closed
        #expect(account.isInactiveFinanceArchive(cards: [creditCard]))
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
        var account = BankAccount()
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
        #expect(card.branchName == nil)
        #expect(card.branchLocation == nil)

        account.isOnlineBank = false
        account.region = .overseas
        card.branchName = nil
        #expect(!card.resolvedOpeningBranch(for: account).hasValue)
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
        #expect(settings.syncedModuleOrder == CompiledToolModules.ordered)
        #expect(Set(settings.syncedModuleVisibility.keys) == Set(CompiledToolModules.ordered.map(\.rawValue)))

        for module in ToolModule.allCases where !CompiledToolModules.contains(module) {
            settings.setVisible(true, for: module)
            #expect(!settings.isVisible(module))
            #expect(defaults.object(forKey: module.visibilityKey) == nil)
        }
        #expect(visibilityChanges.isEmpty)
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

    @Test func financeStoreDeletesStatementsRemovedDuringAccountReplacement() throws {
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
        var account = BankAccount()
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

        store.replaceAccount(account, cards: [])

        #expect(store.cards.isEmpty)
        #expect(!fileManager.fileExists(atPath: attachmentStore.url(for: attachment).path))
    }

    @Test func financeCleanupRemovesOnlyFieldsThatDoNotApplyToTheCurrentType() throws {
        var domestic = BankAccount()
        domestic.region = .domestic
        domestic.swift = "SWIFT"
        domestic.correspondenceAddressChinese = "境外通讯地址"
        domestic.remittanceInstructions = "汇款说明"
        domestic.foreignSubaccounts = [
            ForeignSubaccount(type: .savings, customType: "旧类型"),
            ForeignSubaccount(type: .other, customType: "贵金属账户")
        ]
        var overseas = BankAccount()
        overseas.region = .overseas
        overseas.swift = "KEEP"
        overseas.correspondenceAddressEnglish = "Keep address"
        let store = FinanceStore(
            accounts: [domestic, overseas],
            attachmentStore: AttachmentStore()
        )

        let report = RedundantDataCleanupReport(findings: store.scanRedundantData())
        store.cleanupRedundantData()

        #expect(report.findings.map(\.ruleID) == [
            "non-custom-foreign-account-type",
            "domestic-overseas-details"
        ])
        #expect(report.affectedFieldCount == 4)
        let cleanedDomestic = try #require(store.accounts.first)
        #expect(cleanedDomestic.swift.isEmpty)
        #expect(cleanedDomestic.correspondenceAddressChinese.isEmpty)
        #expect(cleanedDomestic.remittanceInstructions.isEmpty)
        #expect(cleanedDomestic.foreignSubaccounts[0].customType == nil)
        #expect(cleanedDomestic.foreignSubaccounts[1].customType == "贵金属账户")
        let retainedOverseas = try #require(store.accounts.last)
        #expect(retainedOverseas.swift == "KEEP")
        #expect(retainedOverseas.correspondenceAddressEnglish == "Keep address")
    }

    @Test func financeLoginTemplatesAreRegionSpecificAndPersistent() throws {
        let domestic = BankLoginFieldTemplate(name: "境内网银网址")
        let overseas = BankLoginFieldTemplate(name: "海外安全问题", isSensitive: true)
        var legacyAccount = BankAccount()
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

        let migratedAccount = try #require(store.accounts.first)
        #expect(migratedAccount.boundPhoneNumber.isEmpty)
        #expect(migratedAccount.loginAccount.isEmpty)
        #expect(migratedAccount.loginPassword.isEmpty)
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
        #expect(store.accounts.first?.additionalLoginFields.first { $0.name == "登录账号" }?.isSensitive == false)
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
            moduleSettings: settings
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
