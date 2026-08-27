import Foundation

/// Centralizes the cross-module attachment reference rules used by cleanup,
/// restore and storage-integrity scans.
struct ModuleAttachmentReferenceIndex {
    static func attachments(
        for module: ToolModule,
        vault: VaultData,
        secrets: [SecretVaultValue]
    ) -> [FileAttachment] {
        switch module {
        case .personalFinance:
#if MYTOOLS_FEATURE_FINANCE
            return vault.cards.flatMap(\.statements).compactMap(\.attachment)
#else
            return []
#endif
        case .healthRecords:
#if MYTOOLS_FEATURE_HEALTH
            return vault.medicalRecords.flatMap(\.attachments)
#else
            return []
#endif
        case .foodMap:
#if MYTOOLS_FEATURE_FOOD_MAP
            return vault.foodPlaces.flatMap(\.photos)
#else
            return []
#endif
        case .secrets:
#if MYTOOLS_FEATURE_SECRETS
            return secrets.flatMap(\.attachments)
#else
            return []
#endif
        case .documents:
#if MYTOOLS_FEATURE_DOCUMENTS
            return vault.credentialDocuments.flatMap(\.attachmentFiles)
#else
            return []
#endif
        case .myStocks, .currencyExchange, .bills, .sportsLottery:
            return []
        }
    }

    static func byID(
        vault: VaultData,
        secrets: [SecretVaultValue]
    ) -> [UUID: FileAttachment] {
        let values = ToolModule.attachmentModules.flatMap {
            attachments(for: $0, vault: vault, secrets: secrets)
        }
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    static func referencedStoredFileNames(
        vault: VaultData,
        secrets: [SecretVaultValue]
    ) -> Set<String> {
        var result = vault.opaqueAttachmentStoredFileNames
#if !MYTOOLS_FEATURE_SECRETS
        // 保密模块未编译时其附件以不透明载荷保留，索引按已编译模块枚举读不到这些文件名；
        // 这里补充引用，避免存储完整性扫描把未编译模块的附件误判为孤立文件。
        result.formUnion(secrets.flatMap(\.attachmentStoredFileNames))
#endif
        for module in ToolModule.attachmentModules {
            result.formUnion(
                attachments(for: module, vault: vault, secrets: secrets).map(\.storedFileName)
            )
        }
        return result.filter { !$0.isEmpty }
    }
}

private extension ToolModule {
    static let attachmentModules: [ToolModule] = [
        .personalFinance,
        .healthRecords,
        .foodMap,
        .secrets,
        .documents
    ]
}
