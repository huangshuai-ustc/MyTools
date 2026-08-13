import Foundation

struct AppStoreBackupProcessor: VaultBackupProcessing {
    func makeBackup(
        vault: VaultData,
        secrets: [SecretVaultValue],
        includedModules: Set<ToolModule>,
        password: String
    ) async throws -> Data {
        let includedModules = CompiledToolModules.available(from: includedModules)
            .intersection(ToolModuleCatalog.backupModules)
        return try await Task.detached(priority: .userInitiated) {
            let attachments = BackupAttachmentMapper(store: AttachmentStore())
            var snapshot = Self.snapshot(from: vault, includedModules: includedModules)
#if MYTOOLS_FEATURE_HEALTH
            snapshot.medicalRecords = try attachments.recordsForBackup(
                snapshot.medicalRecords
            )
#endif
#if MYTOOLS_FEATURE_FINANCE
            snapshot.cards = try attachments.cardsForBackup(snapshot.cards)
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
            snapshot.foodPlaces = try attachments.foodPlacesForBackup(snapshot.foodPlaces)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
            snapshot.credentialDocuments = try attachments.documentsForBackup(
                snapshot.credentialDocuments
            )
#endif
            let secretSnapshot = includedModules.contains(.secrets) ? secrets : []
#if MYTOOLS_FEATURE_SECRETS
            let embeddedSecrets = try attachments.secretsForBackup(secretSnapshot)
#else
            let embeddedSecrets = secretSnapshot
#endif
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
        password: String,
        enabledModules: Set<ToolModule> = ToolModuleCatalog.allModules
    ) async throws -> VaultBackupPayload {
        try await Task.detached(priority: .userInitiated) {
            let attachments = BackupAttachmentMapper(store: AttachmentStore())
            var payload = try VaultBackupCrypto.restorePayload(
                from: data,
                password: password
            )
            let modules = payload.includedModules.intersection(
                CompiledToolModules.available(from: enabledModules)
            ).intersection(ToolModuleCatalog.backupModules)
            payload = Self.snapshot(payload, includedModules: modules)
#if MYTOOLS_FEATURE_HEALTH
            if payload.includedModules.contains(.healthRecords) {
                payload.vault.medicalRecords = try attachments.restoreAttachments(
                    in: payload.vault.medicalRecords
                )
            }
#endif
#if MYTOOLS_FEATURE_FINANCE
            if payload.includedModules.contains(.personalFinance) {
                payload.vault.cards = try attachments.restoreAttachments(
                    in: payload.vault.cards
                )
            }
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
            if payload.includedModules.contains(.foodMap) {
                payload.vault.foodPlaces = try attachments.restoreAttachments(
                    in: payload.vault.foodPlaces
                )
            }
#endif
#if MYTOOLS_FEATURE_SECRETS
            if payload.includedModules.contains(.secrets) {
                payload.secrets = try attachments.restoreAttachments(
                    in: payload.secrets
                )
            }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
            if payload.includedModules.contains(.documents) {
                payload.vault.credentialDocuments = try attachments.restoreAttachments(
                    in: payload.vault.credentialDocuments
                )
            }
#endif
            return payload
        }.value
    }

    private static func snapshot(
        _ payload: VaultBackupPayload,
        includedModules: Set<ToolModule>
    ) -> VaultBackupPayload {
        VaultBackupPayload(
            vault: snapshot(from: payload.vault, includedModules: includedModules),
            secrets: includedModules.contains(.secrets) ? payload.secrets : [],
            includedModules: includedModules
        )
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
        if !includedModules.contains(.secrets) {
            snapshot.secretFieldTemplates = []
        }
        if !includedModules.contains(.currencyExchange) {
            snapshot.currencyExchangeRecords = []
            snapshot.currencyRateAlerts = []
        }
        if !includedModules.contains(.healthRecords) {
            snapshot.medicalRecords = []
            snapshot.hospitalProfiles = []
        }
        if !includedModules.contains(.foodMap) {
            snapshot.foodPlaces = []
        }
        if !includedModules.contains(.documents) {
            snapshot.credentialDocuments = []
        }
        if !includedModules.contains(.bills) {
            snapshot.billRecords = []
        }
        return snapshot
    }
}

private struct BackupAttachmentMapper {
    let store: AttachmentStore

#if MYTOOLS_FEATURE_HEALTH
    func recordsForBackup(_ records: [MedicalRecord]) throws -> [MedicalRecord] {
        try records.map { record in
            var copy = record
            copy.attachments = try copy.attachments.map(attachmentForBackup)
            return copy
        }
    }
#endif

#if MYTOOLS_FEATURE_FINANCE
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
#endif

#if MYTOOLS_FEATURE_SECRETS
    func secretsForBackup(_ secrets: [SecretVaultValue]) throws -> [SecretVaultValue] {
        try secrets.map { item in
            var copy = item
            copy.attachments = try copy.attachments.map(attachmentForBackup)
            return copy
        }
    }
#endif

#if MYTOOLS_FEATURE_FOOD_MAP
    func foodPlacesForBackup(_ places: [FoodPlace]) throws -> [FoodPlace] {
        try places.map { place in
            var copy = place
            copy.photos = try copy.photos.map(attachmentForBackup)
            return copy
        }
    }
#endif

#if MYTOOLS_FEATURE_DOCUMENTS
    func documentsForBackup(
        _ documents: [CredentialDocument]
    ) throws -> [CredentialDocument] {
        try documents.map { document in
            var copy = document
            copy.attachments = try copy.attachments.map { attachment in
                var attachment = attachment
                attachment.file = try attachmentForBackup(attachment.file)
                return attachment
            }
            return copy
        }
    }
#endif

#if MYTOOLS_FEATURE_HEALTH
    func restoreAttachments(in records: [MedicalRecord]) throws -> [MedicalRecord] {
        try records.map { record in
            var copy = record
            copy.attachments = try copy.attachments.map(restoredAttachment)
            return copy
        }
    }
#endif

#if MYTOOLS_FEATURE_FINANCE
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
#endif

#if MYTOOLS_FEATURE_SECRETS
    func restoreAttachments(in secrets: [SecretVaultValue]) throws -> [SecretVaultValue] {
        try secrets.map { item in
            var copy = item
            copy.attachments = try copy.attachments.map(restoredAttachment)
            return copy
        }
    }
#endif

#if MYTOOLS_FEATURE_FOOD_MAP
    func restoreAttachments(in places: [FoodPlace]) throws -> [FoodPlace] {
        try places.map { place in
            var copy = place
            copy.photos = try copy.photos.map(restoredAttachment)
            return copy
        }
    }
#endif

#if MYTOOLS_FEATURE_DOCUMENTS
    func restoreAttachments(
        in documents: [CredentialDocument]
    ) throws -> [CredentialDocument] {
        try documents.map { document in
            var copy = document
            copy.attachments = try copy.attachments.map { attachment in
                var attachment = attachment
                attachment.file = try restoredAttachment(attachment.file)
                return attachment
            }
            return copy
        }
    }
#endif

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
