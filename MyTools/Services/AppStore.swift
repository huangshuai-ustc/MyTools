import Foundation
import Combine
import OSLog
import UniformTypeIdentifiers

private let startupLogger = Logger(
    subsystem: AppMetadata.bundleIdentifier,
    category: "Startup"
)

private enum AppStoreDefaultsKey {
    static let usdBuyingRate = "stock-usd-cny-buying-rate-v1"
    static let exchangeRateDate = "stock-usd-cny-buying-rate-date-v1"
    static let buyingRates = "boc-currency-buying-rates-v1"
    static let sellingRates = "boc-currency-selling-rates-v1"
    static let stockRefreshDate = "stock-last-refresh-date-v1"
    static let stockRefreshDatesByMarket = "stock-last-refresh-dates-by-market-v1"
}

private struct AppStoreInitialSnapshot: @unchecked Sendable {
    let vault: VaultData
    let secretItems: [SecretItem]
    let vaultByteCount: Int
    let vaultSource: String
    let canPersistVault: Bool
    let readDurationMilliseconds: Double
    let decodeDurationMilliseconds: Double
    let loadDurationMilliseconds: Double

    static func load() -> Self {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = SecureStore().loadVaultWithMetrics()
        return Self(
            vault: result.vault,
            secretItems: result.secrets,
            vaultByteCount: result.byteCount,
            vaultSource: result.source,
            canPersistVault: result.canPersist,
            readDurationMilliseconds: result.readMilliseconds,
            decodeDurationMilliseconds: result.decodeMilliseconds,
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
        let usdRate = defaults.string(forKey: AppStoreDefaultsKey.usdBuyingRate)
            .flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        var buyingRates = decimalRates(
            from: defaults.dictionary(forKey: AppStoreDefaultsKey.buyingRates) as? [String: String]
        )
        let sellingRates = decimalRates(
            from: defaults.dictionary(forKey: AppStoreDefaultsKey.sellingRates) as? [String: String]
        )
        if let usdRate { buyingRates[.usd] = usdRate }

        return Self(
            usdRenminbiBuyingRate: usdRate,
            renminbiBuyingRates: buyingRates,
            renminbiSellingRates: sellingRates,
            exchangeRateUpdatedAt: defaults.object(
                forKey: AppStoreDefaultsKey.exchangeRateDate
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
    @Published private(set) var currencyRateAlerts: [CurrencyRateAlert]
    @Published private(set) var stockPriceAlerts: [StockPriceAlert]
    @Published private(set) var medicalRecords: [MedicalRecord]
    @Published private(set) var hospitalProfiles: [HospitalProfile]
    @Published private(set) var secretItems: [SecretItem]
    @Published private(set) var isRefreshingQuotes = false
    @Published private(set) var quoteRefreshError: String?
    @Published private(set) var lastStockRefreshAt: Date?
    @Published private(set) var lastStockRefreshAtByMarket: [StockMarket: Date] = [:]
    @Published private(set) var quoteErrors: [UUID: String] = [:]
    @Published private(set) var quoteSources: [UUID: String] = [:]
    @Published private(set) var usdRenminbiBuyingRate: Decimal?
    @Published private(set) var renminbiBuyingRates: [CurrencyCode: Decimal] = [:]
    @Published private(set) var renminbiSellingRates: [CurrencyCode: Decimal] = [:]
    @Published private(set) var exchangeRateUpdatedAt: Date?
    @Published private(set) var exchangeRateError: String?
    @Published private(set) var isRefreshingExchangeRate = false
    @Published private(set) var isInitialDataLoaded = false
    @Published private(set) var isVaultLoadFailurePresented = false
    @Published private(set) var persistenceError: String?
    private let persistence = VaultPersistenceCoordinator()
    private let quoteService = StockQuoteService()
    private let exchangeRateService = ForeignExchangeRateService()
    private let attachmentStore = AttachmentStore()
    private let defaults = UserDefaults.standard
    private weak var moduleSettings: ToolModuleSettings?
    private var lastExchangeRateRequestAt: Date?
    private var exchangeRateTask: Task<Void, Never>?
    private var isRestoringBackup = false
    private var canPersistVault = true
    private var didLogPersistenceBlocked = false

    init(moduleSettings: ToolModuleSettings? = nil) {
        self.moduleSettings = moduleSettings
        accounts = []
        cards = []
        stocks = []
        currencyExchangeRecords = []
        currencyRateAlerts = []
        stockPriceAlerts = []
        medicalRecords = []
        hospitalProfiles = []
        secretItems = []
        renminbiBuyingRates = [.cny: 1]
        renminbiSellingRates = [.cny: 1]
        lastStockRefreshAt = defaults.object(forKey: AppStoreDefaultsKey.stockRefreshDate) as? Date
        lastStockRefreshAtByMarket = Self.loadStockRefreshDatesByMarket(from: defaults)
        if let latestMarketRefresh = lastStockRefreshAtByMarket.values.max(),
           latestMarketRefresh > (lastStockRefreshAt ?? .distantPast) {
            lastStockRefreshAt = latestMarketRefresh
        }

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

    func attach(moduleSettings: ToolModuleSettings) {
        self.moduleSettings = moduleSettings
    }
    func moduleVisibilityChanged(_ module: ToolModule, isVisible: Bool) {
        guard !isVisible else {
            if module == .myStocks {
                StockRefreshCoordinator.shared.refreshEligibilityChanged()
            } else if module == .currencyExchange {
                refreshExchangeRateIfNeeded()
            }
            return
        }

        if module == .currencyExchange {
            exchangeRateTask?.cancel()
            exchangeRateTask = nil
            lastExchangeRateRequestAt = nil
            isRefreshingExchangeRate = false
        }
        StockRefreshCoordinator.shared.refreshEligibilityChanged()
    }

    private func isModuleVisible(_ module: ToolModule) -> Bool {
        moduleSettings?.isVisible(module) ?? true
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

    private func applyInitialSnapshot(_ snapshot: AppStoreInitialSnapshot) {
        applyVault(snapshot.vault)
        secretItems = snapshot.secretItems
        canPersistVault = snapshot.canPersistVault
        if isModuleVisible(.healthRecords) {
            synchronizeLoadedInpatientDailyRecords()
            synchronizeHospitalProfilesWithMedicalRecords()
        }
        isVaultLoadFailurePresented = !snapshot.canPersistVault
        didLogPersistenceBlocked = false
        isInitialDataLoaded = true
        StockRefreshCoordinator.shared.refreshEligibilityChanged()
        let loadSummary = "Local vault loaded from \(snapshot.vaultSource): \(snapshot.vaultByteCount) bytes; read \(snapshot.readDurationMilliseconds) ms, decode \(snapshot.decodeDurationMilliseconds) ms, total \(snapshot.loadDurationMilliseconds) ms"
        startupLogger.info("\(loadSummary, privacy: .public)")
        DiagnosticLogger.shared.log(.startup, loadSummary)
    }

    private func applyCachedRatesSnapshot(_ snapshot: AppStoreCachedRatesSnapshot) {
        guard isModuleVisible(.currencyExchange) else { return }
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
        currencyRateAlerts = vault.currencyRateAlerts
        stockPriceAlerts = vault.stockPriceAlerts
        medicalRecords = vault.medicalRecords
        hospitalProfiles = vault.hospitalProfiles
    }

    func upsertAccount(_ account: BankAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
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
        var attached = card
        attached.accountID = account.id
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

    func upsertCurrencyRateAlert(_ alert: CurrencyRateAlert) {
        guard alert.amount > 0, alert.threshold > 0 else { return }
        if let index = currencyRateAlerts.firstIndex(where: { $0.id == alert.id }) {
            currencyRateAlerts[index] = alert
        } else {
            currencyRateAlerts.append(alert)
        }
        AppNotificationService.shared.clearState(for: alert.id)
        persist()
    }

    func deleteCurrencyRateAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        currencyRateAlerts.removeAll { alert in
            if ids.contains(alert.id) {
                AppNotificationService.shared.clearState(for: alert.id)
                return true
            }
            return false
        }
        persist()
    }

    func upsertStockPriceAlert(_ alert: StockPriceAlert) {
        guard let stockID = alert.stockID,
              stocks.contains(where: { $0.id == stockID }),
              alert.threshold > 0 else { return }
        if let index = stockPriceAlerts.firstIndex(where: { $0.id == alert.id }) {
            stockPriceAlerts[index] = alert
        } else {
            stockPriceAlerts.append(alert)
        }
        AppNotificationService.shared.clearState(for: alert.id)
        persist()
        StockRefreshCoordinator.shared.refreshEligibilityChanged()
    }

    func deleteStockPriceAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        stockPriceAlerts.removeAll { alert in
            if ids.contains(alert.id) {
                AppNotificationService.shared.clearState(for: alert.id)
                return true
            }
            return false
        }
        persist()
        StockRefreshCoordinator.shared.refreshEligibilityChanged()
    }

    func deleteCurrencyExchangeRecords(ids: Set<UUID>) {
        currencyExchangeRecords.removeAll { ids.contains($0.id) }
        persist()
    }

    func upsertSecret(_ item: SecretItem) {
        guard !isRestoringBackup else { return }
        var storedItem = item
        storedItem.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        storedItem.tags = item.tags.trimmingCharacters(in: .whitespacesAndNewlines)
        storedItem.updatedAt = Date()
        if let index = secretItems.firstIndex(where: { $0.id == storedItem.id }) {
            let retainedAttachmentIDs = Set(storedItem.attachments.map(\.id))
            for attachment in secretItems[index].attachments
            where !retainedAttachmentIDs.contains(attachment.id) {
                attachmentStore.delete(attachment)
            }
            storedItem.createdAt = secretItems[index].createdAt
            secretItems[index] = storedItem
        } else {
            secretItems.append(storedItem)
        }
        persist()
    }

    func deleteSecrets(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in secretItems where ids.contains(item.id) {
            item.attachments.forEach(attachmentStore.delete)
        }
        secretItems.removeAll { ids.contains($0.id) }
        persist()
    }

    func upsertMedicalRecord(_ record: MedicalRecord) {
        var storedRecord = record
        storedRecord.normalizeInstitutionClassification()
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
        synchronizeInpatientDailyRecords(for: storedRecord)
        rememberHospital(from: storedRecord)
        persist()
    }

    func hospitalProfile(named name: String, type: MedicalInstitutionType? = nil) -> HospitalProfile? {
        let key = hospitalNameKey(name)
        return hospitalProfiles.first {
            guard hospitalNameKey($0.name) == key else { return false }
            guard let type else { return true }
            return $0.supports(type)
        }
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
        storedProfile.normalizeClassification()
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
        where namesToMatch.contains(hospitalNameKey(medicalRecords[index].hospital)) {
            medicalRecords[index].hospital = storedProfile.name
            if storedProfile.supports(medicalRecords[index].institutionType), medicalRecords[index].institutionType == .hospital {
                medicalRecords[index].hospitalLevel = storedProfile.level
                medicalRecords[index].hospitalGrade = storedProfile.grade
                medicalRecords[index].hospitalCategory = storedProfile.category
            }
            medicalRecords[index].normalizeInstitutionClassification()
            medicalRecords[index].updatedAt = Date()
        }
        persist()
        return true
    }

    func deleteHospitalProfiles(ids: Set<UUID>) {
        hospitalProfiles.removeAll { ids.contains($0.id) }
        persist()
    }

    private func synchronizeInpatientDailyRecords(for parent: MedicalRecord) {
        guard parent.isInpatientEpisode else { return }

        let calendar = inpatientCalendar
        let startDate = MedicalRecord.normalizedDate(parent.date)
        let requestedEndDate = MedicalRecord.normalizedDate(parent.inpatientEndDate ?? parent.date)
        let endDate = max(startDate, requestedEndDate)

        let staleEmptyIDs = Set(
            medicalRecords
                .filter { record in
                    guard record.parentRecordID == parent.id,
                          record.isInpatientDailyRecord,
                          !record.hasInpatientDailyContent else { return false }
                    let date = MedicalRecord.normalizedDate(record.date)
                    return date < startDate || date > endDate
                }
                .map(\.id)
        )
        if !staleEmptyIDs.isEmpty {
            medicalRecords.removeAll { staleEmptyIDs.contains($0.id) }
        }

        let existingDates = Set(
            medicalRecords
                .filter { $0.parentRecordID == parent.id && $0.isInpatientDailyRecord }
                .map { MedicalRecord.normalizedDate($0.date) }
        )

        var currentDate = startDate
        while currentDate <= endDate {
            if !existingDates.contains(currentDate) {
                medicalRecords.append(MedicalRecord(inpatientDayFor: parent, date: currentDate))
            }
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = MedicalRecord.normalizedDate(nextDate)
        }
    }

    private func synchronizeLoadedInpatientDailyRecords() {
        let previousCount = medicalRecords.count
        let inpatientEpisodes = medicalRecords.filter(\.isInpatientEpisode)
        inpatientEpisodes.forEach { synchronizeInpatientDailyRecords(for: $0) }
        guard medicalRecords.count != previousCount else { return }
        persist()
    }

    private var inpatientCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private func rememberHospital(from record: MedicalRecord) {
        guard !record.hospital.isEmpty else { return }
        if let index = hospitalProfiles.firstIndex(where: {
            hospitalNameKey($0.name) == hospitalNameKey(record.hospital)
        }) {
            var didChange = false
            if !hospitalProfiles[index].supports(record.institutionType) {
                hospitalProfiles[index].institutionTypes.insert(record.institutionType)
                didChange = true
            }
            if record.institutionType == .hospital {
                if record.hospitalLevel != .unspecified {
                    if hospitalProfiles[index].level != record.hospitalLevel {
                        hospitalProfiles[index].level = record.hospitalLevel
                        didChange = true
                    }
                }
                if record.hospitalGrade != .unspecified {
                    if hospitalProfiles[index].grade != record.hospitalGrade {
                        hospitalProfiles[index].grade = record.hospitalGrade
                        didChange = true
                    }
                }
                if record.hospitalCategory != .unspecified {
                    if hospitalProfiles[index].category != record.hospitalCategory {
                        hospitalProfiles[index].category = record.hospitalCategory
                        didChange = true
                    }
                }
            }
            let previousProfile = hospitalProfiles[index]
            hospitalProfiles[index].normalizeClassification()
            if hospitalProfiles[index] != previousProfile { didChange = true }
            if didChange {
                hospitalProfiles[index].updatedAt = Date()
            }
        } else {
            hospitalProfiles.append(HospitalProfile(record: record))
        }
    }

    private func synchronizeHospitalProfilesWithMedicalRecords() {
        let previousRecords = medicalRecords
        medicalRecords = medicalRecords.map { record in
            var normalizedRecord = record
            normalizedRecord.normalizeInstitutionClassification()
            return normalizedRecord
        }
        let previousProfiles = hospitalProfiles
        medicalRecords.forEach { rememberHospital(from: $0) }
        guard hospitalProfiles != previousProfiles || medicalRecords != previousRecords else { return }
        persist()
    }

    private func hospitalNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
    }

    func deleteMedicalRecords(ids: Set<UUID>) {
        var recordIDsToDelete = ids
        let childrenByParentID = Dictionary(
            grouping: medicalRecords.compactMap { record -> (UUID, UUID)? in
                record.parentRecordID.map { ($0, record.id) }
            },
            by: \.0
        ).mapValues { $0.map(\.1) }
        var pendingParentIDs = Array(ids)
        var nextParentIndex = 0
        while nextParentIndex < pendingParentIDs.count {
            let parentID = pendingParentIDs[nextParentIndex]
            nextParentIndex += 1
            for childID in childrenByParentID[parentID, default: []]
            where recordIDsToDelete.insert(childID).inserted {
                pendingParentIDs.append(childID)
            }
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

    func renameAttachment(_ attachment: FileAttachment, to fileName: String) throws -> FileAttachment {
        try attachmentStore.rename(attachment, to: fileName)
    }

    func importSecretAttachment(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .image)
                || attachment.contentType.conforms(to: .pdf) else {
            attachmentStore.delete(attachment)
            throw AttachmentStoreError.invalidFile
        }
        return attachment
    }

    func saveSecretPhoto(data: Data, fileName: String, contentType: UTType) throws -> FileAttachment {
        guard contentType.conforms(to: .image) else {
            throw AttachmentStoreError.invalidFile
        }
        return try attachmentStore.save(data: data, originalFileName: fileName, contentType: contentType)
    }

    func secretAttachmentURL(for attachment: FileAttachment) -> URL {
        attachmentStore.url(for: attachment)
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
        stockPriceAlerts.removeAll { alert in
            guard let stockID = alert.stockID, ids.contains(stockID) else { return false }
            AppNotificationService.shared.clearState(for: alert.id)
            return true
        }
        for id in ids {
            quoteErrors[id] = nil
            quoteSources[id] = nil
        }
        persist()
        StockRefreshCoordinator.shared.refreshEligibilityChanged()
    }

    func upsertStockTransaction(_ transaction: StockTransaction, in stockID: UUID) -> Bool {
        guard let stockIndex = stocks.firstIndex(where: { $0.id == stockID }) else { return false }

        var candidate = stocks[stockIndex]
        let existingTransaction = candidate.transactions.first { $0.id == transaction.id }
        if let existingTransaction {
            candidate.normalizeTransactionDay(containing: existingTransaction.tradedAt)
        }

        var storedTransaction = transaction
        storedTransaction.tradedAt = StockTransaction.normalizedDate(transaction.tradedAt)
        let staysOnSameDay = existingTransaction.map {
            StockTransaction.isSameDay($0.tradedAt, transaction.tradedAt)
        } ?? false
        if staysOnSameDay,
           let normalizedExisting = candidate.transactions.first(where: { $0.id == transaction.id }) {
            storedTransaction.dayOrder = normalizedExisting.dayOrder
        } else {
            storedTransaction.dayOrder = nil
        }

        if let transactionIndex = candidate.transactions.firstIndex(where: { $0.id == transaction.id }) {
            candidate.transactions[transactionIndex] = storedTransaction
        } else {
            candidate.transactions.append(storedTransaction)
        }
        candidate.normalizeTransactionDay(
            containing: storedTransaction.tradedAt,
            appending: staysOnSameDay ? nil : storedTransaction.id
        )
        guard candidate.hasValidTransactionOrder else { return false }

        stocks[stockIndex] = candidate
        persist()
        return true
    }

    func deleteStockTransactions(ids: Set<UUID>, from stockID: UUID) -> Bool {
        guard let stockIndex = stocks.firstIndex(where: { $0.id == stockID }) else { return false }
        var candidate = stocks[stockIndex]
        let affectedDates = candidate.transactions
            .filter { ids.contains($0.id) }
            .map(\.tradedAt)
        candidate.transactions.removeAll { ids.contains($0.id) }
        affectedDates.forEach { candidate.normalizeTransactionDay(containing: $0) }
        guard candidate.hasValidTransactionOrder else { return false }
        stocks[stockIndex] = candidate
        persist()
        return true
    }

    func reorderStockTransactions(_ orderedIDs: [UUID], in stockID: UUID) -> Bool {
        guard let stockIndex = stocks.firstIndex(where: { $0.id == stockID }),
              orderedIDs.count > 1,
              Set(orderedIDs).count == orderedIDs.count else { return false }

        var candidate = stocks[stockIndex]
        let selectedTransactions = orderedIDs.compactMap { transactionID in
            candidate.transactions.first { $0.id == transactionID }
        }
        guard selectedTransactions.count == orderedIDs.count,
              let date = selectedTransactions.first?.tradedAt,
              selectedTransactions.allSatisfy({ StockTransaction.isSameDay($0.tradedAt, date) }) else {
            return false
        }
        let transactionsOnDate = candidate.transactions.filter {
            StockTransaction.isSameDay($0.tradedAt, date)
        }
        guard Set(transactionsOnDate.map(\.id)) == Set(orderedIDs) else { return false }

        let normalizedDate = StockTransaction.normalizedDate(date)
        for (dayOrder, transactionID) in orderedIDs.enumerated() {
            guard let index = candidate.transactions.firstIndex(where: { $0.id == transactionID }) else {
                return false
            }
            candidate.transactions[index].tradedAt = normalizedDate
            candidate.transactions[index].dayOrder = dayOrder
        }
        guard candidate.hasValidTransactionOrder else { return false }

        stocks[stockIndex] = candidate
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

    func refreshStockQuotes(
        for market: StockMarket? = nil,
        forcedMarkets: Set<StockMarket> = [],
        allowClosedMissingData: Bool = true
    ) async {
        guard isModuleVisible(.myStocks) else { return }
        guard !isRefreshingQuotes else { return }
        guard !Task.isCancelled else { return }

        let refreshDate = Date()
        let stockSnapshot = stocks.filter { stock in
            guard stock.hasConfiguredSymbol else { return false }
            if let market, stock.market != market { return false }
            let quoteDataMissing = stock.latestPrice == nil
                || stock.latestPrice.map { $0 <= 0 } == true
                || stock.lastQuoteAt == nil
            return forcedMarkets.contains(stock.market)
                || (allowClosedMissingData && quoteDataMissing)
                || StockMarketTradingCalendar.isOpen(stock.market, at: refreshDate)
        }
        guard !stockSnapshot.isEmpty else { return }
        isRefreshingQuotes = true
        quoteRefreshError = nil
        defer { isRefreshingQuotes = false }
        if !Task.isCancelled {
            refreshExchangeRateIfNeeded()
        }

        var failures: [UUID: String] = [:]
        var successCount = 0
        let refreshedQuotes = await quoteService.fetchQuotes(for: stockSnapshot)
        guard !Task.isCancelled else { return }
        guard isModuleVisible(.myStocks) else { return }

        let stockIndices = Dictionary(
            uniqueKeysWithValues: stocks.indices.map { (stocks[$0].id, $0) }
        )
        var didChangePersistedQuote = false
        var refreshedMarkets = Set<StockMarket>()
        for stock in stockSnapshot {
            guard let quote = refreshedQuotes[stock.id] else {
                failures[stock.id] = "行情服务暂时不可用"
                continue
            }
            guard let index = stockIndices[stock.id] else { continue }
            let previous = stocks[index]
            stocks[index].symbol = quote.symbol
            let quoteName = quote.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoteName.isEmpty {
                stocks[index].quoteName = quoteName
            }
            stocks[index].latestPrice = quote.latestPrice
            stocks[index].previousClose = quote.previousClose
            stocks[index].changePercent = quote.changePercent
            stocks[index].lastQuoteAt = quote.updatedAt
            if previous.symbol != quote.symbol
                || (!quoteName.isEmpty && previous.quoteName != quoteName)
                || previous.latestPrice != quote.latestPrice
                || previous.previousClose != quote.previousClose
                || previous.changePercent != quote.changePercent
                || previous.lastQuoteAt != quote.updatedAt {
                didChangePersistedQuote = true
            }
            quoteSources[stock.id] = quote.source
            refreshedMarkets.insert(stock.market)
            successCount += 1
        }

        quoteErrors = failures
        for id in failures.keys { quoteSources[id] = nil }
        if !failures.isEmpty {
            let firstReason = failures.values.first ?? "行情服务暂时不可用"
            quoteRefreshError = "\(failures.count) 个标的暂时无法刷新：\(firstReason)"
            DiagnosticLogger.shared.log(
                .stockQuote,
                "行情刷新完成 success=\(successCount) failure=\(failures.count)",
                level: .warning
            )
        }
        if successCount > 0 {
            if didChangePersistedQuote {
                persist()
            }
            let refreshedAt = Date()
            for market in refreshedMarkets {
                lastStockRefreshAtByMarket[market] = refreshedAt
            }
            lastStockRefreshAt = max(lastStockRefreshAt ?? .distantPast, refreshedAt)
            persistStockRefreshDates()
            evaluateStockPriceAlerts()
        }
    }

    func lastStockRefreshAt(for market: StockMarket?) -> Date? {
        if let market {
            return lastStockRefreshAtByMarket[market]
        }
        return lastStockRefreshAtByMarket.values.max() ?? lastStockRefreshAt
    }

    func latestStockQuoteAt(for market: StockMarket) -> Date? {
        stocks
            .filter { $0.market == market && $0.hasConfiguredSymbol }
            .compactMap { $0.lastQuoteAt }
            .max()
    }

    private static func loadStockRefreshDatesByMarket(
        from defaults: UserDefaults
    ) -> [StockMarket: Date] {
        guard let values = defaults.dictionary(
            forKey: AppStoreDefaultsKey.stockRefreshDatesByMarket
        ) else { return [:] }

        return values.reduce(into: [StockMarket: Date]()) { result, entry in
            guard let market = StockMarket(rawValue: entry.key),
                  let date = entry.value as? Date else { return }
            result[market] = date
        }
    }

    private func persistStockRefreshDates() {
        if let lastStockRefreshAt {
            defaults.set(lastStockRefreshAt, forKey: AppStoreDefaultsKey.stockRefreshDate)
        } else {
            defaults.removeObject(forKey: AppStoreDefaultsKey.stockRefreshDate)
        }
        let values = lastStockRefreshAtByMarket.reduce(into: [String: Date]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        defaults.set(values, forKey: AppStoreDefaultsKey.stockRefreshDatesByMarket)
    }

    func refreshExchangeRateIfNeeded() {
        guard isModuleVisible(.currencyExchange) else { return }
        if let lastExchangeRateRequestAt {
            let retryInterval: TimeInterval = exchangeRateError == nil ? 60 * 60 : 5 * 60
            guard Date().timeIntervalSince(lastExchangeRateRequestAt) >= retryInterval else { return }
        }
        refreshExchangeRates()
    }

    func refreshExchangeRates() {
        guard isModuleVisible(.currencyExchange) else { return }
        guard !isRefreshingExchangeRate else { return }
        isRefreshingExchangeRate = true
        lastExchangeRateRequestAt = Date()
        exchangeRateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshingExchangeRate = false }
            do {
                let rates = try await self.exchangeRateService.fetchRates()
                guard self.isModuleVisible(.currencyExchange), !Task.isCancelled else { return }
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
                self.evaluateCurrencyRateAlerts()
                self.defaults.set(
                    NSDecimalNumber(decimal: usdRate).stringValue,
                    forKey: AppStoreDefaultsKey.usdBuyingRate
                )
                self.defaults.set(
                    self.exchangeRateUpdatedAt,
                    forKey: AppStoreDefaultsKey.exchangeRateDate
                )
                self.defaults.set(
                    buyingRateValues.reduce(into: [String: String]()) { result, entry in
                        result[entry.key.rawValue] = NSDecimalNumber(decimal: entry.value).stringValue
                    },
                    forKey: AppStoreDefaultsKey.buyingRates
                )
                self.defaults.set(
                    sellingRateValues.reduce(into: [String: String]()) { result, entry in
                        result[entry.key.rawValue] = NSDecimalNumber(decimal: entry.value).stringValue
                    },
                    forKey: AppStoreDefaultsKey.sellingRates
                )
            } catch {
                guard self.isModuleVisible(.currencyExchange), !Task.isCancelled else { return }
                self.exchangeRateError = error.localizedDescription
                DiagnosticLogger.logError(
                    .exchangeRate,
                    operation: "外汇牌价刷新失败",
                    error: error
                )
            }
        }
    }

    func makeBackupDocument(password: String) async throws -> VaultBackupDocument {
        let includedModules = Set(
            ToolModule.allCases.filter { isModuleVisible($0) }
        )
        var snapshot = currentVaultData()
        if !includedModules.contains(.personalFinance) {
            snapshot.accounts = []
            snapshot.cards = []
        }
        if !includedModules.contains(.myStocks) {
            snapshot.stocks = []
            snapshot.stockPriceAlerts = []
        }
        if !includedModules.contains(.currencyExchange) {
            snapshot.currencyExchangeRecords = []
            snapshot.currencyRateAlerts = []
        }
        if !includedModules.contains(.healthRecords) {
            snapshot.medicalRecords = []
            snapshot.hospitalProfiles = []
        }
        let secretSnapshot = includedModules.contains(.secrets) ? secretItems : []
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                let attachmentStore = AttachmentStore()
                var vault = snapshot
                vault.medicalRecords = try attachmentStore.recordsForBackup(vault.medicalRecords)
                vault.cards = try attachmentStore.cardsForBackup(vault.cards)
                let secrets = try attachmentStore.secretsForBackup(secretSnapshot)
                return try VaultBackupCrypto.makeBackup(
                    from: vault,
                    secrets: secrets,
                    includedModules: includedModules,
                    password: password
                )
            }.value
        } catch {
            DiagnosticLogger.logError(.backup, operation: "导出加密备份失败", error: error)
            throw error
        }
        return VaultBackupDocument(data: data)
    }

    func restoreBackup(from data: Data, password: String) async throws {
        isRestoringBackup = true
        defer { isRestoringBackup = false }
        let restoredPayload: VaultBackupPayload
        do {
            restoredPayload = try await Task.detached(priority: .userInitiated) {
                let attachmentStore = AttachmentStore()
                var payload = try VaultBackupCrypto.restorePayload(from: data, password: password)
                if payload.includedModules.contains(.healthRecords) {
                    payload.vault.medicalRecords = try attachmentStore.restoreAttachments(
                        in: payload.vault.medicalRecords
                    )
                }
                if payload.includedModules.contains(.personalFinance) {
                    payload.vault.cards = try attachmentStore.restoreAttachments(in: payload.vault.cards)
                }
                if payload.includedModules.contains(.secrets) {
                    payload.secrets = try attachmentStore.restoreAttachments(in: payload.secrets)
                }
                return payload
            }.value
        } catch {
            DiagnosticLogger.logError(.backup, operation: "导入加密备份失败", error: error)
            throw error
        }
        let mergedPayload = mergeBackupPayload(restoredPayload)
        do {
            try await Task.detached(priority: .userInitiated) { [persistence] in
                try persistence.saveImmediately(
                    mergedPayload.vault,
                    secrets: mergedPayload.secrets
                )
            }.value
        } catch {
            DiagnosticLogger.logError(.backup, operation: "保存增量备份导入结果失败", error: error)
            throw error
        }
        applyVault(mergedPayload.vault)
        secretItems = mergedPayload.secrets
        canPersistVault = true
        didLogPersistenceBlocked = false
        persistenceError = nil
        if restoredPayload.includedModules.contains(.myStocks) {
            quoteErrors = [:]
            quoteSources = [:]
            for alert in restoredPayload.vault.stockPriceAlerts {
                AppNotificationService.shared.clearState(for: alert.id)
            }
        }
        if restoredPayload.includedModules.contains(.currencyExchange) {
            for alert in restoredPayload.vault.currencyRateAlerts {
                AppNotificationService.shared.clearState(for: alert.id)
            }
        }
        StockRefreshCoordinator.shared.refreshEligibilityChanged()
    }

    func flushPendingPersistence() async {
        if let errorCode = await persistence.flush() {
            persistenceError = "本地数据未能保存（错误码：\(errorCode)）。原有档案仍然保留，请导出调试日志检查。"
        }
    }

    func dismissVaultLoadFailure() {
        isVaultLoadFailurePresented = false
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    private func mergeBackupPayload(_ imported: VaultBackupPayload) -> VaultBackupPayload {
        let modules = imported.includedModules
        var merged = currentVaultData()
        if modules.contains(.personalFinance) {
            merged.accounts = mergeByID(local: accounts, imported: imported.vault.accounts)
            merged.cards = mergeByID(local: cards, imported: imported.vault.cards)
        }
        if modules.contains(.myStocks) {
            merged.stocks = mergeByID(local: stocks, imported: imported.vault.stocks)
            merged.stockPriceAlerts = mergeByID(
                local: stockPriceAlerts,
                imported: imported.vault.stockPriceAlerts
            )
        }
        if modules.contains(.currencyExchange) {
            merged.currencyExchangeRecords = mergeByID(
                local: currencyExchangeRecords,
                imported: imported.vault.currencyExchangeRecords
            )
            merged.currencyRateAlerts = mergeByID(
                local: currencyRateAlerts,
                imported: imported.vault.currencyRateAlerts
            )
        }
        if modules.contains(.healthRecords) {
            merged.medicalRecords = mergeByID(local: medicalRecords, imported: imported.vault.medicalRecords)
            merged.hospitalProfiles = mergeByID(local: hospitalProfiles, imported: imported.vault.hospitalProfiles)
        }
        let secrets = modules.contains(.secrets)
            ? mergeByID(local: secretItems, imported: imported.secrets)
            : secretItems
        return VaultBackupPayload(vault: merged, secrets: secrets, includedModules: modules)
    }

    private func mergeByID<Element: Identifiable>(
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
        guard !isRestoringBackup, canPersistVault else {
            if !canPersistVault, !didLogPersistenceBlocked {
                didLogPersistenceBlocked = true
                DiagnosticLogger.shared.log(
                    .persistence,
                    "本地存档未成功读取，已拦截写入以保护原文件",
                    level: .error
                )
            }
            return
        }
        persistence.schedule(currentVaultData(), secrets: secretItems)
    }

    private func currentVaultData() -> VaultData {
        VaultData(
            accounts: accounts,
            cards: cards,
            stocks: stocks,
            currencyExchangeRecords: currencyExchangeRecords,
            medicalRecords: medicalRecords,
            hospitalProfiles: hospitalProfiles,
            currencyRateAlerts: currencyRateAlerts,
            stockPriceAlerts: stockPriceAlerts
        )
    }

    private func evaluateCurrencyRateAlerts() {
        guard isModuleVisible(.currencyExchange) else { return }
        var triggeredAlertIDs = Set<UUID>()
        for alert in currencyRateAlerts {
            guard alert.isEnabled else {
                _ = AppNotificationService.shared.shouldSend(for: alert.id, condition: false)
                continue
            }
            guard let value = alert.convertedValue(using: renminbiBuyingRates) else { continue }
            let condition = alert.direction.matches(value, threshold: alert.threshold)
            guard AppNotificationService.shared.shouldSend(for: alert.id, condition: condition) else {
                continue
            }
            let valueText = CurrencyExchangeValueFormatter.amount(value, currency: .cny)
            let thresholdText = CurrencyExchangeValueFormatter.amount(alert.threshold, currency: .cny)
            AppNotificationService.shared.send(
                title: "换汇价格提醒",
                body: "\(CurrencyExchangeValueFormatter.amount(alert.amount, currency: alert.currency)) 约合 \(valueText)，已\(alert.direction.title) \(thresholdText)。",
                ruleID: alert.id
            )
            triggeredAlertIDs.insert(alert.id)
        }
        if !triggeredAlertIDs.isEmpty {
            disableCurrencyRateAlerts(ids: triggeredAlertIDs)
        }
    }

    private func evaluateStockPriceAlerts() {
        guard isModuleVisible(.myStocks) else { return }
        var triggeredAlertIDs = Set<UUID>()
        for alert in stockPriceAlerts {
            guard alert.isEnabled else {
                _ = AppNotificationService.shared.shouldSend(for: alert.id, condition: false)
                continue
            }
            guard let stockID = alert.stockID,
                  let stock = stocks.first(where: { $0.id == stockID }),
                  let price = stock.latestPrice else { continue }
            let condition = alert.direction.matches(price, threshold: alert.threshold)
            guard AppNotificationService.shared.shouldSend(for: alert.id, condition: condition) else {
                continue
            }
            let priceText = StockValueFormatter.price(price, currencyCode: stock.market.currencyCode)
            let thresholdText = StockValueFormatter.price(alert.threshold, currencyCode: stock.market.currencyCode)
            AppNotificationService.shared.send(
                title: "股票价格提醒",
                body: "\(stock.displayName)（\(stock.symbol)）当前 \(priceText)，已\(alert.direction.title) \(thresholdText)。",
                ruleID: alert.id
            )
            triggeredAlertIDs.insert(alert.id)
        }
        if !triggeredAlertIDs.isEmpty {
            disableStockPriceAlerts(ids: triggeredAlertIDs)
        }
    }

    private func disableCurrencyRateAlerts(ids: Set<UUID>) {
        var didChange = false
        for index in currencyRateAlerts.indices where ids.contains(currencyRateAlerts[index].id) {
            guard currencyRateAlerts[index].isEnabled else { continue }
            currencyRateAlerts[index].isEnabled = false
            AppNotificationService.shared.clearState(for: currencyRateAlerts[index].id)
            didChange = true
        }
        if didChange {
            persist()
        }
    }

    private func disableStockPriceAlerts(ids: Set<UUID>) {
        var didChange = false
        for index in stockPriceAlerts.indices where ids.contains(stockPriceAlerts[index].id) {
            guard stockPriceAlerts[index].isEnabled else { continue }
            stockPriceAlerts[index].isEnabled = false
            AppNotificationService.shared.clearState(for: stockPriceAlerts[index].id)
            didChange = true
        }
        if didChange {
            persist()
            StockRefreshCoordinator.shared.refreshEligibilityChanged()
        }
    }
}
