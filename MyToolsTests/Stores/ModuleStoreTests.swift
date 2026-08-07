import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MyTools

@MainActor
struct ModuleStoreTests {
    @Test func financeStoreDeletesStatementsRemovedDuringAccountReplacement() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("MyToolsTests-(UUID().uuidString)", isDirectory: true)
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

    @Test func secretStoreRejectsMutationsWhileBackupRestoreIsInProgress() {
        let original = SecretItem(title: "Original")
        let store = SecretStore(
            secretItems: [original],
            attachmentStore: AttachmentStore()
        )
        var edited = original
        edited.title = "Changed"

        store.setBackupRestoreInProgress(true)
        store.upsertSecret(edited)
        store.deleteSecrets(ids: [original.id])

        #expect(store.secretItems.map(\.title) == ["Original"])

        store.setBackupRestoreInProgress(false)
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
