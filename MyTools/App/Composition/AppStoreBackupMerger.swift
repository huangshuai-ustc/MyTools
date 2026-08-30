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
        var merged = localVault

#if MYTOOLS_FEATURE_FINANCE
        if modules.contains(.personalFinance) {
            merged.accounts = mergeByID(local: localVault.accounts, imported: imported.vault.accounts)
            merged.cards = mergeByID(local: localVault.cards, imported: imported.vault.cards)
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
            merged.stocks = mergeByID(local: localVault.stocks, imported: validImportedStocks)
            merged.stockPriceAlerts = mergeByID(
                local: localVault.stockPriceAlerts,
                imported: imported.vault.stockPriceAlerts
            )
        }
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        if modules.contains(.currencyExchange) {
            merged.currencyExchangeRecords = mergeByID(
                local: localVault.currencyExchangeRecords,
                imported: imported.vault.currencyExchangeRecords
            )
            merged.currencyRateAlerts = mergeByID(
                local: localVault.currencyRateAlerts,
                imported: imported.vault.currencyRateAlerts
            )
        }
#endif
#if MYTOOLS_FEATURE_HEALTH
        if modules.contains(.healthRecords) {
            merged.medicalRecords = mergeByID(
                local: localVault.medicalRecords,
                imported: imported.vault.medicalRecords
            )
            merged.hospitalProfiles = mergeByID(
                local: localVault.hospitalProfiles,
                imported: imported.vault.hospitalProfiles
            )
            merged.medicalRecordTags = AppTagSupport.merged(
                localVault.medicalRecordTags,
                with: imported.vault.medicalRecordTags
            )
        }
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        if modules.contains(.foodMap) {
            merged.foodPlaces = mergeByID(
                local: localVault.foodPlaces,
                imported: imported.vault.foodPlaces
            )
            merged.foodPlaceTags = AppTagSupport.merged(
                localVault.foodPlaceTags,
                with: imported.vault.foodPlaceTags
            )
        }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        if modules.contains(.documents) {
            merged.credentialDocuments = mergeByID(
                local: localVault.credentialDocuments,
                imported: imported.vault.credentialDocuments
            )
            merged.credentialTags = AppTagSupport.merged(
                localVault.credentialTags,
                with: imported.vault.credentialTags
            )
        }
#endif
#if MYTOOLS_FEATURE_BILLS
        if modules.contains(.bills) {
            merged.billRecords = mergeByID(
                local: localVault.billRecords,
                imported: imported.vault.billRecords
            )
            merged.billTags = AppTagSupport.merged(
                localVault.billTags,
                with: imported.vault.billTags
            )
        }
#endif

#if MYTOOLS_FEATURE_SECRETS
        if modules.contains(.secrets), !imported.vault.secretFieldTemplates.isEmpty {
            merged.secretFieldTemplates = imported.vault.secretFieldTemplates
        }
        if modules.contains(.secrets) {
            merged.secretTags = AppTagSupport.merged(
                localVault.secretTags,
                with: imported.vault.secretTags
            )
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
            ? mergeByID(local: localSecrets, imported: importedSecrets)
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
