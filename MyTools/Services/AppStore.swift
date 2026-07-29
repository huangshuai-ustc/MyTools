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
    @Published private(set) var secretItems: [SecretItem]
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
    @Published private(set) var isVaultLoadFailurePresented = false
    private let persistence = VaultPersistenceCoordinator()
    private let quoteService = StockQuoteService()
    private let exchangeRateService = ForeignExchangeRateService()
    private let attachmentStore = AttachmentStore()
    private let defaults = UserDefaults.standard
    private var lastExchangeRateRequestAt: Date?
    private var isRestoringBackup = false
    private var canPersistVault = true

    init() {
        accounts = []
        cards = []
        stocks = []
        currencyExchangeRecords = []
        medicalRecords = []
        hospitalProfiles = []
        secretItems = []
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

    private func applyInitialSnapshot(_ snapshot: AppStoreInitialSnapshot) {
        applyVault(snapshot.vault)
        secretItems = snapshot.secretItems
        canPersistVault = snapshot.canPersistVault
        migrateLegacyPhysicalExamSessions()
        synchronizeLoadedInpatientDailyRecords()
        synchronizeHospitalProfilesWithMedicalRecords()
        isVaultLoadFailurePresented = !snapshot.canPersistVault
        isInitialDataLoaded = true
        let loadSummary = "Local vault loaded from \(snapshot.vaultSource): \(snapshot.vaultByteCount) bytes; read \(snapshot.readDurationMilliseconds) ms, decode \(snapshot.decodeDurationMilliseconds) ms, total \(snapshot.loadDurationMilliseconds) ms"
        startupLogger.info("\(loadSummary, privacy: .public)")
        DiagnosticLogger.shared.log(.startup, loadSummary)
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
        persistSecrets()
    }

    func deleteSecrets(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in secretItems where ids.contains(item.id) {
            item.attachments.forEach(attachmentStore.delete)
        }
        secretItems.removeAll { ids.contains($0.id) }
        persistSecrets()
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

    private func migrateLegacyPhysicalExamSessions() {
        var migratedRecords: [MedicalRecord] = []
        var didChange = false

        for index in medicalRecords.indices {
            guard medicalRecords[index].isPhysicalExam,
                  var details = medicalRecords[index].physicalExamDetails,
                  !details.sessions.isEmpty else {
                continue
            }
            didChange = true

            let parent = medicalRecords[index]
            let sessions = details.sessions.sorted { $0.date < $1.date }
            if let firstSession = sessions.first {
                medicalRecords[index].date = MedicalRecord.normalizedDate(firstSession.date)
                if details.completedItems.isEmpty {
                    details.completedItems = firstSession.completedItems
                }
                if medicalRecords[index].diagnosis.isEmpty {
                    medicalRecords[index].diagnosis = firstSession.result
                }
                if medicalRecords[index].treatment.isEmpty {
                    medicalRecords[index].treatment = firstSession.recommendation
                }
                if medicalRecords[index].notes.isEmpty {
                    medicalRecords[index].notes = firstSession.notes
                }
            }

            for session in sessions.dropFirst() {
                guard !medicalRecords.contains(where: { $0.id == session.id }) else { continue }
                var child = MedicalRecord(followUpTo: parent, date: session.date)
                child.id = session.id
                child.hospital = session.institution.isEmpty ? parent.hospital : session.institution
                child.physicalExamDetails = PhysicalExamDetails(
                    packageName: details.packageName,
                    completedItems: session.completedItems
                )
                child.diagnosis = session.result
                child.treatment = session.recommendation
                child.notes = session.notes
                migratedRecords.append(child)
            }

            details.sessions = []
            medicalRecords[index].physicalExamDetails = details
            medicalRecords[index].updatedAt = Date()
        }

        guard didChange else { return }
        medicalRecords.append(contentsOf: migratedRecords)
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
        let stockSnapshot = stocks
        guard !stockSnapshot.isEmpty else { return }

        var failures: [UUID: String] = [:]
        var successCount = 0
        let refreshedQuotes = await quoteService.fetchQuotes(for: stockSnapshot)

        let stockIndices = Dictionary(
            uniqueKeysWithValues: stocks.indices.map { (stocks[$0].id, $0) }
        )
        for stock in stockSnapshot {
            guard let quote = refreshedQuotes[stock.id] else {
                failures[stock.id] = "行情服务暂时不可用"
                continue
            }
            guard let index = stockIndices[stock.id] else { continue }
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

    func makeBackupDocument(password: String) async throws -> VaultBackupDocument {
        let snapshot = VaultData(
            accounts: accounts,
            cards: cards,
            stocks: stocks,
            currencyExchangeRecords: currencyExchangeRecords,
            medicalRecords: medicalRecords,
            hospitalProfiles: hospitalProfiles
        )
        let secretSnapshot = secretItems
        let data = try await Task.detached(priority: .userInitiated) {
            let attachmentStore = AttachmentStore()
            var vault = snapshot
            vault.medicalRecords = try attachmentStore.recordsForBackup(vault.medicalRecords)
            vault.cards = try attachmentStore.cardsForBackup(vault.cards)
            let secrets = try attachmentStore.secretsForBackup(secretSnapshot)
            return try VaultBackupCrypto.makeBackup(
                from: vault,
                secrets: secrets,
                password: password
            )
        }.value
        return VaultBackupDocument(data: data)
    }

    func restoreBackup(from data: Data, password: String) async throws {
        isRestoringBackup = true
        defer { isRestoringBackup = false }
        let restoredPayload = try await Task.detached(priority: .userInitiated) {
            let attachmentStore = AttachmentStore()
            var payload = try VaultBackupCrypto.restorePayload(from: data, password: password)
            payload.vault.medicalRecords = try attachmentStore.restoreAttachments(
                in: payload.vault.medicalRecords
            )
            payload.vault.cards = try attachmentStore.restoreAttachments(in: payload.vault.cards)
            payload.secrets = try attachmentStore.restoreAttachments(in: payload.secrets)
            return payload
        }.value
        try await Task.detached(priority: .userInitiated) { [persistence] in
            try persistence.saveImmediately(
                restoredPayload.vault,
                secrets: restoredPayload.secrets
            )
        }.value
        applyVault(restoredPayload.vault)
        secretItems = restoredPayload.secrets
        canPersistVault = true
        quoteErrors = [:]
        quoteSources = [:]
    }

    func flushPendingPersistence() async {
        await persistence.flush()
    }

    func dismissVaultLoadFailure() {
        isVaultLoadFailurePresented = false
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
            if !canPersistVault {
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

    private func persistSecrets() {
        guard !isRestoringBackup, canPersistVault else {
            if !canPersistVault {
                DiagnosticLogger.shared.log(
                    .persistence,
                    "本地存档未成功读取，已拦截保密资料写入以保护原文件",
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
            hospitalProfiles: hospitalProfiles
        )
    }
}
