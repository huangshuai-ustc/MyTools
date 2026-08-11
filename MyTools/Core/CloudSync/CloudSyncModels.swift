import Foundation

enum CloudSyncEntityKind: String, Codable, CaseIterable, Sendable {
    case bankAccount
    case bankCard
    case stockHolding
    case currencyExchangeRecord
    case medicalRecord
    case hospitalProfile
    case foodPlace
    case currencyRateAlert
    case stockPriceAlert
    case secretItem
    case credentialDocument
    case billRecord
    case attachment
    case appPreferences

    var module: ToolModule? {
        switch self {
        case .bankAccount, .bankCard:
            .personalFinance
        case .stockHolding, .stockPriceAlert:
            .myStocks
        case .currencyExchangeRecord, .currencyRateAlert:
            .currencyExchange
        case .medicalRecord, .hospitalProfile:
            .healthRecords
        case .foodPlace:
            .foodMap
        case .secretItem:
            .secrets
        case .credentialDocument:
            .documents
        case .billRecord:
            .bills
        case .attachment, .appPreferences:
            nil
        }
    }

    func isIncluded(in modules: Set<ToolModule>) -> Bool {
        if let module {
            return modules.contains(module)
        }
        return self == .attachment || self == .appPreferences
    }
}

struct CloudSyncItem: Sendable {
    let kind: CloudSyncEntityKind
    let id: UUID
    let payload: Data
    let assetURL: URL?
    let module: ToolModule?

    var key: String {
        Self.key(kind: kind, id: id)
    }

    static func key(kind: CloudSyncEntityKind, id: UUID) -> String {
        "\(kind.rawValue).\(id.uuidString.lowercased())"
    }

    init(
        kind: CloudSyncEntityKind,
        id: UUID,
        payload: Data,
        assetURL: URL?,
        module: ToolModule? = nil
    ) {
        self.kind = kind
        self.id = id
        self.payload = payload
        self.assetURL = assetURL
        self.module = module ?? kind.module
    }
}

struct CloudSyncSnapshot: Sendable {
    let items: [CloudSyncItem]
    let participatingModules: Set<ToolModule>

    init(items: [CloudSyncItem], participatingModules: Set<ToolModule> = ToolModuleCatalog.allModules) {
        self.items = items
        self.participatingModules = CompiledToolModules.available(from: participatingModules)
    }

    static let empty = CloudSyncSnapshot(items: [])
}

enum CloudSyncChange: Sendable {
    case upsert(kind: CloudSyncEntityKind, id: UUID, payload: Data)
    case delete(kind: CloudSyncEntityKind, id: UUID)
}

struct CloudSyncMergeResult: @unchecked Sendable {
    let vault: VaultData
    let secrets: [SecretVaultValue]
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
        secrets: [SecretVaultValue],
        attachmentStore: AttachmentStore,
        appPreferences: CloudSyncAppPreferences? = nil,
        enabledModules: Set<ToolModule> = ToolModuleCatalog.allModules
    ) throws -> CloudSyncSnapshot {
        let enabledModules = CompiledToolModules.available(from: enabledModules)
        let encoder = CloudSyncCoding.encoder()
        var items: [CloudSyncItem] = []

#if MYTOOLS_FEATURE_FINANCE
        if enabledModules.contains(.personalFinance) {
            try append(vault.accounts, kind: .bankAccount, encoder: encoder, to: &items)
            try append(
                vault.cards.map(metadataOnlyCard),
                kind: .bankCard,
                encoder: encoder,
                to: &items
            )
        }
#endif
#if MYTOOLS_FEATURE_STOCKS
        if enabledModules.contains(.myStocks) {
            try append(
                vault.stocks.map(portfolioOnlyStock),
                kind: .stockHolding,
                encoder: encoder,
                to: &items
            )
            try append(vault.stockPriceAlerts, kind: .stockPriceAlert, encoder: encoder, to: &items)
        }
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        if enabledModules.contains(.currencyExchange) {
            try append(
                vault.currencyExchangeRecords,
                kind: .currencyExchangeRecord,
                encoder: encoder,
                to: &items
            )
            try append(vault.currencyRateAlerts, kind: .currencyRateAlert, encoder: encoder, to: &items)
        }
#endif
#if MYTOOLS_FEATURE_HEALTH
        if enabledModules.contains(.healthRecords) {
            try append(
                vault.medicalRecords.map(metadataOnlyMedicalRecord),
                kind: .medicalRecord,
                encoder: encoder,
                to: &items
            )
            try append(vault.hospitalProfiles, kind: .hospitalProfile, encoder: encoder, to: &items)
        }
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        if enabledModules.contains(.foodMap) {
            try append(
                vault.foodPlaces.map(metadataOnlyFoodPlace),
                kind: .foodPlace,
                encoder: encoder,
                to: &items
            )
        }
#endif
#if MYTOOLS_FEATURE_SECRETS
        if enabledModules.contains(.secrets) {
            try append(
                secrets.map(metadataOnlySecret),
                kind: .secretItem,
                encoder: encoder,
                to: &items
            )
        }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        if enabledModules.contains(.documents) {
            try append(
                vault.credentialDocuments.map(metadataOnlyCredentialDocument),
                kind: .credentialDocument,
                encoder: encoder,
                to: &items
            )
        }
#endif
#if MYTOOLS_FEATURE_BILLS
        if enabledModules.contains(.bills) {
            try append(vault.billRecords, kind: .billRecord, encoder: encoder, to: &items)
        }
#endif

        if let appPreferences {
            items.append(
                CloudSyncItem(
                    kind: .appPreferences,
                    id: CloudSyncAppPreferences.itemID,
                    payload: try encoder.encode(appPreferences),
                    assetURL: nil,
                    module: nil
                )
            )
        }

        for (attachment, module) in uniqueAttachments(
            vault: vault,
            secrets: secrets,
            enabledModules: enabledModules
        ) {
            var metadata = attachment
            metadata.backupData = nil
            items.append(
                CloudSyncItem(
                    kind: .attachment,
                    id: metadata.id,
                    payload: try encoder.encode(metadata),
                    assetURL: attachmentStore.url(for: metadata),
                    module: module
                )
            )
        }

        return CloudSyncSnapshot(items: items, participatingModules: enabledModules)
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

#if MYTOOLS_FEATURE_STOCKS
    private static func portfolioOnlyStock(_ stock: StockHolding) -> StockHolding {
        var result = stock
        result.latestPrice = nil
        result.previousClose = nil
        result.changePercent = nil
        result.quoteName = ""
        result.lastQuoteAt = nil
        return result
    }
#endif

#if MYTOOLS_FEATURE_FINANCE
    private static func metadataOnlyCard(_ card: BankCard) -> BankCard {
        var result = card
        result.statements = card.statements.map { statement in
            var result = statement
            result.attachment = statement.attachment.map(metadataOnlyAttachment)
            return result
        }
        return result
    }
#endif

#if MYTOOLS_FEATURE_HEALTH
    private static func metadataOnlyMedicalRecord(_ record: MedicalRecord) -> MedicalRecord {
        var result = record
        result.attachments = record.attachments.map(metadataOnlyAttachment)
        return result
    }
#endif

#if MYTOOLS_FEATURE_SECRETS
    private static func metadataOnlySecret(_ secret: SecretItem) -> SecretItem {
        var result = secret
        result.attachments = secret.attachments.map(metadataOnlyAttachment)
        return result
    }
#endif

#if MYTOOLS_FEATURE_FOOD_MAP
    private static func metadataOnlyFoodPlace(_ place: FoodPlace) -> FoodPlace {
        var result = place
        result.photos = place.photos.map(metadataOnlyAttachment)
        return result
    }
#endif

#if MYTOOLS_FEATURE_DOCUMENTS
    private static func metadataOnlyCredentialDocument(
        _ document: CredentialDocument
    ) -> CredentialDocument {
        var result = document
        result.attachments = document.attachments.map { attachment in
            var attachment = attachment
            attachment.file = metadataOnlyAttachment(attachment.file)
            return attachment
        }
        return result
    }
#endif

    private static func metadataOnlyAttachment(_ attachment: FileAttachment) -> FileAttachment {
        var result = attachment
        result.backupData = nil
        return result
    }

    private static func uniqueAttachments(
        vault: VaultData,
        secrets: [SecretVaultValue],
        enabledModules: Set<ToolModule>
    ) -> [(FileAttachment, ToolModule)] {
        var result: [UUID: (FileAttachment, ToolModule)] = [:]
#if MYTOOLS_FEATURE_FINANCE
        if enabledModules.contains(.personalFinance) {
            for attachment in vault.cards.flatMap(\.statements).compactMap(\.attachment) {
                result[attachment.id] = (attachment, .personalFinance)
            }
        }
#endif
#if MYTOOLS_FEATURE_HEALTH
        if enabledModules.contains(.healthRecords) {
            for attachment in vault.medicalRecords.flatMap(\.attachments) {
                result[attachment.id] = (attachment, .healthRecords)
            }
        }
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        if enabledModules.contains(.foodMap) {
            for attachment in vault.foodPlaces.flatMap(\.photos) {
                result[attachment.id] = (attachment, .foodMap)
            }
        }
#endif
#if MYTOOLS_FEATURE_SECRETS
        if enabledModules.contains(.secrets) {
            for attachment in secrets.flatMap(\.attachments) {
                result[attachment.id] = (attachment, .secrets)
            }
        }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        if enabledModules.contains(.documents) {
            for attachment in vault.credentialDocuments.flatMap(\.attachmentFiles) {
                result[attachment.id] = (attachment, .documents)
            }
        }
#endif
        return result.values.sorted { $0.0.id.uuidString < $1.0.id.uuidString }
    }
}

enum CloudSyncMerger {
    static func apply(
        _ changes: [CloudSyncChange],
        to vault: VaultData,
        secrets: [SecretVaultValue],
        enabledModules: Set<ToolModule> = ToolModuleCatalog.allModules
    ) throws -> CloudSyncMergeResult {
        var vault = vault
        var secrets = secrets
        let enabledModules = CompiledToolModules.available(from: enabledModules)
        let decoder = CloudSyncCoding.decoder()

        for change in changes {
            switch change {
            case .upsert(let kind, _, let payload):
                guard kind.isIncluded(in: enabledModules) else { continue }
                switch kind {
                case .bankAccount:
#if MYTOOLS_FEATURE_FINANCE
                    try upsert(decoder.decode(BankAccount.self, from: payload), in: &vault.accounts)
#endif
                    break
                case .bankCard:
#if MYTOOLS_FEATURE_FINANCE
                    try upsert(decoder.decode(BankCard.self, from: payload), in: &vault.cards)
#endif
                    break
                case .stockHolding:
#if MYTOOLS_FEATURE_STOCKS
                    var incoming = try decoder.decode(StockHolding.self, from: payload)
                    if let local = vault.stocks.first(where: { $0.id == incoming.id }) {
                        incoming.latestPrice = local.latestPrice
                        incoming.previousClose = local.previousClose
                        incoming.changePercent = local.changePercent
                        incoming.quoteName = local.quoteName
                        incoming.lastQuoteAt = local.lastQuoteAt
                    }
                    upsert(incoming, in: &vault.stocks)
#endif
                    break
                case .currencyExchangeRecord:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
                    try upsert(
                        decoder.decode(CurrencyExchangeRecord.self, from: payload),
                        in: &vault.currencyExchangeRecords
                    )
#endif
                    break
                case .medicalRecord:
#if MYTOOLS_FEATURE_HEALTH
                    try upsert(decoder.decode(MedicalRecord.self, from: payload), in: &vault.medicalRecords)
#endif
                    break
                case .hospitalProfile:
#if MYTOOLS_FEATURE_HEALTH
                    try upsert(
                        decoder.decode(HospitalProfile.self, from: payload),
                        in: &vault.hospitalProfiles
                    )
#endif
                    break
                case .foodPlace:
#if MYTOOLS_FEATURE_FOOD_MAP
                    try upsert(decoder.decode(FoodPlace.self, from: payload), in: &vault.foodPlaces)
#endif
                    break
                case .currencyRateAlert:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
                    try upsert(
                        decoder.decode(CurrencyRateAlert.self, from: payload),
                        in: &vault.currencyRateAlerts
                    )
#endif
                    break
                case .stockPriceAlert:
#if MYTOOLS_FEATURE_STOCKS
                    try upsert(
                        decoder.decode(StockPriceAlert.self, from: payload),
                        in: &vault.stockPriceAlerts
                    )
#endif
                    break
                case .secretItem:
#if MYTOOLS_FEATURE_SECRETS
                    try upsert(decoder.decode(SecretItem.self, from: payload), in: &secrets)
#endif
                    break
                case .credentialDocument:
#if MYTOOLS_FEATURE_DOCUMENTS
                    try upsert(
                        decoder.decode(CredentialDocument.self, from: payload),
                        in: &vault.credentialDocuments
                    )
#endif
                    break
                case .billRecord:
#if MYTOOLS_FEATURE_BILLS
                    try upsert(decoder.decode(BillRecord.self, from: payload), in: &vault.billRecords)
#endif
                    break
                case .attachment:
                    break
                case .appPreferences:
                    break
                }

            case .delete(let kind, let id):
                guard kind.isIncluded(in: enabledModules) else { continue }
                switch kind {
                case .bankAccount:
#if MYTOOLS_FEATURE_FINANCE
                    vault.accounts.removeAll { $0.id == id }
#endif
                    break
                case .bankCard:
#if MYTOOLS_FEATURE_FINANCE
                    vault.cards.removeAll { $0.id == id }
#endif
                    break
                case .stockHolding:
#if MYTOOLS_FEATURE_STOCKS
                    vault.stocks.removeAll { $0.id == id }
#endif
                    break
                case .currencyExchangeRecord:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
                    vault.currencyExchangeRecords.removeAll { $0.id == id }
#endif
                    break
                case .medicalRecord:
#if MYTOOLS_FEATURE_HEALTH
                    vault.medicalRecords.removeAll { $0.id == id }
#endif
                    break
                case .hospitalProfile:
#if MYTOOLS_FEATURE_HEALTH
                    vault.hospitalProfiles.removeAll { $0.id == id }
#endif
                    break
                case .foodPlace:
#if MYTOOLS_FEATURE_FOOD_MAP
                    vault.foodPlaces.removeAll { $0.id == id }
#endif
                    break
                case .currencyRateAlert:
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
                    vault.currencyRateAlerts.removeAll { $0.id == id }
#endif
                    break
                case .stockPriceAlert:
#if MYTOOLS_FEATURE_STOCKS
                    vault.stockPriceAlerts.removeAll { $0.id == id }
#endif
                    break
                case .secretItem:
#if MYTOOLS_FEATURE_SECRETS
                    secrets.removeAll { $0.id == id }
#endif
                    break
                case .credentialDocument:
#if MYTOOLS_FEATURE_DOCUMENTS
                    vault.credentialDocuments.removeAll { $0.id == id }
#endif
                    break
                case .billRecord:
#if MYTOOLS_FEATURE_BILLS
                    vault.billRecords.removeAll { $0.id == id }
#endif
                    break
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
