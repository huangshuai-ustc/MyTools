import Foundation

enum AppStoreBackupMerger {
    static func merge(
        localVault: VaultData,
        localSecrets: [SecretItem],
        imported: VaultBackupPayload
    ) -> VaultBackupPayload {
        let modules = imported.includedModules
        var merged = localVault

        if modules.contains(.personalFinance) {
            merged.accounts = mergeByID(local: localVault.accounts, imported: imported.vault.accounts)
            merged.cards = mergeByID(local: localVault.cards, imported: imported.vault.cards)
        }
        if modules.contains(.myStocks) {
            merged.stocks = mergeByID(local: localVault.stocks, imported: imported.vault.stocks)
            merged.stockPriceAlerts = mergeByID(
                local: localVault.stockPriceAlerts,
                imported: imported.vault.stockPriceAlerts
            )
        }
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

        let secrets = modules.contains(.secrets)
            ? mergeByID(local: localSecrets, imported: imported.secrets)
            : localSecrets
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
