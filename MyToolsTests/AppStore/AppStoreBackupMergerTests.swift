import Foundation
import Testing
@testable import MyTools

struct AppStoreBackupMergerTests {
    @Test func onlyIncludedModulesAreMerged() {
        let accountID = UUID()
        let stockID = UUID()
        let recordID = UUID()
        let currencyAlertID = UUID()
        let secretID = UUID()

        var localAccount = BankAccount()
        localAccount.id = accountID
        localAccount.name = "Local account"
        var importedAccount = localAccount
        importedAccount.name = "Imported account"

        var localStock = StockHolding()
        localStock.id = stockID
        localStock.symbol = "LOCAL"
        var importedStock = localStock
        importedStock.symbol = "IMPORTED"

        var localRecord = MedicalRecord()
        localRecord.id = recordID
        localRecord.hospital = "Local hospital"
        var importedRecord = localRecord
        importedRecord.hospital = "Imported hospital"

        let localCurrencyAlert = CurrencyRateAlert(
            id: currencyAlertID,
            threshold: 600
        )
        let importedCurrencyAlert = CurrencyRateAlert(
            id: currencyAlertID,
            threshold: 700
        )
        let localSecret = SecretItem(id: secretID, title: "Local secret")
        let importedSecret = SecretItem(id: secretID, title: "Imported secret")

        let localVault = VaultData(
            accounts: [localAccount],
            stocks: [localStock],
            medicalRecords: [localRecord],
            currencyRateAlerts: [localCurrencyAlert]
        )
        let imported = VaultBackupPayload(
            vault: VaultData(
                accounts: [importedAccount],
                stocks: [importedStock],
                medicalRecords: [importedRecord],
                currencyRateAlerts: [importedCurrencyAlert]
            ),
            secrets: [importedSecret],
            includedModules: [.currencyExchange]
        )

        let merged = AppStoreBackupMerger.merge(
            localVault: localVault,
            localSecrets: [localSecret],
            imported: imported
        )

        #expect(merged.vault.accounts == [localAccount])
        #expect(merged.vault.stocks == [localStock])
        #expect(merged.vault.medicalRecords == [localRecord])
        #expect(merged.vault.currencyRateAlerts == [importedCurrencyAlert])
        #expect(merged.secrets == [localSecret])
        #expect(merged.includedModules == [.currencyExchange])
    }

    @Test func selectedModuleReplacesMatchingIDsAndAppendsNewIDs() {
        let existingID = UUID()
        let retainedID = UUID()
        let appendedID = UUID()
        let local = [
            StockPriceAlert(id: existingID, threshold: 10),
            StockPriceAlert(id: retainedID, threshold: 20)
        ]
        let imported = [
            StockPriceAlert(id: existingID, threshold: 30),
            StockPriceAlert(id: appendedID, threshold: 40)
        ]

        let merged = AppStoreBackupMerger.merge(
            localVault: VaultData(stockPriceAlerts: local),
            localSecrets: [],
            imported: VaultBackupPayload(
                vault: VaultData(stockPriceAlerts: imported),
                includedModules: [.myStocks]
            )
        )

        #expect(merged.vault.stockPriceAlerts.map(\.id) == [existingID, retainedID, appendedID])
        #expect(merged.vault.stockPriceAlerts.map(\.threshold) == [30, 20, 40])
    }

    @Test func selectedSecretsReplaceMatchingIDsAndAppendNewIDs() {
        let existingID = UUID()
        let appendedID = UUID()
        let merged = AppStoreBackupMerger.merge(
            localVault: VaultData(),
            localSecrets: [SecretItem(id: existingID, title: "Local")],
            imported: VaultBackupPayload(
                vault: VaultData(),
                secrets: [
                    SecretItem(id: existingID, title: "Imported"),
                    SecretItem(id: appendedID, title: "New")
                ],
                includedModules: [.secrets]
            )
        )

        #expect(merged.secrets.map(\.id) == [existingID, appendedID])
        #expect(merged.secrets.map(\.title) == ["Imported", "New"])
    }

    @Test func disabledModulesAreExcludedFromImportedPayload() {
        var localHealth = MedicalRecord()
        localHealth.hospital = "Local"
        var importedHealth = localHealth
        importedHealth.hospital = "Imported"
        var importedAccount = BankAccount()
        importedAccount.name = "Imported account"

        let merged = AppStoreBackupMerger.merge(
            localVault: VaultData(medicalRecords: [localHealth]),
            localSecrets: [],
            imported: VaultBackupPayload(
                vault: VaultData(
                    accounts: [importedAccount],
                    medicalRecords: [importedHealth]
                ),
                includedModules: [.personalFinance, .healthRecords]
            ),
            enabledModules: [.personalFinance]
        )

        #expect(merged.vault.accounts == [importedAccount])
        #expect(merged.vault.medicalRecords == [localHealth])
        #expect(merged.includedModules == [.personalFinance])
    }
}
