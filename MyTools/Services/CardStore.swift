import Foundation
import Combine

@MainActor
final class CardStore: ObservableObject {
    @Published private(set) var accounts: [BankAccount]
    @Published private(set) var cards: [BankCard]
    @Published private(set) var stocks: [StockHolding]
    @Published private(set) var isRefreshingQuotes = false
    @Published private(set) var quoteRefreshError: String?
    @Published private(set) var quoteErrors: [UUID: String] = [:]
    @Published private(set) var usdRenminbiBuyingRate: Decimal?
    @Published private(set) var exchangeRateUpdatedAt: Date?
    @Published private(set) var exchangeRateError: String?
    private let secureStore = SecureStore()
    private let quoteService = StockQuoteService()
    private let exchangeRateService = ForeignExchangeRateService()
    private let defaults = UserDefaults.standard

    init() {
        let vault = secureStore.loadVault()
        accounts = vault.accounts
        cards = vault.cards
        stocks = vault.stocks
        if let savedRate = defaults.string(forKey: "stock-usd-cny-buying-rate-v1") {
            usdRenminbiBuyingRate = Decimal(string: savedRate, locale: Locale(identifier: "en_US_POSIX"))
        }
        exchangeRateUpdatedAt = defaults.object(forKey: "stock-usd-cny-buying-rate-date-v1") as? Date
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
        let encryptedVault = secureStore.hasLocalVault() ? VaultData() : secureStore.loadEncryptedVault()
        let vault = encryptedVault.isEmpty ? secureStore.loadVault() : encryptedVault
        accounts = vault.accounts
        cards = vault.cards
        stocks = vault.stocks
        // 旧版本加密数据在管理员认证后迁移到普通可读存储；之后普通模式启动不读取 Keychain。
        try? secureStore.saveVault(vault)
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

    func deleteAccount(at offsets: IndexSet) {
        let ids = offsets.map { accounts[$0].id }
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
        if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card } else { cards.append(card) }
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

    func deleteStocks(ids: Set<UUID>) {
        stocks.removeAll { ids.contains($0.id) }
        for id in ids { quoteErrors[id] = nil }
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

    func refreshStockQuotes() async {
        guard !isRefreshingQuotes else { return }
        isRefreshingQuotes = true
        quoteRefreshError = nil
        defer { isRefreshingQuotes = false }

        do {
            let exchangeRate = try await exchangeRateService.fetchUSDBuyingRate()
            usdRenminbiBuyingRate = exchangeRate.renminbiPerUnit
            exchangeRateUpdatedAt = exchangeRate.updatedAt
            exchangeRateError = nil
            defaults.set(NSDecimalNumber(decimal: exchangeRate.renminbiPerUnit).stringValue, forKey: "stock-usd-cny-buying-rate-v1")
            defaults.set(exchangeRate.updatedAt, forKey: "stock-usd-cny-buying-rate-date-v1")
        } catch {
            exchangeRateError = error.localizedDescription
        }

        guard !stocks.isEmpty else { return }

        var failures: [UUID: String] = [:]
        var successCount = 0
        let stockSnapshot = stocks
        for stock in stockSnapshot {
            do {
                let quote = try await quoteService.fetchQuote(for: stock)
                guard let index = stocks.firstIndex(where: { $0.id == stock.id }) else { continue }
                stocks[index].symbol = quote.symbol
                stocks[index].quoteName = quote.name
                stocks[index].latestPrice = quote.latestPrice
                stocks[index].previousClose = quote.previousClose
                stocks[index].changePercent = quote.changePercent
                stocks[index].lastQuoteAt = quote.updatedAt
                successCount += 1
            } catch {
                failures[stock.id] = error.localizedDescription
            }
        }

        quoteErrors = failures
        if !failures.isEmpty {
            let firstReason = failures.values.first ?? "行情服务暂时不可用"
            quoteRefreshError = "\(failures.count) 只股票暂时无法刷新：\(firstReason)"
        }
        if successCount > 0 { persist() }
    }

    func makeBackupDocument(password: String) throws -> VaultBackupDocument {
        let vault = VaultData(accounts: accounts, cards: cards, stocks: stocks)
        let data = try VaultBackupCrypto.makeBackup(from: vault, password: password)
        return VaultBackupDocument(data: data)
    }

    func restoreBackup(from data: Data, password: String) throws {
        let vault = try VaultBackupCrypto.restoreVault(from: data, password: password)
        try secureStore.saveVault(vault)
        accounts = vault.accounts
        cards = vault.cards
        stocks = vault.stocks
        quoteErrors = [:]
    }

    func delete(at offsets: IndexSet) { cards.remove(atOffsets: offsets); persist() }
    func delete(_ card: BankCard) { cards.removeAll { $0.id == card.id }; persist() }
    private func persist() { try? secureStore.saveVault(VaultData(accounts: accounts, cards: cards, stocks: stocks)) }
}

private extension VaultData {
    var isEmpty: Bool { accounts.isEmpty && cards.isEmpty && stocks.isEmpty }
}
