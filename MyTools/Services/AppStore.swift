import Foundation
import Combine
import OSLog
import UniformTypeIdentifiers

private let startupLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.fjwyz.PersonalToolBox",
    category: "Startup"
)

private struct AppStoreInitialSnapshot: @unchecked Sendable {
    let vault: VaultData
    let vaultByteCount: Int
    let vaultSource: String
    let readDurationMilliseconds: Double
    let decodeDurationMilliseconds: Double
    let migrationDurationMilliseconds: Double
    let loadDurationMilliseconds: Double

    static func load() -> Self {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = SecureStore().loadVaultWithMetrics()
        return Self(
            vault: result.vault,
            vaultByteCount: result.byteCount,
            vaultSource: result.source,
            readDurationMilliseconds: result.readMilliseconds,
            decodeDurationMilliseconds: result.decodeMilliseconds,
            migrationDurationMilliseconds: result.migrationMilliseconds,
            loadDurationMilliseconds: (
                ProcessInfo.processInfo.systemUptime - startedAt
            ) * 1_000
        )
    }
}

private struct AppStoreCachedRatesSnapshot: @unchecked Sendable {
    let usdRenminbiBuyingRate: Decimal?
    let renminbiBuyingRates: [CurrencyCode: Decimal]
    let renminbiSellingRates: [CurrencyCode: Decimal]
    let exchangeRateUpdatedAt: Date?

    static func load() -> Self {
        let defaults = UserDefaults.standard
        let usdRate = defaults.string(forKey: "stock-usd-cny-buying-rate-v1")
            .flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        var buyingRates = decimalRates(
            from: defaults.dictionary(forKey: "boc-currency-buying-rates-v1") as? [String: String]
        )
        let sellingRates = decimalRates(
            from: defaults.dictionary(forKey: "boc-currency-selling-rates-v1") as? [String: String]
        )
        if let usdRate { buyingRates[.usd] = usdRate }

        return Self(
            usdRenminbiBuyingRate: usdRate,
            renminbiBuyingRates: buyingRates,
            renminbiSellingRates: sellingRates,
            exchangeRateUpdatedAt: defaults.object(
                forKey: "stock-usd-cny-buying-rate-date-v1"
            ) as? Date
        )
    }

    private static func decimalRates(from values: [String: String]?) -> [CurrencyCode: Decimal] {
        guard let values else { return [:] }
        return values.reduce(into: [:]) { result, entry in
            guard let currency = CurrencyCode(rawValue: entry.key),
                  let rate = Decimal(
                    string: entry.value,
                    locale: Locale(identifier: "en_US_POSIX")
                  ) else { return }
            result[currency] = rate
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var accounts: [BankAccount]
    @Published private(set) var cards: [BankCard]
    @Published private(set) var stocks: [StockHolding]
    @Published private(set) var currencyExchangeRecords: [CurrencyExchangeRecord]
    @Published private(set) var medicalRecords: [MedicalRecord]
    @Published private(set) var hospitalProfiles: [HospitalProfile]
    @Published private(set) var isRefreshingQuotes = false
    @Published private(set) var quoteRefreshError: String?
    @Published private(set) var lastStockRefreshAt: Date?
    @Published private(set) var quoteErrors: [UUID: String] = [:]
    @Published private(set) var quoteSources: [UUID: String] = [:]
    @Published private(set) var usdRenminbiBuyingRate: Decimal?
    @Published private(set) var renminbiBuyingRates: [CurrencyCode: Decimal] = [:]
    @Published private(set) var renminbiSellingRates: [CurrencyCode: Decimal] = [:]
    @Published private(set) var exchangeRateUpdatedAt: Date?
    @Published private(set) var exchangeRateError: String?
    @Published private(set) var isRefreshingExchangeRate = false
    @Published private(set) var isInitialDataLoaded = false
    private let secureStore = SecureStore()
    private let quoteService = StockQuoteService()
    private let exchangeRateService = ForeignExchangeRateService()
    private let attachmentStore = AttachmentStore()
    private let defaults = UserDefaults.standard
    private var lastExchangeRateRequestAt: Date?

    init() {
        accounts = []
        cards = []
        stocks = []
        currencyExchangeRecords = []
        medicalRecords = []
        hospitalProfiles = []
        renminbiBuyingRates = [.cny: 1]
        renminbiSellingRates = [.cny: 1]

        Task { [weak self] in
            let cachedRatesTask = Task.detached(priority: .utility) {
                AppStoreCachedRatesSnapshot.load()
            }
            let snapshot = await Task.detached(priority: .userInitiated) {
                AppStoreInitialSnapshot.load()
            }.value
            guard let self else { return }
            self.applyInitialSnapshot(snapshot)
            self.applyCachedRatesSnapshot(await cachedRatesTask.value)
        }
    }

    var currentCardCount: Int {
        VaultData(accounts: accounts, cards: cards).currentCardCount
    }

    var currentBankCount: Int {
        VaultData(accounts: accounts, cards: cards).currentBankCount
    }

    var openStockCount: Int {
        stocks.lazy.filter { $0.currentShares > 0 }.count
    }

    func loadEncryptedVaultAfterAuthentication() {
        guard !secureStore.hasLocalVault() else { return }
        let vault = secureStore.loadEncryptedVault()
        guard !vault.isEmpty else { return }
        let upgradedVault = Self.initializingHospitalDirectory(in: vault)
        applyVault(upgradedVault)
        // 旧版本加密数据在管理员认证后迁移到普通可读存储；之后普通模式启动不读取 Keychain。
        try? secureStore.saveVault(upgradedVault)
    }

    private func applyInitialSnapshot(_ snapshot: AppStoreInitialSnapshot) {
        let upgradedVault = Self.initializingHospitalDirectory(in: snapshot.vault)
        applyVault(upgradedVault)
        if !snapshot.vault.hospitalDirectoryInitialized {
            try? secureStore.saveVault(upgradedVault)
        }
        isInitialDataLoaded = true
        startupLogger.info(
            "Local vault loaded from \(snapshot.vaultSource, privacy: .public): \(snapshot.vaultByteCount, privacy: .public) bytes; read \(snapshot.readDurationMilliseconds, privacy: .public) ms, decode \(snapshot.decodeDurationMilliseconds, privacy: .public) ms, migration \(snapshot.migrationDurationMilliseconds, privacy: .public) ms, total \(snapshot.loadDurationMilliseconds, privacy: .public) ms"
        )
    }

    private func applyCachedRatesSnapshot(_ snapshot: AppStoreCachedRatesSnapshot) {
        usdRenminbiBuyingRate = snapshot.usdRenminbiBuyingRate
        renminbiBuyingRates = snapshot.renminbiBuyingRates
        renminbiSellingRates = snapshot.renminbiSellingRates
        renminbiBuyingRates[.cny] = 1
        renminbiSellingRates[.cny] = 1
        exchangeRateUpdatedAt = snapshot.exchangeRateUpdatedAt
    }

    private func applyVault(_ vault: VaultData) {
        accounts = vault.accounts
        cards = vault.cards
        stocks = vault.stocks
        currencyExchangeRecords = vault.currencyExchangeRecords
        medicalRecords = vault.medicalRecords
        hospitalProfiles = vault.hospitalProfiles
    }

    private static func initializingHospitalDirectory(in vault: VaultData) -> VaultData {
        guard !vault.hospitalDirectoryInitialized else { return vault }
        var upgraded = vault
        upgraded.hospitalProfiles = HospitalProfile.inferred(from: vault.medicalRecords)
        upgraded.hospitalDirectoryInitialized = true
        return upgraded
    }

    func upsertAccount(_ account: BankAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            for cardIndex in cards.indices where cards[cardIndex].accountID == account.id {
                cards[cardIndex].bankName = account.bankName
                cards[cardIndex].branchName = account.branchName
            }
        } else {
            accounts.append(account)
        }
        persist()
    }

    func replaceAccount(_ account: BankAccount, cards updatedCards: [BankCard]) {
        let previousCards = cards.filter { $0.accountID == account.id }
        let retainedAttachmentIDs = Set(
            updatedCards.flatMap(\.statements).compactMap { $0.attachment?.id }
        )
        for card in previousCards {
            for statement in card.statements {
                guard let attachment = statement.attachment,
                      !retainedAttachmentIDs.contains(attachment.id) else { continue }
                attachmentStore.delete(attachment)
            }
        }

        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        cards.removeAll { $0.accountID == account.id }
        cards.append(contentsOf: updatedCards.map { card in
            var attached = card
            attached.accountID = account.id
            attached.bankName = account.bankName
            attached.branchName = account.branchName
            return attached
        })
        persist()
    }

    func deleteAccount(at offsets: IndexSet) {
        let ids = offsets.map { accounts[$0].id }
        for card in cards where ids.contains(card.accountID ?? UUID()) {
            card.statements.compactMap(\.attachment).forEach(attachmentStore.delete)
        }
        accounts.remove(atOffsets: offsets)
        cards.removeAll { card in ids.contains(card.accountID ?? UUID()) }
        persist()
    }

    func cards(for account: BankAccount) -> [BankCard] { cards.filter { $0.accountID == account.id } }

    func upsertCard(_ card: BankCard, in account: BankAccount) {
        var attached = card; attached.accountID = account.id; attached.bankName = account.bankName; attached.branchName = account.branchName
        upsert(attached)
    }

    func upsert(_ card: BankCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            let retainedAttachmentIDs = Set(card.statements.compactMap { $0.attachment?.id })
            cards[index].statements.compactMap(\.attachment)
                .filter { !retainedAttachmentIDs.contains($0.id) }
                .forEach(attachmentStore.delete)
            cards[index] = card
        } else {
            cards.append(card)
        }
        persist()
    }

    func stockExists(market: StockMarket, symbol: String, excluding stockID: UUID? = nil) -> Bool {
        let normalized = StockHolding.normalizedSymbol(symbol, market: market)
        return stocks.contains { stock in
            stock.id != stockID
                && stock.market == market
                && StockHolding.normalizedSymbol(stock.symbol, market: stock.market) == normalized
        }
    }

    func upsertStock(_ stock: StockHolding) {
        var normalized = stock
        normalized.symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        if let index = stocks.firstIndex(where: { $0.id == stock.id }) {
            stocks[index] = normalized
        } else {
            stocks.append(normalized)
        }
        persist()
    }

    func upsertCurrencyExchangeRecord(_ record: CurrencyExchangeRecord) {
        if let index = currencyExchangeRecords.firstIndex(where: { $0.id == record.id }) {
            currencyExchangeRecords[index] = record
        } else {
            currencyExchangeRecords.append(record)
        }
        persist()
    }

    func deleteCurrencyExchangeRecords(ids: Set<UUID>) {
        currencyExchangeRecords.removeAll { ids.contains($0.id) }
        persist()
    }

    func upsertMedicalRecord(_ record: MedicalRecord) {
        var storedRecord = record
        storedRecord.hospital = storedRecord.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = medicalRecords.firstIndex(where: { $0.id == storedRecord.id }) {
            let retainedIDs = Set(storedRecord.attachments.map(\.id))
            for attachment in medicalRecords[index].attachments where !retainedIDs.contains(attachment.id) {
                attachmentStore.delete(attachment)
            }
            medicalRecords[index] = storedRecord
        } else {
            medicalRecords.append(storedRecord)
        }
        rememberHospital(from: storedRecord)
        persist()
    }

    func hospitalProfile(named name: String) -> HospitalProfile? {
        let key = hospitalNameKey(name)
        return hospitalProfiles.first { hospitalNameKey($0.name) == key }
    }

    func hospitalProfileNameExists(_ name: String, excluding id: UUID? = nil) -> Bool {
        let key = hospitalNameKey(name)
        guard !key.isEmpty else { return false }
        return hospitalProfiles.contains { $0.id != id && hospitalNameKey($0.name) == key }
    }

    @discardableResult
    func upsertHospitalProfile(_ profile: HospitalProfile) -> Bool {
        var storedProfile = profile
        storedProfile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storedProfile.name.isEmpty,
              !hospitalProfileNameExists(storedProfile.name, excluding: storedProfile.id) else {
            return false
        }

        let previousName: String?
        if let index = hospitalProfiles.firstIndex(where: { $0.id == storedProfile.id }) {
            previousName = hospitalProfiles[index].name
            storedProfile.createdAt = hospitalProfiles[index].createdAt
            storedProfile.updatedAt = Date()
            hospitalProfiles[index] = storedProfile
        } else {
            previousName = nil
            storedProfile.createdAt = Date()
            storedProfile.updatedAt = storedProfile.createdAt
            hospitalProfiles.append(storedProfile)
        }

        let namesToMatch = [previousName, storedProfile.name].compactMap { $0 }.map(hospitalNameKey)
        for index in medicalRecords.indices
        where !medicalRecords[index].isPharmacyPurchase
            && namesToMatch.contains(hospitalNameKey(medicalRecords[index].hospital)) {
            medicalRecords[index].hospital = storedProfile.name
            medicalRecords[index].hospitalLevel = storedProfile.level
            medicalRecords[index].hospitalGrade = storedProfile.grade
            medicalRecords[index].hospitalCategory = storedProfile.category
            medicalRecords[index].updatedAt = Date()
        }
        persist()
        return true
    }

    func deleteHospitalProfiles(ids: Set<UUID>) {
        hospitalProfiles.removeAll { ids.contains($0.id) }
        persist()
    }

    private func rememberHospital(from record: MedicalRecord) {
        guard !record.isPharmacyPurchase, !record.hospital.isEmpty else { return }
        if let index = hospitalProfiles.firstIndex(where: {
            hospitalNameKey($0.name) == hospitalNameKey(record.hospital)
        }) {
            if record.hospitalLevel != .unspecified {
                hospitalProfiles[index].level = record.hospitalLevel
            }
            if record.hospitalGrade != .unspecified {
                hospitalProfiles[index].grade = record.hospitalGrade
            }
            if record.hospitalCategory != .unspecified {
                hospitalProfiles[index].category = record.hospitalCategory
            }
            hospitalProfiles[index].updatedAt = Date()
        } else {
            hospitalProfiles.append(HospitalProfile(record: record))
        }
    }

    private func hospitalNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
    }

    func deleteMedicalRecords(ids: Set<UUID>) {
        var recordIDsToDelete = ids
        while true {
            let dependentIDs = Set(medicalRecords.compactMap { record -> UUID? in
                guard let parentID = record.parentRecordID,
                      recordIDsToDelete.contains(parentID) else { return nil }
                return record.id
            })
            let expandedIDs = recordIDsToDelete.union(dependentIDs)
            guard expandedIDs != recordIDsToDelete else { break }
            recordIDsToDelete = expandedIDs
        }

        for record in medicalRecords where recordIDsToDelete.contains(record.id) {
            record.attachments.forEach(attachmentStore.delete)
        }
        medicalRecords.removeAll { recordIDsToDelete.contains($0.id) }
        persist()
    }

    func importMedicalAttachment(from url: URL) throws -> FileAttachment {
        try attachmentStore.importFile(from: url)
    }

    func saveMedicalPhoto(data: Data, fileName: String, contentType: UTType) throws -> FileAttachment {
        try attachmentStore.save(data: data, originalFileName: fileName, contentType: contentType)
    }

    func deleteUncommittedAttachment(_ attachment: FileAttachment) {
        attachmentStore.delete(attachment)
    }

    func medicalAttachmentURL(for attachment: FileAttachment) -> URL {
        attachmentStore.url(for: attachment)
    }

    func importCreditCardStatement(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .pdf) else {
            attachmentStore.delete(attachment)
            throw AttachmentStoreError.invalidFile
        }
        return attachment
    }

    func financeAttachmentURL(for attachment: FileAttachment) -> URL {
        attachmentStore.url(for: attachment)
    }

    func deleteStocks(ids: Set<UUID>) {
        stocks.removeAll { ids.contains($0.id) }
        for id in ids {
            quoteErrors[id] = nil
            quoteSources[id] = nil
        }
        persist()
    }

    func upsertStockTransaction(_ transaction: StockTransaction, in stockID: UUID) -> Bool {
        guard let stockIndex = stocks.firstIndex(where: { $0.id == stockID }) else { return false }
        guard stocks[stockIndex].canApply(transaction) else { return false }
        if let transactionIndex = stocks[stockIndex].transactions.firstIndex(where: { $0.id == transaction.id }) {
            stocks[stockIndex].transactions[transactionIndex] = transaction
        } else {
            stocks[stockIndex].transactions.append(transaction)
        }
        persist()
        return true
    }

    func deleteStockTransactions(ids: Set<UUID>, from stockID: UUID) -> Bool {
        guard let stockIndex = stocks.firstIndex(where: { $0.id == stockID }) else { return false }
        let remaining = stocks[stockIndex].transactions.filter { !ids.contains($0.id) }
        guard remaining.reduce(Decimal.zero, { $0 + $1.signedShares }) >= 0 else { return false }
        stocks[stockIndex].transactions = remaining
        persist()
        return true
    }

    func upsertStockDividend(_ dividend: StockDividend, in stockID: UUID) {
        guard let stockIndex = stocks.firstIndex(where: { $0.id == stockID }) else { return }
        if let dividendIndex = stocks[stockIndex].dividends.firstIndex(where: { $0.id == dividend.id }) {
            stocks[stockIndex].dividends[dividendIndex] = dividend
        } else {
            stocks[stockIndex].dividends.append(dividend)
        }
        persist()
    }

    func deleteStockDividends(ids: Set<UUID>, from stockID: UUID) {
        guard let stockIndex = stocks.firstIndex(where: { $0.id == stockID }) else { return }
        stocks[stockIndex].dividends.removeAll { ids.contains($0.id) }
        persist()
    }

    func refreshStockQuotes() async {
        guard !isRefreshingQuotes else { return }
        isRefreshingQuotes = true
        quoteRefreshError = nil
        defer { isRefreshingQuotes = false }

        refreshExchangeRateIfNeeded()
        guard !stocks.isEmpty else { return }

        var failures: [UUID: String] = [:]
        var successCount = 0
        let stockSnapshot = stocks
        let refreshedQuotes = await quoteService.fetchQuotes(for: stockSnapshot)

        for stock in stockSnapshot {
            guard let quote = refreshedQuotes[stock.id] else {
                failures[stock.id] = "行情服务暂时不可用"
                continue
            }
            guard let index = stocks.firstIndex(where: { $0.id == stock.id }) else { continue }
            stocks[index].symbol = quote.symbol
            stocks[index].quoteName = quote.name
            stocks[index].latestPrice = quote.latestPrice
            stocks[index].previousClose = quote.previousClose
            stocks[index].changePercent = quote.changePercent
            stocks[index].lastQuoteAt = quote.updatedAt
            quoteSources[stock.id] = quote.source
            successCount += 1
        }

        quoteErrors = failures
        for id in failures.keys { quoteSources[id] = nil }
        if !failures.isEmpty {
            let firstReason = failures.values.first ?? "行情服务暂时不可用"
            quoteRefreshError = "\(failures.count) 只股票暂时无法刷新：\(firstReason)"
        }
        if successCount > 0 { persist() }
        if successCount > 0 { lastStockRefreshAt = Date() }
    }

    func refreshExchangeRateIfNeeded() {
        if let lastExchangeRateRequestAt {
            let retryInterval: TimeInterval = exchangeRateError == nil ? 30 * 60 : 5 * 60
            guard Date().timeIntervalSince(lastExchangeRateRequestAt) >= retryInterval else { return }
        }
        refreshExchangeRates()
    }

    func refreshExchangeRates() {
        guard !isRefreshingExchangeRate else { return }
        isRefreshingExchangeRate = true
        lastExchangeRateRequestAt = Date()
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshingExchangeRate = false }
            do {
                let rates = try await self.exchangeRateService.fetchRates()
                var buyingRateValues: [CurrencyCode: Decimal] = [.cny: 1]
                var sellingRateValues: [CurrencyCode: Decimal] = [.cny: 1]
                for rate in rates {
                    guard let currency = CurrencyCode(rawValue: rate.currencyCode) else { continue }
                    buyingRateValues[currency] = rate.renminbiBuyingPerUnit
                    sellingRateValues[currency] = rate.renminbiSellingPerUnit
                }
                guard let usdRate = buyingRateValues[.usd] else {
                    throw ForeignExchangeRateError.rateUnavailable
                }
                self.renminbiBuyingRates = buyingRateValues
                self.renminbiSellingRates = sellingRateValues
                self.usdRenminbiBuyingRate = usdRate
                self.exchangeRateUpdatedAt = rates.map(\.updatedAt).max()
                self.exchangeRateError = nil
                self.defaults.set(
                    NSDecimalNumber(decimal: usdRate).stringValue,
                    forKey: "stock-usd-cny-buying-rate-v1"
                )
                self.defaults.set(
                    self.exchangeRateUpdatedAt,
                    forKey: "stock-usd-cny-buying-rate-date-v1"
                )
                self.defaults.set(
                    buyingRateValues.reduce(into: [String: String]()) { result, entry in
                        result[entry.key.rawValue] = NSDecimalNumber(decimal: entry.value).stringValue
                    },
                    forKey: "boc-currency-buying-rates-v1"
                )
                self.defaults.set(
                    sellingRateValues.reduce(into: [String: String]()) { result, entry in
                        result[entry.key.rawValue] = NSDecimalNumber(decimal: entry.value).stringValue
                    },
                    forKey: "boc-currency-selling-rates-v1"
                )
            } catch {
                self.exchangeRateError = error.localizedDescription
            }
        }
    }

    func makeBackupDocument(password: String) throws -> VaultBackupDocument {
        let medicalRecordsWithAttachments = try attachmentStore.recordsForBackup(medicalRecords)
        let cardsWithAttachments = try attachmentStore.cardsForBackup(cards)
        let vault = VaultData(
            accounts: accounts,
            cards: cardsWithAttachments,
            stocks: stocks,
            currencyExchangeRecords: currencyExchangeRecords,
            medicalRecords: medicalRecordsWithAttachments,
            hospitalProfiles: hospitalProfiles
        )
        let data = try VaultBackupCrypto.makeBackup(from: vault, password: password)
        return VaultBackupDocument(data: data)
    }

    func restoreBackup(from data: Data, password: String) throws {
        var vault = Self.initializingHospitalDirectory(
            in: try VaultBackupCrypto.restoreVault(from: data, password: password)
        )
        vault.medicalRecords = try attachmentStore.restoreAttachments(in: vault.medicalRecords)
        vault.cards = try attachmentStore.restoreAttachments(in: vault.cards)
        try secureStore.saveVault(vault)
        applyVault(vault)
        quoteErrors = [:]
        quoteSources = [:]
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            cards[index].statements.compactMap(\.attachment).forEach(attachmentStore.delete)
        }
        cards.remove(atOffsets: offsets)
        persist()
    }

    func delete(_ card: BankCard) {
        card.statements.compactMap(\.attachment).forEach(attachmentStore.delete)
        cards.removeAll { $0.id == card.id }
        persist()
    }
    private func persist() {
        try? secureStore.saveVault(
            VaultData(
                accounts: accounts,
                cards: cards,
                stocks: stocks,
                currencyExchangeRecords: currencyExchangeRecords,
                medicalRecords: medicalRecords,
                hospitalProfiles: hospitalProfiles
            )
        )
    }
}

private extension VaultData {
    var isEmpty: Bool {
        accounts.isEmpty
            && cards.isEmpty
            && stocks.isEmpty
            && currencyExchangeRecords.isEmpty
            && medicalRecords.isEmpty
            && hospitalProfiles.isEmpty
    }
}
