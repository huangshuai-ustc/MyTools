import Foundation
import Testing
import UniformTypeIdentifiers
import CryptoKit
@testable import MyTools

struct AppStoreBackupProcessorTests {
    @Test func backupRoundTripIncludesOnlySelectedModules() async throws {
        var account = FinancialInstitution()
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
        #expect(payload.vault.financialInstitutions.isEmpty)
        #expect(payload.vault.stocks.map(\.symbol) == ["TEST"])
        #expect(payload.vault.medicalRecords.isEmpty)
        #expect(payload.secrets.map(\.title) == ["Example Secret"])
    }

    @Test func binaryBackupHasNoBase64AndRejectsTamperedHeader() throws {
        var stock = StockHolding()
        stock.symbol = "TEST"
        let attachmentID = UUID()
        let blob = Data((0..<4_096).map { UInt8($0 % 251) })
        let data = try VaultBackupCrypto.makeBackup(
            from: VaultData(stocks: [stock]), includedModules: [.myStocks],
            attachmentData: [attachmentID: blob], password: "test-password"
        )
        let withoutAttachment = try VaultBackupCrypto.makeBackup(
            from: VaultData(stocks: [stock]), includedModules: [.myStocks], password: "test-password"
        )
        #expect(data.starts(with: Data("MTVB".utf8)))
        #expect(data[4] == 3)
        // Each attachment costs its raw bytes plus id and length, not base64.
        #expect(data.count - withoutAttachment.count == 16 + 8 + blob.count)
        let restored = try VaultBackupCrypto.restorePayload(from: data, password: "test-password")
        #expect(restored.vault.stocks.map(\.symbol) == ["TEST"])
        #expect(restored.attachmentData == [attachmentID: blob])

        // The header is authenticated: lowering the rounds fails like a wrong password.
        var weakened = data
        weakened[8] ^= 0x01
        #expect(throws: VaultBackupError.wrongPassword) {
            try VaultBackupCrypto.restorePayload(from: weakened, password: "test-password")
        }
        var unknown = data
        unknown[4] = 9
        #expect(throws: VaultBackupError.unsupportedVersion) {
            try VaultBackupCrypto.restorePayload(from: unknown, password: "test-password")
        }
        #expect(throws: VaultBackupError.invalidFile) {
            try VaultBackupCrypto.restorePayload(from: data.prefix(30), password: "test-password")
        }
    }

    @Test func jsonVersionTwoBackupStillRestores() throws {
        let password = "test-password"
        let salt = Data(repeating: 5, count: 16)
        let rounds = 100_000
        let key = SymmetricKey(data: try VaultCrypto.pbkdf2SHA256(
            password: Data(password.utf8), salt: salt, rounds: UInt32(rounds), keyLength: 32
        ))
        var stock = StockHolding()
        stock.symbol = "V2"
        let payload = try JSONEncoder().encode(
            VaultBackupPayload(vault: VaultData(stocks: [stock]), includedModules: [.myStocks])
        )
        let aad = Data("mytools-vault|2.0|\(rounds)".utf8)
        let combined = try #require(try AES.GCM.seal(payload, using: key, authenticating: aad).combined)
        var object: [String: Any] = [
            "format": "mytools-vault", "version": "2.0", "rounds": rounds,
            "salt": salt.base64EncodedString(), "combined": combined.base64EncodedString(),
        ]
        let envelope = try JSONSerialization.data(withJSONObject: object)

        let restored = try VaultBackupCrypto.restorePayload(from: envelope, password: password)
        #expect(restored.vault.stocks.map(\.symbol) == ["V2"])

        object["rounds"] = 1
        #expect(throws: VaultBackupError.invalidFile) {
            try VaultBackupCrypto.restorePayload(
                from: JSONSerialization.data(withJSONObject: object), password: password
            )
        }
    }

    @Test func legacyVersionOneBackupStillRestores() throws {
        let password = "test-password"
        let salt = Data(repeating: 3, count: 16)
        let key = SymmetricKey(data: try VaultCrypto.pbkdf2SHA256(
            password: Data(password.utf8), salt: salt, rounds: 210_000, keyLength: 32
        ))
        var stock = StockHolding()
        stock.symbol = "LEGACY"
        let payload = try JSONEncoder().encode(
            VaultBackupPayload(vault: VaultData(stocks: [stock]), includedModules: [.myStocks])
        )
        let combined = try #require(try AES.GCM.seal(payload, using: key).combined)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "format": "mytools-vault", "version": "1.0",
            "salt": salt.base64EncodedString(), "combined": combined.base64EncodedString(),
        ])

        let restored = try VaultBackupCrypto.restorePayload(from: legacy, password: password)
        #expect(restored.vault.stocks.map(\.symbol) == ["LEGACY"])
    }

    @Test func backupOmitsTagsAndTemplatesOfExcludedModules() async throws {
        var vault = VaultData()
        vault.medicalRecordTags = ["体检"]
        vault.credentialTags = ["家庭"]
        vault.billTags = ["餐饮"]
        vault.secretTags = ["工作"]
        let processor = AppStoreBackupProcessor()

        let data = try await processor.makeBackup(
            vault: vault,
            secrets: [],
            includedModules: [.myStocks],
            password: "test-password"
        )
        // 直接解密，不经过导入时的模块过滤，确认备份文件本身不含这些数据。
        let payload = try VaultBackupCrypto.restorePayload(from: data, password: "test-password")

        #expect(payload.vault.medicalRecordTags.isEmpty)
        #expect(payload.vault.credentialTags.isEmpty)
        #expect(payload.vault.billTags.isEmpty)
        #expect(payload.vault.secretTags.isEmpty)
        #expect(payload.vault.domesticBankLoginFieldTemplates.isEmpty)
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
        let institution = FinancialInstitution()
        var card = BankCard()
        card.accountID = institution.id
        card.statements = [statement]
        let secret = SecretItem(
            title: "Attachment Secret",
            attachments: [secretAttachment]
        )
        let processor = AppStoreBackupProcessor()

        let backup = try await processor.makeBackup(
            vault: VaultData(accounts: [institution], cards: [card]),
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
