import Foundation
import Testing
@testable import MyTools

struct AppStoreBackupMergerTests {
    @Test func oldFinanceBackupRestoresInstitutionAndCardsTogether() throws {
        var old = FinancialInstitution()
        old.bankName = "Old institution"
        var local = old
        var profile = FinancialInstitution()
        profile.name = "New institution"
        local.financialProfile = profile
        var oldCard = BankCard()
        oldCard.accountID = old.id
        oldCard.cardType = "Old card"
        var localCard = oldCard
        localCard.cardType = "New card"
        let merged = try AppStoreBackupMerger.merge(
            localVault: VaultData(accounts: [local], cards: [localCard]), localSecrets: [],
            imported: VaultBackupPayload(vault: VaultData(accounts: [old], cards: [oldCard]), includedModules: [.personalFinance])
        )
        #expect(merged.vault.financialInstitutions[0].name == "Old institution")
        #expect(merged.vault.financialInstitutions[0].financialProfile != nil)
        #expect(merged.vault.cards[0].cardType == "Old card")
    }
    @Test func stockCashFlowsAreMergedOnlyWithStocksModule() throws {
        var local = StockCashFlowRecord()
        local.amount = 100
        var imported = local
        imported.amount = 200

        let excluded = try AppStoreBackupMerger.merge(
            localVault: VaultData(stockCashFlowRecords: [local]),
            localSecrets: [],
            imported: VaultBackupPayload(
                vault: VaultData(stockCashFlowRecords: [imported]),
                includedModules: [.currencyExchange]
            )
        )
        #expect(excluded.vault.stockCashFlowRecords == [local])

        let included = try AppStoreBackupMerger.merge(
            localVault: VaultData(stockCashFlowRecords: [local]),
            localSecrets: [],
            imported: VaultBackupPayload(
                vault: VaultData(stockCashFlowRecords: [imported]),
                includedModules: [.myStocks]
            )
        )
        #expect(included.vault.stockCashFlowRecords == [imported])
    }

    @Test func onlyIncludedModulesAreMerged() throws {
        let accountID = UUID()
        let stockID = UUID()
        let recordID = UUID()
        let currencyAlertID = UUID()
        let secretID = UUID()

        var localAccount = FinancialInstitution()
        localAccount.id = accountID
        localAccount.bankName = "Local account"
        var importedAccount = localAccount
        importedAccount.bankName = "Imported account"

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
            financialInstitutions: [localAccount],
            stocks: [localStock],
            medicalRecords: [localRecord],
            currencyRateAlerts: [localCurrencyAlert]
        )
        let imported = VaultBackupPayload(
            vault: VaultData(
                financialInstitutions: [importedAccount],
                stocks: [importedStock],
                medicalRecords: [importedRecord],
                currencyRateAlerts: [importedCurrencyAlert]
            ),
            secrets: [importedSecret],
            includedModules: [.currencyExchange]
        )

        let merged = try AppStoreBackupMerger.merge(
            localVault: localVault,
            localSecrets: [localSecret],
            imported: imported
        )

        #expect(merged.vault.financialInstitutions == [localAccount])
        #expect(merged.vault.stocks == [localStock])
        #expect(merged.vault.medicalRecords == [localRecord])
        #expect(merged.vault.currencyRateAlerts == [importedCurrencyAlert])
        #expect(merged.secrets == [localSecret])
        #expect(merged.includedModules == [ToolModule.currencyExchange])
    }

    /// Backup import replaces every included module as a whole: local-only
    /// records of that module are dropped, omitted modules stay untouched.
    @Test func selectedModuleIsReplacedAsAWhole() throws {
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

        let merged = try AppStoreBackupMerger.merge(
            localVault: VaultData(stockPriceAlerts: local),
            localSecrets: [],
            imported: VaultBackupPayload(
                vault: VaultData(stockPriceAlerts: imported),
                includedModules: [.myStocks]
            )
        )

        #expect(merged.vault.stockPriceAlerts.map(\.id) == [existingID, appendedID])
        #expect(merged.vault.stockPriceAlerts.map(\.threshold) == [30, 40])
        #expect(!merged.vault.stockPriceAlerts.contains { $0.id == retainedID })
    }

    @Test func selectedSecretsAreReplacedAsAWhole() throws {
        let existingID = UUID()
        let appendedID = UUID()
        let merged = try AppStoreBackupMerger.merge(
            localVault: VaultData(),
            localSecrets: [SecretItem(id: existingID, title: "Local"), SecretItem(title: "Local only")],
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

    @Test func disabledModulesAreExcludedFromImportedPayload() throws {
        var localHealth = MedicalRecord()
        localHealth.hospital = "Local"
        var importedHealth = localHealth
        importedHealth.hospital = "Imported"
        var importedAccount = FinancialInstitution()
        importedAccount.bankName = "Imported account"

        let merged = try AppStoreBackupMerger.merge(
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

        #expect(merged.vault.financialInstitutions == [importedAccount])
        #expect(merged.vault.medicalRecords == [localHealth])
        #expect(merged.includedModules == [.personalFinance])
    }

    // AUDIT-027：恢复被隔离的模块时清除隔离状态与原始载荷，并恢复模板。
    @Test func restoringQuarantinedModuleClearsPreservedPayloadAndRestoresTemplates() throws {
        var local = VaultData()
        local.unavailableModules = ["healthRecords", "documents", "myStocks"]
        local.preservedModulePayloads = [
            "medicalRecords": .array([]),
            "credentialFieldTemplates": .array([]),
            "stocks": .array([])
        ]
        var record = MedicalRecord()
        record.hospital = "备份"
        let template = CredentialFieldTemplate(documentType: .passport, fields: [])
        var importedVault = VaultData(medicalRecords: [record])
        importedVault.credentialFieldTemplates = [template]
        importedVault.domesticBankLoginFieldTemplates = []

        let merged = try AppStoreBackupMerger.merge(
            localVault: local,
            localSecrets: [],
            imported: VaultBackupPayload(
                vault: importedVault,
                includedModules: [.healthRecords, .documents, .personalFinance]
            )
        )

        #expect(merged.vault.unavailableModules == ["myStocks"])
        #expect(merged.vault.preservedModulePayloads.keys.sorted() == ["stocks"])
        #expect(merged.vault.medicalRecords.map(\.id) == [record.id])
        #expect(merged.vault.credentialFieldTemplates == [template])
        #expect(merged.vault.domesticBankLoginFieldTemplates.isEmpty)
    }

#if MYTOOLS_FEATURE_STOCKS
    // AUDIT-028：备份中有非法持仓时整体报错，而不是静默返回本地数据。
    @Test func invalidImportedStockFailsTheRestore() {
        var stock = StockHolding(market: .aShare, symbol: "600000")
        var sell = StockTransaction()
        sell.type = .sell
        sell.quantity = 10
        sell.unitPrice = 1
        stock.transactions = [sell]
        #expect(throws: VaultBackupError.self) {
            try AppStoreBackupMerger.merge(
                localVault: VaultData(),
                localSecrets: [],
                imported: VaultBackupPayload(vault: VaultData(stocks: [stock]), includedModules: [.myStocks])
            )
        }
    }
#endif
}
