import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MyTools

struct AppStoreBackupProcessorTests {
    @Test func backupRoundTripIncludesOnlySelectedModules() async throws {
        var account = BankAccount()
        account.bankName = "Example Bank"
        var stock = StockHolding()
        stock.symbol = "TEST"
        var medicalRecord = MedicalRecord()
        medicalRecord.hospital = "Example Hospital"
        var secret = SecretItem()
        secret.title = "Example Secret"
        let vault = VaultData(
            accounts: [account],
            stocks: [stock],
            medicalRecords: [medicalRecord]
        )
        let processor = AppStoreBackupProcessor()

        let data = try await processor.makeBackup(
            vault: vault,
            secrets: [secret],
            includedModules: [.myStocks, .secrets],
            password: "test-password"
        )
        let payload = try await processor.restorePayload(
            from: data,
            password: "test-password"
        )

        #expect(payload.includedModules == [.myStocks, .secrets])
        #expect(payload.vault.accounts.isEmpty)
        #expect(payload.vault.stocks.map(\.symbol) == ["TEST"])
        #expect(payload.vault.medicalRecords.isEmpty)
        #expect(payload.secrets.map(\.title) == ["Example Secret"])
    }

    @Test func financeAndSecretAttachmentsSurviveBackupRestore() async throws {
        let attachmentStore = AttachmentStore()
        let statementData = Data("statement-pdf".utf8)
        let secretData = Data("secret-image".utf8)
        let statementAttachment = try attachmentStore.save(
            data: statementData,
            originalFileName: "statement.pdf",
            contentType: .pdf
        )
        let secretAttachment = try attachmentStore.save(
            data: secretData,
            originalFileName: "secret.jpg",
            contentType: .jpeg
        )
        defer {
            attachmentStore.delete(statementAttachment)
            attachmentStore.delete(secretAttachment)
        }
        var statement = CreditCardStatement()
        statement.attachment = statementAttachment
        var card = BankCard()
        card.statements = [statement]
        let secret = SecretItem(
            title: "Attachment Secret",
            attachments: [secretAttachment]
        )
        let processor = AppStoreBackupProcessor()

        let backup = try await processor.makeBackup(
            vault: VaultData(cards: [card]),
            secrets: [secret],
            includedModules: [.personalFinance, .secrets],
            password: "test-password"
        )
        attachmentStore.delete(statementAttachment)
        attachmentStore.delete(secretAttachment)

        let payload = try await processor.restorePayload(
            from: backup,
            password: "test-password"
        )
        let restoredStatement = try #require(
            payload.vault.cards.first?.statements.first?.attachment
        )
        let restoredSecret = try #require(payload.secrets.first?.attachments.first)
        defer {
            attachmentStore.delete(restoredStatement)
            attachmentStore.delete(restoredSecret)
        }

        #expect(try attachmentStore.data(for: restoredStatement) == statementData)
        #expect(try attachmentStore.data(for: restoredSecret) == secretData)
        #expect(restoredStatement.backupData == nil)
        #expect(restoredSecret.backupData == nil)
    }

    @Test func disabledModuleAttachmentsAreFilteredBeforeRestore() async throws {
        let attachmentStore = AttachmentStore()
        let attachment = try attachmentStore.save(
            data: Data("health-report".utf8),
            originalFileName: "health.pdf",
            contentType: .pdf
        )
        defer { attachmentStore.delete(attachment) }

        var record = MedicalRecord()
        record.attachments = [attachment]
        let processor = AppStoreBackupProcessor()
        let backup = try await processor.makeBackup(
            vault: VaultData(medicalRecords: [record]),
            secrets: [],
            includedModules: [.healthRecords],
            password: "test-password"
        )

        attachmentStore.delete(attachment)
        let payload = try await processor.restorePayload(
            from: backup,
            password: "test-password",
            enabledModules: [.personalFinance]
        )

        #expect(payload.includedModules.isEmpty)
        #expect(payload.vault.medicalRecords.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: attachmentStore.url(for: attachment).path))
    }
}
