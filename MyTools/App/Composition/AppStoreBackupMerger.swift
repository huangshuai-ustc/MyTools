import Foundation

enum AppStoreBackupMerger {
    static func merge(
        localVault: VaultData,
        localSecrets: [SecretVaultValue],
        imported: VaultBackupPayload,
        enabledModules: Set<ToolModule> = ToolModuleCatalog.allModules
    ) -> VaultBackupPayload {
        let modules = imported.includedModules.intersection(
            CompiledToolModules.available(from: enabledModules)
        ).intersection(ToolModuleCatalog.backupModules)
            // Imported backup data is an explicit recovery source. A local
            // quarantine must not filter out the module being repaired. Each
            // included module below is replaced as a whole; omitted modules
            // remain untouched.
        var merged = localVault
#if MYTOOLS_FEATURE_PARTNERSHIP
        if modules.contains(.partnership) {
            merged.partnershipBooks = imported.vault.partnershipBooks
        }
#endif

#if MYTOOLS_FEATURE_FINANCE
        if modules.contains(.personalFinance) {
            merged.financialInstitutions = imported.vault.financialInstitutions
            // Strict backup decoding has already validated the imported module.
            // Clear only Finance quarantine; unrelated modules retain their
            // original recovery payloads and blocked status.
            merged.unavailableModules.remove("personalFinance")
            for key in ["financialInstitutions", "accounts", "cards", "financialProviders", "domesticBankLoginFieldTemplates", "overseasBankLoginFieldTemplates"] {
                merged.preservedModulePayloads.removeValue(forKey: key)
            }
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
            let validImportedStocks = imported.vault.stocks.filter {
                $0.hasValidTransactionOrder
            }
            guard validImportedStocks.count == imported.vault.stocks.count else { return VaultBackupPayload(vault: localVault, secrets: localSecrets, includedModules: modules) }
            merged.stocks = validImportedStocks
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
#if MYTOOLS_FEATURE_FOOD_MAP
        if modules.contains(.foodMap) {
            merged.foodPlaces = imported.vault.foodPlaces
            merged.foodPlaceTags = imported.vault.foodPlaceTags
        }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        if modules.contains(.documents) {
            merged.credentialDocuments = imported.vault.credentialDocuments
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
