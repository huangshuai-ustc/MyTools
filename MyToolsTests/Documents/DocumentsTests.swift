#if MYTOOLS_FEATURE_DOCUMENTS
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MyTools

@MainActor
struct DocumentsTests {
    @Test func documentTypesExposeOfficiallyDistinctTemplatesAndValidityRules() {
        #expect(CredentialDocumentType.birthMedicalCertificate.title == "出生医学证明")
        #expect(CredentialDocumentType.vaccinationCertificate.title == "预防接种证")
        #expect(CredentialDocumentType.professionalQualificationCertificate.title == "职业资格证书")
        #expect(CredentialDocumentType.birthMedicalCertificate.defaultFields.map(\.label).contains("母亲姓名"))
        #expect(CredentialDocumentType.vaccinationCertificate.defaultFields.map(\.label).contains("接种记录"))
        #expect(CredentialDocumentType.professionalQualificationCertificate.defaultFields.map(\.label).contains("资格等级"))
        #expect(CredentialValidityKind.options(for: .passport) == [.fiveYears, .tenYears])
        #expect(CredentialValidityKind.options(for: .hongKongMacaoPermit) == [.fiveYears, .tenYears])
        #expect(CredentialValidityKind.options(for: .driversLicense) == [.sixYears, .tenYears, .permanent])
        #expect(CredentialValidityKind.isAlwaysPermanent(for: .birthMedicalCertificate))
        #expect(CredentialValidityKind.isAlwaysPermanent(for: .vaccinationCertificate))
    }

    @Test func expirationUsesMandatoryIssuanceDateForAllFixedTerms() {
        let issuedAt = Self.date(year: 2026, month: 8, day: 12)
        let calendar = Self.calendar
        let cases: [(CredentialDocumentType, CredentialValidityKind, Date)] = [
            (.identityCard, .tenYears, Self.date(year: 2036, month: 8, day: 12)),
            (.passport, .fiveYears, Self.date(year: 2031, month: 8, day: 11)),
            (.passport, .tenYears, Self.date(year: 2036, month: 8, day: 11)),
            (.hongKongMacaoPermit, .tenYears, Self.date(year: 2036, month: 8, day: 12)),
            (.driversLicense, .sixYears, Self.date(year: 2032, month: 8, day: 12))
        ]
        for (type, kind, expected) in cases {
            let document = CredentialDocument(type: type, issuedAt: issuedAt, validity: CredentialValidity(kind: kind))
            #expect(document.expirationDate(calendar: calendar) == expected)
        }
    }

    @Test func validityStatusDistinguishesPermanentUpcomingAndExpired() {
        let calendar = Self.calendar
        let today = Self.date(year: 2026, month: 8, day: 11)
        var document = CredentialDocument()

        document.validity = CredentialValidity(kind: .permanent)
        #expect(document.validityStatus(on: today, calendar: calendar) == .permanent)

        document.validity = CredentialValidity(
            kind: .dateRange,
            endDate: Self.date(year: 2026, month: 9, day: 10)
        )
        #expect(
            document.validityStatus(on: today, calendar: calendar)
                == .expiringSoon(daysRemaining: 30)
        )

        document.validity.endDate = Self.date(year: 2026, month: 8, day: 1)
        #expect(
            document.validityStatus(on: today, calendar: calendar)
                == .expired(daysElapsed: 10)
        )

        document.issuedAt = Self.date(year: 2026, month: 8, day: 11)
        document.validity = CredentialValidity(kind: .fiveYears)
        #expect(
            document.expirationDate(calendar: calendar)
                == Self.date(year: 2031, month: 8, day: 11)
        )

        document.validity = CredentialValidity(kind: .unspecified)
        #expect(document.expirationDate(calendar: calendar) == nil)
        #expect(!CredentialValidityKind.identityCardOptions.contains(.unspecified))
    }

    @Test func fixedTermDateRulesAreAppliedWhenInferringOCRValidity() throws {
        let start = Self.date(year: 2026, month: 8, day: 12)
        let passportResult = OCRResult(lines: [
            Self.line("签发日期 2026.08.12", y: 0.1),
            Self.line("有效期 2026.08.12-2036.08.11", y: 0.2)
        ])
        let passportSuggestion = CredentialOCRParser.parse(
            passportResult,
            for: .passport,
            calendar: Self.calendar
        )
        var passport = CredentialDocument(type: .passport)
        passport.applyOCRSuggestion(passportSuggestion, calendar: Self.calendar)
        #expect(passport.issuedAt == start)
        #expect(passport.validity.kind == .tenYears)
        #expect(passport.expirationDate(calendar: Self.calendar) == Self.date(year: 2036, month: 8, day: 11))

        let permitResult = OCRResult(lines: [
            Self.line("签发日期 2026.08.12", y: 0.1),
            Self.line("有效期 2026.08.12-2036.08.12", y: 0.2)
        ])
        let permitSuggestion = CredentialOCRParser.parse(
            permitResult,
            for: .hongKongMacaoPermit,
            calendar: Self.calendar
        )
        var permit = CredentialDocument(type: .hongKongMacaoPermit)
        permit.applyOCRSuggestion(permitSuggestion, calendar: Self.calendar)
        #expect(permit.validity.kind == .tenYears)
        #expect(permit.expirationDate(calendar: Self.calendar) == Self.date(year: 2036, month: 8, day: 12))

        let passportWithAnniversaryResult = OCRResult(lines: [
            Self.line("签发日期 2026.08.12", y: 0.1),
            Self.line("有效期 2026.08.12-2036.08.12", y: 0.2)
        ])
        let passportWithAnniversarySuggestion = CredentialOCRParser.parse(
            passportWithAnniversaryResult,
            for: .passport,
            calendar: Self.calendar
        )
        var passportWithAnniversary = CredentialDocument(type: .passport)
        passportWithAnniversary.applyOCRSuggestion(
            passportWithAnniversarySuggestion,
            calendar: Self.calendar
        )
        #expect(passportWithAnniversary.validity.kind == .dateRange)
        #expect(passportWithAnniversary.issuedAt == start)
        #expect(
            passportWithAnniversary.validity.endDate
                == Self.date(year: 2036, month: 8, day: 12)
        )
    }

    @Test func birthDateUsesCustomFieldsInsteadOfBasicInformation() {
        let result = OCRResult(lines: [Self.line("出生日期 1990.01.02", y: 0.1)])
        let suggestion = CredentialOCRParser.parse(
            result,
            for: .propertyOwnershipCertificate,
            calendar: Self.calendar
        )
        #expect(
            suggestion.fieldValues["出生日期"]
                == AppDateFormatter.string(from: Self.date(year: 1990, month: 1, day: 2))
        )

        var propertyDocument = CredentialDocument(type: .propertyOwnershipCertificate)
        propertyDocument.applyOCRSuggestion(suggestion, calendar: Self.calendar)
        #expect(propertyDocument.fields.first { $0.label == "出生日期" }?.value != nil)
    }

    @Test func versionsAndGroupsPreferTheFarthestExpirationDate() throws {
        var earlier = CredentialDocument(
            title: "身份证",
            type: .identityCard,
            issuedAt: Self.date(year: 2020, month: 1, day: 1),
            validity: CredentialValidity(kind: .tenYears)
        )
        earlier.createdAt = Self.date(year: 2020, month: 1, day: 1)
        var later = CredentialDocument(versionOf: earlier)
        later.issuedAt = Self.date(year: 2026, month: 1, day: 1)
        later.validity = CredentialValidity(kind: .tenYears)
        later.versionStatus = .lost
        let store = DocumentsStore(documents: [earlier, later], attachmentStore: AttachmentStore())

        let versions = store.versionGroup(for: earlier)

        #expect(versions.map(\.id) == [later.id, earlier.id])
        #expect(CredentialDocument.preferredVersion(in: versions)?.id == later.id)
        #expect(later.expirationDate(calendar: Self.calendar) == Self.date(year: 2036, month: 1, day: 1))
    }

    @Test func identityCardOCRProducesConfirmableFieldCandidates() throws {
        let result = OCRResult(lines: [
            Self.line("姓名 张三", y: 0.1),
            Self.line("性别 男 民族 汉", y: 0.2),
            Self.line("住址 北京市东城区", y: 0.3),
            Self.line("示例路1号", y: 0.35),
            Self.line("公民身份号码 11010119900102123X", y: 0.4),
            Self.line("签发机关 北京市公安局东城分局", y: 0.5),
            Self.line("有效期限 2020.01.02-2040.01.02", y: 0.6),
            Self.line("签发次数：02", y: 0.7)
        ])

        let suggestion = CredentialOCRParser.parse(
            result,
            for: .identityCard,
            calendar: Self.calendar
        )

        #expect(suggestion.holderName == "张三")
        #expect(suggestion.documentNumber == "11010119900102123X")
        #expect(
            suggestion.fieldValues["出生日期"]
                == AppDateFormatter.string(from: Self.date(year: 1990, month: 1, day: 2))
        )
        #expect(suggestion.issuingAuthority == "北京市公安局东城分局")
        #expect(suggestion.validityStart == Self.date(year: 2020, month: 1, day: 2))
        #expect(suggestion.validityEnd == Self.date(year: 2040, month: 1, day: 2))
        #expect(suggestion.issuedAt == Self.date(year: 2020, month: 1, day: 2))
        #expect(suggestion.fieldValues["性别"] == "男")
        #expect(suggestion.fieldValues["民族"] == "汉")
        #expect(suggestion.fieldValues["住址"] == "北京市东城区示例路1号")
        #expect(suggestion.fieldValues["签发次数"] == "02")

        var document = CredentialDocument(type: .identityCard)
        document.applyOCRSuggestion(suggestion, calendar: Self.calendar)

        #expect(document.holderName == "张三")
        #expect(document.fields.first { $0.label == "性别" }?.value == "男")
        #expect(document.fields.first { $0.label == "民族" }?.value == "汉")
        #expect(document.fields.first { $0.label == "住址" }?.value == "北京市东城区示例路1号")
        #expect(document.fields.first { $0.label == "出生日期" }?.value == suggestion.fieldValues["出生日期"])
        #expect(document.fields.first { $0.label == "签发次数" }?.value == "02")
        #expect(document.validity.kind == .twentyYears)
        #expect(document.expirationDate(calendar: Self.calendar) == suggestion.validityEnd)
    }

    @Test func storeNormalizesDataOwnsAttachmentsAndCancelsNotificationsWhenDisabled() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("DocumentsTests-\(UUID().uuidString)", isDirectory: true)
        let attachmentStore = AttachmentStore(fileManager: fileManager, directoryURL: directoryURL)
        defer { try? fileManager.removeItem(at: directoryURL) }
        let scheduler = RecordingLocalNotificationScheduler()
        let defaults = UserDefaults(suiteName: "DocumentsTests.\(UUID().uuidString)")!
        let settings = ToolModuleSettings(defaults: defaults)
        let retained = try attachmentStore.save(
            data: Data("retained".utf8),
            originalFileName: "front.jpg",
            contentType: .jpeg
        )
        let removed = try attachmentStore.save(
            data: Data("removed".utf8),
            originalFileName: "back.jpg",
            contentType: .jpeg
        )
        let endDate = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 200, to: Date())!
        var original = CredentialDocument(
            title: "Original",
            attachments: [
                CredentialAttachment(file: retained, role: .front),
                CredentialAttachment(file: removed, role: .back)
            ],
            expiryReminder: CredentialExpiryReminder(isEnabled: true, daysBefore: 30)
        )
        original.validity = CredentialValidity(kind: .dateRange, endDate: endDate)
        let store = DocumentsStore(
            documents: [original],
            attachmentStore: attachmentStore,
            notificationScheduler: scheduler,
            moduleSettings: settings
        )
        var edited = original
        edited.title = "  我的护照  "
        edited.documentNumber = "  e12345678  "
        edited.tags = [" 旅行 ", "旅行", "  "]
        edited.attachments = [CredentialAttachment(file: retained, role: .front)]

        store.upsert(edited)

        let stored = try #require(store.documents.first)
        #expect(stored.title == "我的护照")
        #expect(stored.documentNumber == "E12345678")
        #expect(stored.tags == ["旅行"])
        #expect(fileManager.fileExists(atPath: attachmentStore.url(for: retained).path))
        #expect(!fileManager.fileExists(atPath: attachmentStore.url(for: removed).path))
        #expect(scheduler.latestNotifications.count == 1)

        store.moduleDidChange(.documents, isEnabled: false)

        #expect(scheduler.latestNotifications.isEmpty)
        #expect(scheduler.latestPrefix == DocumentsStore.notificationIdentifierPrefix)
    }

    @Test func cleanupRemovesOnlyFieldsThatDoNotApplyToTheDocumentType() throws {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        var property = CredentialDocument(
            type: .propertyOwnershipCertificate,
            customTypeName: "旧自定义名称",
            legacyDateOfBirth: staleDate,
            validity: CredentialValidity(
                kind: .unspecified,
                startDate: staleDate,
                endDate: staleDate
            ),
            expiryReminder: CredentialExpiryReminder(isEnabled: true, daysBefore: 30)
        )
        property.title = "房产证"
        var passport = CredentialDocument(
            type: .passport,
            validity: CredentialValidity(
                kind: .permanent,
                startDate: staleDate,
                endDate: staleDate
            )
        )
        passport.title = "长期护照"
        let store = DocumentsStore(
            documents: [property, passport],
            attachmentStore: AttachmentStore()
        )

        let report = RedundantDataCleanupReport(findings: store.scanRedundantData())
        store.cleanupRedundantData()

        #expect(report.findings.map(\.ruleID) == [
            "legacy-date-of-birth",
            "non-custom-type-name",
            "inapplicable-validity-dates",
            "unusable-expiry-reminder"
        ])
        #expect(report.affectedFieldCount == 6)
        let cleanedProperty = try #require(store.documents.first)
        #expect(cleanedProperty.legacyDateOfBirth == nil)
        #expect(
            cleanedProperty.fields.first { $0.label == "出生日期" }?.value
                == AppDateFormatter.string(from: staleDate)
        )
        #expect(!String(decoding: try JSONEncoder().encode(cleanedProperty), as: UTF8.self).contains("dateOfBirth"))
        #expect(cleanedProperty.customTypeName.isEmpty)
        #expect(cleanedProperty.validity.startDate == nil)
        #expect(cleanedProperty.validity.endDate == nil)
        #expect(!cleanedProperty.expiryReminder.isEnabled)
        let retainedPassport = try #require(store.documents.last)
        #expect(retainedPassport.validity.startDate == staleDate)
        #expect(retainedPassport.validity.endDate == nil)
    }

    @Test func vaultWithoutDocumentsDecodesAsEmpty() throws {
        let vault = try JSONDecoder().decode(VaultData.self, from: Data("{}".utf8))
        #expect(vault.credentialDocuments.isEmpty)
    }

    @Test func existingDocumentWithoutVersionFieldsDecodesAsNormalRoot() throws {
        let source = Data(#"{"credentialDocuments":[{"title":"旧身份证"}]}"#.utf8)
        let vault = try JSONDecoder().decode(VaultData.self, from: source)
        let document = try #require(vault.credentialDocuments.first)

        #expect(document.displayTitle == "旧身份证")
        #expect(document.parentDocumentID == nil)
        #expect(document.versionStatus == .normal)
        #expect(document.fields.map(\.label) == ["性别", "民族", "住址"])
    }

    @Test func versionCreationAndRootDeletionKeepTheGroupAndAttachmentsConsistent() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("DocumentVersions-\(UUID().uuidString)", isDirectory: true)
        let attachmentStore = AttachmentStore(fileManager: fileManager, directoryURL: directoryURL)
        defer { try? fileManager.removeItem(at: directoryURL) }
        let rootFile = try attachmentStore.save(
            data: Data("root".utf8),
            originalFileName: "root.jpg",
            contentType: .jpeg
        )
        let versionFile = try attachmentStore.save(
            data: Data("version".utf8),
            originalFileName: "version.jpg",
            contentType: .jpeg
        )
        var root = CredentialDocument(
            title: "我的护照",
            holderName: "张三",
            attachments: [CredentialAttachment(file: rootFile)]
        )
        root.fields[0].value = "男"
        var version = CredentialDocument(versionOf: root)
        version.versionStatus = .lost
        version.attachments = [CredentialAttachment(file: versionFile)]
        let store = DocumentsStore(
            documents: [root, version],
            attachmentStore: attachmentStore
        )

        #expect(version.parentDocumentID == root.id)
        #expect(version.documentNumber.isEmpty)
        #expect(version.fields.first?.value == "男")
        #expect(store.versionGroup(for: version).map(\.id).contains(root.id))

        store.delete(ids: [root.id])

        #expect(store.documents.isEmpty)
        #expect(!fileManager.fileExists(atPath: attachmentStore.url(for: rootFile).path))
        #expect(!fileManager.fileExists(atPath: attachmentStore.url(for: versionFile).path))
    }

    @Test func backupRestoresDocumentAttachmentsOnlyInsideModuleBoundary() async throws {
        let attachmentStore = AttachmentStore()
        let payload = Data("credential-image".utf8)
        let file = try attachmentStore.save(
            data: payload,
            originalFileName: "credential.jpg",
            contentType: .jpeg
        )
        defer { attachmentStore.delete(file) }
        let document = CredentialDocument(
            title: "身份证",
            attachments: [CredentialAttachment(file: file, role: .front)]
        )
        let processor = AppStoreBackupProcessor()

        let backup = try await processor.makeBackup(
            vault: VaultData(credentialDocuments: [document]),
            secrets: [],
            includedModules: [.documents],
            password: "test-password"
        )
        attachmentStore.delete(file)
        let restored = try await processor.restorePayload(
            from: backup,
            password: "test-password",
            enabledModules: [.documents]
        )

        let restoredFile = try #require(restored.vault.credentialDocuments.first?.attachments.first?.file)
        #expect(restored.includedModules == [.documents])
        #expect(try attachmentStore.data(for: restoredFile) == payload)
        #expect(restoredFile.backupData == nil)

        let excluded = try await processor.restorePayload(
            from: backup,
            password: "test-password",
            enabledModules: [.personalFinance]
        )
        #expect(excluded.includedModules.isEmpty)
        #expect(excluded.vault.credentialDocuments.isEmpty)
    }

    @Test func cloudSnapshotAndMergeRespectDocumentsModuleBoundary() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("DocumentsCloudTests-\(UUID().uuidString)", isDirectory: true)
        let attachmentStore = AttachmentStore(fileManager: fileManager, directoryURL: directoryURL)
        defer { try? fileManager.removeItem(at: directoryURL) }
        let file = try attachmentStore.save(
            data: Data("cloud-document".utf8),
            originalFileName: "document.pdf",
            contentType: .pdf
        )
        var fileWithBackup = file
        fileWithBackup.backupData = Data([1, 2, 3])
        let local = CredentialDocument(
            title: "本地证照",
            attachments: [CredentialAttachment(file: fileWithBackup, role: .scan)]
        )
        let snapshot = try CloudSyncSnapshotBuilder.make(
            vault: VaultData(credentialDocuments: [local]),
            secrets: [],
            attachmentStore: attachmentStore,
            enabledModules: [.documents]
        )
        let documentItem = try #require(snapshot.items.first { $0.kind == .credentialDocument })
        let attachmentItem = try #require(snapshot.items.first { $0.kind == .attachment })
        let synced = try CloudSyncCoding.decoder().decode(
            CredentialDocument.self,
            from: documentItem.payload
        )

        #expect(documentItem.module == .documents)
        #expect(attachmentItem.module == .documents)
        #expect(synced.attachments.first?.file.backupData == nil)

        var remote = local
        remote.title = "远端证照"
        let remotePayload = try CloudSyncCoding.encoder().encode(remote)
        let ignored = try CloudSyncMerger.apply(
            [.upsert(kind: .credentialDocument, id: remote.id, payload: remotePayload)],
            to: VaultData(credentialDocuments: [local]),
            secrets: [],
            enabledModules: [.personalFinance]
        )
        #expect(ignored.vault.credentialDocuments == [local])
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func line(_ text: String, y: CGFloat) -> OCRRecognizedLine {
        OCRRecognizedLine(
            text: text,
            confidence: 1,
            boundingBox: OCRNormalizedRegion(x: 0, y: y, width: 1, height: 0.05)
        )
    }
}

@MainActor
private final class RecordingLocalNotificationScheduler: LocalNotificationScheduling {
    private(set) var latestNotifications: [ScheduledLocalNotification] = []
    private(set) var latestPrefix = ""

    func replaceScheduledNotifications(
        _ notifications: [ScheduledLocalNotification],
        identifierPrefix: String
    ) {
        latestNotifications = notifications
        latestPrefix = identifierPrefix
    }
}

#endif
