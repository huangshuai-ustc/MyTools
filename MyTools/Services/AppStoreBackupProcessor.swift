import Foundation

struct AppStoreBackupProcessor: VaultBackupProcessing {
    func makeBackup(
        vault: VaultData,
        secrets: [SecretItem],
        includedModules: Set<ToolModule>,
        password: String
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let attachments = BackupAttachmentMapper(store: AttachmentStore())
            var snapshot = Self.snapshot(from: vault, includedModules: includedModules)
            snapshot.medicalRecords = try attachments.recordsForBackup(
                snapshot.medicalRecords
            )
            snapshot.cards = try attachments.cardsForBackup(snapshot.cards)
            let secretSnapshot = includedModules.contains(.secrets) ? secrets : []
            let embeddedSecrets = try attachments.secretsForBackup(secretSnapshot)
            return try VaultBackupCrypto.makeBackup(
                from: snapshot,
                secrets: embeddedSecrets,
                includedModules: includedModules,
                password: password
            )
        }.value
    }

    func restorePayload(
        from data: Data,
        password: String
    ) async throws -> VaultBackupPayload {
        try await Task.detached(priority: .userInitiated) {
            let attachments = BackupAttachmentMapper(store: AttachmentStore())
            var payload = try VaultBackupCrypto.restorePayload(
                from: data,
                password: password
            )
            if payload.includedModules.contains(.healthRecords) {
                payload.vault.medicalRecords = try attachments.restoreAttachments(
                    in: payload.vault.medicalRecords
                )
            }
            if payload.includedModules.contains(.personalFinance) {
                payload.vault.cards = try attachments.restoreAttachments(
                    in: payload.vault.cards
                )
            }
            if payload.includedModules.contains(.secrets) {
                payload.secrets = try attachments.restoreAttachments(
                    in: payload.secrets
                )
            }
            return payload
        }.value
    }

    private static func snapshot(
        from vault: VaultData,
        includedModules: Set<ToolModule>
    ) -> VaultData {
        var snapshot = vault
        if !includedModules.contains(.personalFinance) {
            snapshot.accounts = []
            snapshot.cards = []
        }
        if !includedModules.contains(.myStocks) {
            snapshot.stocks = []
            snapshot.stockPriceAlerts = []
        }
        if !includedModules.contains(.currencyExchange) {
            snapshot.currencyExchangeRecords = []
            snapshot.currencyRateAlerts = []
        }
        if !includedModules.contains(.healthRecords) {
            snapshot.medicalRecords = []
            snapshot.hospitalProfiles = []
        }
        return snapshot
    }
}

private struct BackupAttachmentMapper {
    let store: AttachmentStore

    func recordsForBackup(_ records: [MedicalRecord]) throws -> [MedicalRecord] {
        try records.map { record in
            var copy = record
            copy.attachments = try copy.attachments.map(attachmentForBackup)
            return copy
        }
    }

    func cardsForBackup(_ cards: [BankCard]) throws -> [BankCard] {
        try cards.map { card in
            var copy = card
            for index in copy.statements.indices {
                guard let attachment = copy.statements[index].attachment else { continue }
                copy.statements[index].attachment = try attachmentForBackup(attachment)
            }
            return copy
        }
    }

    func secretsForBackup(_ secrets: [SecretItem]) throws -> [SecretItem] {
        try secrets.map { item in
            var copy = item
            copy.attachments = try copy.attachments.map(attachmentForBackup)
            return copy
        }
    }

    func restoreAttachments(in records: [MedicalRecord]) throws -> [MedicalRecord] {
        try records.map { record in
            var copy = record
            copy.attachments = try copy.attachments.map(restoredAttachment)
            return copy
        }
    }

    func restoreAttachments(in cards: [BankCard]) throws -> [BankCard] {
        try cards.map { card in
            var copy = card
            for index in copy.statements.indices {
                guard let attachment = copy.statements[index].attachment else { continue }
                copy.statements[index].attachment = try restoredAttachment(attachment)
            }
            return copy
        }
    }

    func restoreAttachments(in secrets: [SecretItem]) throws -> [SecretItem] {
        try secrets.map { item in
            var copy = item
            copy.attachments = try copy.attachments.map(restoredAttachment)
            return copy
        }
    }

    private func attachmentForBackup(_ attachment: FileAttachment) throws -> FileAttachment {
        var copy = attachment
        copy.backupData = try store.data(for: attachment)
        return copy
    }

    private func restoredAttachment(_ attachment: FileAttachment) throws -> FileAttachment {
        guard let payload = attachment.backupData else { return attachment }
        try store.write(payload, to: attachment)
        var copy = attachment
        copy.fileSize = Int64(payload.count)
        copy.backupData = nil
        return copy
    }
}
