import Foundation

enum AppStoreBackupMerger {
    static func merge(
        localVault: VaultData,
        localSecrets: [SecretVaultValue],
        imported: VaultBackupPayload,
        enabledModules: Set<ToolModule> = ToolModuleCatalog.allModules
    ) throws -> VaultBackupPayload {
        let modules = imported.includedModules.intersection(
            CompiledToolModules.available(from: enabledModules)
        ).intersection(ToolModuleCatalog.backupModules)
            // Imported backup data is an explicit recovery source. A local
            // quarantine must not filter out the module being repaired. Each
            // included module below is replaced as a whole; omitted modules
            // remain untouched.
        var merged = localVault
        // Strict backup decoding has already validated every imported module.
        // A restored module leaves quarantine: otherwise the preserved raw
        // payload keeps winning at encode time and the import never reaches
        // disk (AUDIT-027). Unrelated modules keep their recovery payloads.
        for module in modules {
            merged.unavailableModules.remove(module.rawValue)
            for key in quarantinedPayloadKeys[module, default: []] {
                merged.preservedModulePayloads.removeValue(forKey: key)
            }
            if module == .secrets { merged.preservedSecrets = nil }
        }

#if MYTOOLS_FEATURE_FINANCE
        if modules.contains(.personalFinance) {
            merged.financialInstitutions = imported.vault.financialInstitutions
            merged.domesticBankLoginFieldTemplates = imported.vault.domesticBankLoginFieldTemplates
            merged.overseasBankLoginFieldTemplates = imported.vault.overseasBankLoginFieldTemplates
            for key in ["accounts", "cards", "financialProviders"] {
                merged.unknownPayloads.removeValue(forKey: key)
            }
        }
#endif
#if MYTOOLS_FEATURE_STOCKS
        if modules.contains(.myStocks) {
            // Sanitize incoming stock holdings before merging: reject any holding
            // whose transaction sequence would produce a negative position so that
            // malformed backup data cannot corrupt the local portfolio or place a
            // stock into an indeterminate listState.
            let rejectedStockIDs = imported.vault.stocks
                .filter { !$0.hasValidTransactionOrder }
                .map(\.id)
            if !rejectedStockIDs.isEmpty {
                DiagnosticLogger.shared.log(
                    .backup,
                    "备份导入拒绝了 \(rejectedStockIDs.count) 条非法持仓记录（交易顺序会导致负持仓）：\(rejectedStockIDs.map(\.uuidString).joined(separator: ","))",
                    level: .warning
                )
            }
            // The module is replaced as a whole, so a partial import is not an
            // option; fail loudly instead of reporting success (AUDIT-028).
            guard rejectedStockIDs.isEmpty else {
                throw VaultBackupError.invalidStockHoldings(rejectedStockIDs.count)
            }
            merged.stocks = imported.vault.stocks
            merged.stockCashFlowRecords = imported.vault.stockCashFlowRecords
            merged.stockPriceAlerts = imported.vault.stockPriceAlerts
            merged.stockReturnAlerts = imported.vault.stockReturnAlerts
        }
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        if modules.contains(.currencyExchange) {
            merged.currencyExchangeRecords = imported.vault.currencyExchangeRecords
            merged.currencyRateAlerts = imported.vault.currencyRateAlerts
        }
#endif
#if MYTOOLS_FEATURE_HEALTH
        if modules.contains(.healthRecords) {
            merged.medicalRecords = imported.vault.medicalRecords
            merged.hospitalProfiles = imported.vault.hospitalProfiles
            merged.medicalRecordTags = imported.vault.medicalRecordTags
        }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        if modules.contains(.documents) {
            merged.credentialDocuments = imported.vault.credentialDocuments
            merged.credentialFieldTemplates = imported.vault.credentialFieldTemplates
            merged.credentialTags = imported.vault.credentialTags
        }
#endif
#if MYTOOLS_FEATURE_BILLS
        if modules.contains(.bills) {
            merged.billRecords = imported.vault.billRecords
            merged.billTags = imported.vault.billTags
        }
#endif

#if MYTOOLS_FEATURE_SECRETS
        if modules.contains(.secrets) {
            merged.secretFieldTemplates = imported.vault.secretFieldTemplates
        }
        if modules.contains(.secrets) {
            merged.secretTags = imported.vault.secretTags
        }
        let importedSecrets: [SecretVaultValue] = modules.contains(.secrets)
            ? imported.secrets.map { item in
                guard item.fields.isEmpty else { return item }
                let template = imported.vault.secretFieldTemplates.first {
                    $0.category == item.category
                } ?? localVault.secretFieldTemplates.first {
                    $0.category == item.category
                } ?? SecretFieldTemplate(category: item.category, fields: item.category.defaultFields)
                var normalized = item
                normalized.fields = template.makeFields()
                return normalized
            }
            : []
        let secrets = modules.contains(.secrets)
            ? importedSecrets
            : localSecrets
#else
        let secrets = localSecrets
#endif
        return VaultBackupPayload(vault: merged, secrets: secrets, includedModules: modules)
    }

    /// Top-level Vault keys whose raw payload is preserved while a module is
    /// quarantined (see `VaultData.init(from:)`).
    private static let quarantinedPayloadKeys: [ToolModule: [String]] = [
        .personalFinance: [
            "financialInstitutions", "accounts", "cards", "financialProviders",
            "domesticBankLoginFieldTemplates", "overseasBankLoginFieldTemplates",
        ],
        .myStocks: ["stocks", "stockCashFlowRecords", "stockPriceAlerts", "stockReturnAlerts"],
        .currencyExchange: ["currencyExchangeRecords", "currencyRateAlerts"],
        .healthRecords: ["medicalRecords", "hospitalProfiles", "medicalRecordTags"],
        .documents: ["credentialDocuments", "credentialFieldTemplates", "credentialTags"],
        .bills: ["billRecords", "billTags"],
        .secrets: ["secretTags", "secretFieldTemplates"],
    ]

    private static func mergeByID<Element: Identifiable>(
        local: [Element],
        imported: [Element]
    ) -> [Element] where Element.ID: Hashable {
        var result = local
        var indices: [Element.ID: Int] = [:]
        for index in result.indices {
            indices[result[index].id] = index
        }
        for item in imported {
            if let index = indices[item.id] {
                result[index] = item
            } else {
                indices[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }
}
