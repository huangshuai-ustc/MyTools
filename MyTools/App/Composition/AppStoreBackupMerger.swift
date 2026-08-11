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
        )
        var merged = localVault

#if MYTOOLS_FEATURE_FINANCE
        if modules.contains(.personalFinance) {
            merged.accounts = mergeByID(local: localVault.accounts, imported: imported.vault.accounts)
            merged.cards = mergeByID(local: localVault.cards, imported: imported.vault.cards)
        }
#endif
#if MYTOOLS_FEATURE_STOCKS
        if modules.contains(.myStocks) {
            merged.stocks = mergeByID(local: localVault.stocks, imported: imported.vault.stocks)
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
        }
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        if modules.contains(.foodMap) {
            merged.foodPlaces = mergeByID(
                local: localVault.foodPlaces,
                imported: imported.vault.foodPlaces
            )
        }
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        if modules.contains(.documents) {
            merged.credentialDocuments = mergeByID(
                local: localVault.credentialDocuments,
                imported: imported.vault.credentialDocuments
            )
        }
#endif
#if MYTOOLS_FEATURE_BILLS
        if modules.contains(.bills) {
            merged.billRecords = mergeByID(
                local: localVault.billRecords,
                imported: imported.vault.billRecords
            )
        }
#endif

#if MYTOOLS_FEATURE_SECRETS
        let secrets = modules.contains(.secrets)
            ? mergeByID(local: localSecrets, imported: imported.secrets)
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
