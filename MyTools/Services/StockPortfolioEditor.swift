import Foundation

struct StockDeletionResult {
    var stocks: [StockHolding]
    var stockPriceAlerts: [StockPriceAlert]
    var removedAlertIDs: Set<UUID>
}

enum StockPortfolioEditor {
    static func containsStock(
        in stocks: [StockHolding],
        market: StockMarket,
        symbol: String,
        excluding stockID: UUID? = nil
    ) -> Bool {
        let normalized = StockHolding.normalizedSymbol(symbol, market: market)
        return stocks.contains { stock in
            stock.id != stockID
                && stock.market == market
                && StockHolding.normalizedSymbol(stock.symbol, market: stock.market) == normalized
        }
    }

    static func normalizedHolding(_ stock: StockHolding) -> StockHolding {
        var normalized = stock
        normalized.symbol = StockHolding.normalizedSymbol(stock.symbol, market: stock.market)
        return normalized
    }

    static func deletingStocks(
        ids: Set<UUID>,
        from stocks: [StockHolding],
        alerts: [StockPriceAlert]
    ) -> StockDeletionResult {
        let removedAlertIDs: Set<UUID> = Set(alerts.compactMap { alert in
            guard let stockID = alert.stockID, ids.contains(stockID) else { return nil }
            return alert.id
        })
        return StockDeletionResult(
            stocks: stocks.filter { !ids.contains($0.id) },
            stockPriceAlerts: alerts.filter { alert in
                guard let stockID = alert.stockID else { return true }
                return !ids.contains(stockID)
            },
            removedAlertIDs: removedAlertIDs
        )
    }

    static func upserting(
        _ transaction: StockTransaction,
        in stock: StockHolding
    ) -> StockHolding? {
        var candidate = stock
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
        return candidate.hasValidTransactionOrder ? candidate : nil
    }

    static func deletingTransactions(
        ids: Set<UUID>,
        from stock: StockHolding
    ) -> StockHolding? {
        var candidate = stock
        let affectedDates = candidate.transactions
            .filter { ids.contains($0.id) }
            .map(\.tradedAt)
        candidate.transactions.removeAll { ids.contains($0.id) }
        affectedDates.forEach { candidate.normalizeTransactionDay(containing: $0) }
        return candidate.hasValidTransactionOrder ? candidate : nil
    }

    static func reorderingTransactions(
        _ orderedIDs: [UUID],
        in stock: StockHolding
    ) -> StockHolding? {
        guard orderedIDs.count > 1,
              Set(orderedIDs).count == orderedIDs.count else { return nil }

        var candidate = stock
        let selectedTransactions = orderedIDs.compactMap { transactionID in
            candidate.transactions.first { $0.id == transactionID }
        }
        guard selectedTransactions.count == orderedIDs.count,
              let date = selectedTransactions.first?.tradedAt,
              selectedTransactions.allSatisfy({ StockTransaction.isSameDay($0.tradedAt, date) }) else {
            return nil
        }
        let transactionsOnDate = candidate.transactions.filter {
            StockTransaction.isSameDay($0.tradedAt, date)
        }
        guard Set(transactionsOnDate.map(\.id)) == Set(orderedIDs) else { return nil }

        let normalizedDate = StockTransaction.normalizedDate(date)
        for (dayOrder, transactionID) in orderedIDs.enumerated() {
            guard let index = candidate.transactions.firstIndex(where: { $0.id == transactionID }) else {
                return nil
            }
            candidate.transactions[index].tradedAt = normalizedDate
            candidate.transactions[index].dayOrder = dayOrder
        }
        return candidate.hasValidTransactionOrder ? candidate : nil
    }

    static func upserting(_ dividend: StockDividend, in stock: StockHolding) -> StockHolding {
        var candidate = stock
        if let index = candidate.dividends.firstIndex(where: { $0.id == dividend.id }) {
            candidate.dividends[index] = dividend
        } else {
            candidate.dividends.append(dividend)
        }
        return candidate
    }

    static func deletingDividends(
        ids: Set<UUID>,
        from stock: StockHolding
    ) -> StockHolding {
        var candidate = stock
        candidate.dividends.removeAll { ids.contains($0.id) }
        return candidate
    }
}
