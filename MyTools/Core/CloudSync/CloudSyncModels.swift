import Foundation

enum CloudSyncEntityKind: String, Codable, CaseIterable, Sendable {
    case bankAccount
    case bankCard
    case stockHolding
    case currencyExchangeRecord
    case medicalRecord
    case hospitalProfile
    case currencyRateAlert
    case stockPriceAlert
    case secretItem
    case attachment
    case appPreferences
}

struct CloudSyncItem: Sendable {
    let kind: CloudSyncEntityKind
    let id: UUID
    let payload: Data
    let assetURL: URL?

    var key: String {
        Self.key(kind: kind, id: id)
    }

    static func key(kind: CloudSyncEntityKind, id: UUID) -> String {
        "\(kind.rawValue).\(id.uuidString.lowercased())"
    }
}

struct CloudSyncSnapshot: Sendable {
    let items: [CloudSyncItem]

    static let empty = CloudSyncSnapshot(items: [])
}

enum CloudSyncChange: Sendable {
    case upsert(kind: CloudSyncEntityKind, id: UUID, payload: Data)
    case delete(kind: CloudSyncEntityKind, id: UUID)
}

struct CloudSyncMergeResult: @unchecked Sendable {
    let vault: VaultData
    let secrets: [SecretItem]
}

enum CloudSyncCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

enum CloudSyncSnapshotBuilder {
    static func make(
        vault: VaultData,
        secrets: [SecretItem],
        attachmentStore: AttachmentStore,
        appPreferences: CloudSyncAppPreferences? = nil
    ) throws -> CloudSyncSnapshot {
        let encoder = CloudSyncCoding.encoder()
        var items: [CloudSyncItem] = []

        try append(vault.accounts, kind: .bankAccount, encoder: encoder, to: &items)
        try append(
            vault.cards.map(metadataOnlyCard),
            kind: .bankCard,
            encoder: encoder,
            to: &items
        )
        try append(
            vault.stocks.map(portfolioOnlyStock),
            kind: .stockHolding,
            encoder: encoder,
            to: &items
        )
        try append(
            vault.currencyExchangeRecords,
            kind: .currencyExchangeRecord,
            encoder: encoder,
            to: &items
        )
        try append(
            vault.medicalRecords.map(metadataOnlyMedicalRecord),
            kind: .medicalRecord,
            encoder: encoder,
            to: &items
        )
        try append(vault.hospitalProfiles, kind: .hospitalProfile, encoder: encoder, to: &items)
        try append(vault.currencyRateAlerts, kind: .currencyRateAlert, encoder: encoder, to: &items)
        try append(vault.stockPriceAlerts, kind: .stockPriceAlert, encoder: encoder, to: &items)
        try append(
            secrets.map(metadataOnlySecret),
            kind: .secretItem,
            encoder: encoder,
            to: &items
        )

        if let appPreferences {
            items.append(
                CloudSyncItem(
                    kind: .appPreferences,
                    id: CloudSyncAppPreferences.itemID,
                    payload: try encoder.encode(appPreferences),
                    assetURL: nil
                )
            )
        }

        for attachment in uniqueAttachments(vault: vault, secrets: secrets) {
            var metadata = attachment
            metadata.backupData = nil
            items.append(
                CloudSyncItem(
                    kind: .attachment,
                    id: metadata.id,
                    payload: try encoder.encode(metadata),
                    assetURL: attachmentStore.url(for: metadata)
                )
            )
        }

        return CloudSyncSnapshot(items: items)
    }

    private static func append<T: Encodable & Identifiable>(
        _ values: [T],
        kind: CloudSyncEntityKind,
        encoder: JSONEncoder,
        to items: inout [CloudSyncItem]
    ) throws where T.ID == UUID {
        for value in values {
            items.append(
                CloudSyncItem(
                    kind: kind,
                    id: value.id,
                    payload: try encoder.encode(value),
                    assetURL: nil
                )
            )
        }
    }

    private static func portfolioOnlyStock(_ stock: StockHolding) -> StockHolding {
        var result = stock
        result.latestPrice = nil
        result.previousClose = nil
        result.changePercent = nil
        result.quoteName = ""
        result.lastQuoteAt = nil
        return result
    }

    private static func metadataOnlyCard(_ card: BankCard) -> BankCard {
        var result = card
        result.statements = card.statements.map { statement in
            var result = statement
            result.attachment = statement.attachment.map(metadataOnlyAttachment)
            return result
        }
        return result
    }

    private static func metadataOnlyMedicalRecord(_ record: MedicalRecord) -> MedicalRecord {
        var result = record
        result.attachments = record.attachments.map(metadataOnlyAttachment)
        return result
    }

    private static func metadataOnlySecret(_ secret: SecretItem) -> SecretItem {
        var result = secret
        result.attachments = secret.attachments.map(metadataOnlyAttachment)
        return result
    }

    private static func metadataOnlyAttachment(_ attachment: FileAttachment) -> FileAttachment {
        var result = attachment
        result.backupData = nil
        return result
    }

    private static func uniqueAttachments(
        vault: VaultData,
        secrets: [SecretItem]
    ) -> [FileAttachment] {
        let cardAttachments = vault.cards.flatMap(\.statements).compactMap(\.attachment)
        let healthAttachments = vault.medicalRecords.flatMap(\.attachments)
        let secretAttachments = secrets.flatMap(\.attachments)
        return (cardAttachments + healthAttachments + secretAttachments).reduce(into: [:]) {
            result, attachment in
            result[attachment.id] = attachment
        }.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

enum CloudSyncMerger {
    static func apply(
        _ changes: [CloudSyncChange],
        to vault: VaultData,
        secrets: [SecretItem]
    ) throws -> CloudSyncMergeResult {
        var vault = vault
        var secrets = secrets
        let decoder = CloudSyncCoding.decoder()

        for change in changes {
            switch change {
            case .upsert(let kind, _, let payload):
                switch kind {
                case .bankAccount:
                    try upsert(decoder.decode(BankAccount.self, from: payload), in: &vault.accounts)
                case .bankCard:
                    try upsert(decoder.decode(BankCard.self, from: payload), in: &vault.cards)
                case .stockHolding:
                    var incoming = try decoder.decode(StockHolding.self, from: payload)
                    if let local = vault.stocks.first(where: { $0.id == incoming.id }) {
                        incoming.latestPrice = local.latestPrice
                        incoming.previousClose = local.previousClose
                        incoming.changePercent = local.changePercent
                        incoming.quoteName = local.quoteName
                        incoming.lastQuoteAt = local.lastQuoteAt
                    }
                    upsert(incoming, in: &vault.stocks)
                case .currencyExchangeRecord:
                    try upsert(
                        decoder.decode(CurrencyExchangeRecord.self, from: payload),
                        in: &vault.currencyExchangeRecords
                    )
                case .medicalRecord:
                    try upsert(decoder.decode(MedicalRecord.self, from: payload), in: &vault.medicalRecords)
                case .hospitalProfile:
                    try upsert(
                        decoder.decode(HospitalProfile.self, from: payload),
                        in: &vault.hospitalProfiles
                    )
                case .currencyRateAlert:
                    try upsert(
                        decoder.decode(CurrencyRateAlert.self, from: payload),
                        in: &vault.currencyRateAlerts
                    )
                case .stockPriceAlert:
                    try upsert(
                        decoder.decode(StockPriceAlert.self, from: payload),
                        in: &vault.stockPriceAlerts
                    )
                case .secretItem:
                    try upsert(decoder.decode(SecretItem.self, from: payload), in: &secrets)
                case .attachment:
                    break
                case .appPreferences:
                    break
                }

            case .delete(let kind, let id):
                switch kind {
                case .bankAccount: vault.accounts.removeAll { $0.id == id }
                case .bankCard: vault.cards.removeAll { $0.id == id }
                case .stockHolding: vault.stocks.removeAll { $0.id == id }
                case .currencyExchangeRecord: vault.currencyExchangeRecords.removeAll { $0.id == id }
                case .medicalRecord: vault.medicalRecords.removeAll { $0.id == id }
                case .hospitalProfile: vault.hospitalProfiles.removeAll { $0.id == id }
                case .currencyRateAlert: vault.currencyRateAlerts.removeAll { $0.id == id }
                case .stockPriceAlert: vault.stockPriceAlerts.removeAll { $0.id == id }
                case .secretItem: secrets.removeAll { $0.id == id }
                case .attachment: break
                case .appPreferences: break
                }
            }
        }

        return CloudSyncMergeResult(vault: vault, secrets: secrets)
    }

    private static func upsert<T: Identifiable>(_ value: T, in values: inout [T])
    where T.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }
}
