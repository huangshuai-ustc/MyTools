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
            return vault.financialInstitutions.flatMap(\.financeAttachments)
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
            return []
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
        case .myStocks, .currencyExchange, .bills, .sportsLottery, .partnership:
            return []
        }
    }

    /// Applies `update` to every attachment of `modules`, wherever a record
    /// embeds it. Used to rewrite metadata after a file changed on disk.
    /// Records with an edit time get `changedAt`: iCloud orders versions by
    /// that time, so an unchanged one would tie with the other devices' old
    /// copy and the new metadata could lose to it.
    static func updateAttachments(
        of modules: Set<ToolModule>,
        vault: inout VaultData,
        secrets: inout [SecretVaultValue],
        changedAt: Date = Date(),
        _ update: (inout FileAttachment) -> Void
    ) {
#if MYTOOLS_FEATURE_FINANCE
        if modules.contains(.personalFinance) {
            for index in vault.financialInstitutions.indices {
                var institution = vault.financialInstitutions[index]
                for document in institution.documents.indices { update(&institution.documents[document].attachment) }
                var cards = institution.cards
                for card in cards.indices {
                    for statement in cards[card].statements.indices {
                        guard var attachment = cards[card].statements[statement].attachment else { continue }
                        update(&attachment)
                        cards[card].statements[statement].attachment = attachment
                    }
                }
                if !cards.isEmpty { institution.cards = cards }
                vault.financialInstitutions[index] = institution
            }
        }
#endif
#if MYTOOLS_FEATURE_HEALTH
        if modules.contains(.healthRecords) {
            for record in vault.medicalRecords.indices {
                let original = vault.medicalRecords[record].attachments
                for attachment in original.indices {
                    update(&vault.medicalRecords[record].attachments[attachment])
                }
                if vault.medicalRecords[record].attachments != original { vault.medicalRecords[record].updatedAt = changedAt }
            }
        }
#endif
#if MYTOOLS_FEATURE_SECRETS
        if modules.contains(.secrets) {
            for item in secrets.indices {
                let original = secrets[item].attachments
                for attachment in original.indices { update(&secrets[item].attachments[attachment]) }
                if secrets[item].attachments != original { secrets[item].updatedAt = changedAt }
            }
        }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        if modules.contains(.documents) {
            for document in vault.credentialDocuments.indices {
                let original = vault.credentialDocuments[document].attachments
                for attachment in original.indices {
                    update(&vault.credentialDocuments[document].attachments[attachment].file)
                }
                if vault.credentialDocuments[document].attachments != original {
                    vault.credentialDocuments[document].updatedAt = changedAt
                }
            }
        }
#endif
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
