#if MYTOOLS_FEATURE_PARTNERSHIP
import Foundation
import Combine

struct PartnershipStockImportRecord: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case buy, sell, dividend
        var title: String {
            switch self { case .buy: "买入"; case .sell: "卖出"; case .dividend: "股息" }
        }
    }
    var id: UUID
    var market: PartnershipStockMarket
    var symbol: String
    var name: String
    var kind: Kind
    var date: Date
    var shares: Decimal
    var price: Decimal
    var fee: Decimal
    var grossAmount: Decimal = 0
    var withholdingTax: Decimal = 0

    init(id: UUID, market: PartnershipStockMarket, symbol: String, name: String, kind: Kind,
         date: Date, shares: Decimal, price: Decimal, fee: Decimal,
         grossAmount: Decimal = 0, withholdingTax: Decimal = 0) {
        self.id = id
        self.market = market
        self.symbol = symbol
        self.name = name
        self.kind = kind
        self.date = date
        self.shares = shares
        self.price = price
        self.fee = fee
        self.grossAmount = grossAmount
        self.withholdingTax = withholdingTax
    }

    /// Source-compatible initializer for existing tests and callers.
    init(id: UUID, market: PartnershipStockMarket, symbol: String, name: String,
         side: PartnershipStockTradeSide, date: Date, shares: Decimal, price: Decimal, fee: Decimal) {
        self.init(id: id, market: market, symbol: symbol, name: name,
                  kind: side == .buy ? .buy : .sell, date: date, shares: shares, price: price, fee: fee)
    }

    var title: String {
        switch kind { case .buy: "买入"; case .sell: "卖出"; case .dividend: "股息" }
    }
}

@MainActor
protocol PartnershipStockImportProviding: AnyObject {
    var partnershipImportRecords: [PartnershipStockImportRecord] { get }
}

@MainActor
final class PartnershipStore: ObservableObject {
    @Published private(set) var books: [PartnershipBook]
    private weak var mutationNotifier: (any VaultMutationNotifying)?
    private weak var stockImportProvider: (any PartnershipStockImportProviding)?
    /// In-memory only: a restored operation must never be recreated after a
    /// relaunch or a CloudKit merge.
    private var undoneBooks: [UUID: [PartnershipBook]] = [:]

    init(books: [PartnershipBook] = []) { self.books = books }
    func attach(mutationNotifier: any VaultMutationNotifying) { self.mutationNotifier = mutationNotifier }
    func attach(stockImportProvider: any PartnershipStockImportProviding) { self.stockImportProvider = stockImportProvider }
    func replace(books: [PartnershipBook]) {
        self.books = books
        undoneBooks.removeAll()
    }
    var stockImportRecords: [PartnershipStockImportRecord] { stockImportProvider?.partnershipImportRecords ?? [] }

    func importCandidates(bookID: UUID) -> [PartnershipStockImportRecord] {
        guard let book = books.first(where: { $0.id == bookID }) else { return [] }
        let imported = Set(book.records.compactMap(\.sourceRecordID))
        return stockImportRecords.filter { !imported.contains($0.id) }
    }

    func importStockRecords(bookID: UUID, ids: Set<UUID>, adjustmentRate: Decimal = Decimal(5) / 100) throws {
        guard let book = books.first(where: { $0.id == bookID }) else { throw PartnershipError.invalid("账本已不存在。") }
        let alreadyImported = Set(book.records.compactMap(\.sourceRecordID))
        guard ids.isDisjoint(with: alreadyImported) else { throw PartnershipError.invalid("所选记录中包含已经导入的项目。") }
        let selected = stockImportRecords.filter { ids.contains($0.id) }
        let records = selected.sorted { $0.date < $1.date }
        let operationID = UUID()
        // Validate the entire import against a disposable draft before changing
        // the real book. A failed row must never leave a partial import behind.
        let staged = PartnershipStore(books: [book])
        for record in records {
            switch record.kind {
            case .buy:
                try staged.recordStockPurchase(bookID: bookID, date: record.date, market: record.market,
                                               symbol: record.symbol, name: record.name, shares: record.shares,
                                               price: record.price, fee: record.fee, operationID: operationID,
                                               note: "从股票投资导入", sourceRecordID: record.id)
            case .sell:
                try staged.recordStockSale(bookID: bookID, date: record.date, market: record.market,
                                           symbol: record.symbol, name: record.name, shares: record.shares,
                                           price: record.price, fee: record.fee, adjustmentRate: adjustmentRate,
                                           operationID: operationID, note: "从股票投资导入", sourceRecordID: record.id)
            case .dividend:
                try staged.recordDividend(bookID: bookID, date: record.date, market: record.market,
                                          symbol: record.symbol, name: record.name, grossAmount: record.grossAmount,
                                          withholdingTax: record.withholdingTax, fee: record.fee,
                                          note: "从股票投资导入", sourceRecordID: record.id)
            }
        }
        guard let importedBook = staged.books.first else { return }
        try update(bookID) { book in
            let originalAudit = book.auditLog
            book = importedBook
            book.auditLog = originalAudit // discard the disposable draft's audit entries
            for record in records {
                log("从股票投资导入：\(record.title) \(record.name) \(record.symbol)，业务时间 \(record.date.formatted(date: .numeric, time: .shortened))", into: &book, recordID: record.id)
            }
        }
    }
    func create(name: String, type: PartnershipBookType = .stockInvestment, currency: CurrencyCode = .usd) throws {
        var book = PartnershipBook(name: try checkedName(name), type: type, currency: currency, members: [])
        log("创建账本「\(book.name)」，类型：\(type.title)，币种：\(currency.rawValue)", into: &book)
        books.append(book)
        undoneBooks[book.id] = nil
        didMutate()
    }
    func create(
        name: String,
        manager: String,
        partner: String,
        amounts: [Decimal],
        rate: Decimal
    ) throws {
        guard amounts.count == 2, amounts.allSatisfy({ PartnershipCalculator.validAmount($0) }),
              !rate.isNaN, (0...Decimal(1)).contains(rate) else {
            throw PartnershipError.invalid("初始出资须大于零且最多两位小数，调整比例须为 0%～100%。")
        }
        let members = [
            PartnershipMember(name: try checkedName(manager), isManager: true),
            PartnershipMember(name: try checkedName(partner))
        ]
        guard members[0].name != members[1].name else { throw PartnershipError.invalid("成员姓名不能重复。") }
        var book = PartnershipBook(name: try checkedName(name), adjustmentRate: rate, members: members)
        for (member, amount) in zip(members, amounts) {
            book.records.append(.init(kind: .contribution, amount: amount, note: "初始出资", memberID: member.id))
        }
        log("创建账本「\(book.name)」", into: &book)
        books.append(book)
        undoneBooks[book.id] = nil
        didMutate()
    }

    func rename(id: UUID, name: String) throws {
        let name = try checkedName(name)
        try update(id) { book in
            book.name = name
            log("修改账本名称为「\(name)」", into: &book)
        }
    }

    func delete(id: UUID) {
        books.removeAll { $0.id == id }
        undoneBooks[id] = nil
        didMutate()
    }

    func addMember(bookID: UUID, name: String, amount: Decimal, date: Date = Date()) throws {
        let name = try checkedName(name)
        try update(bookID) { book in
            try requireAmount(amount)
            try requireCapitalEventDate(date, in: book)
            guard !book.members.contains(where: { $0.name == name }) else { throw PartnershipError.invalid("成员姓名不能重复。") }
            let member = PartnershipMember(name: name, isManager: book.members.isEmpty)
            book.members.append(member)
            let record = PartnershipRecord(kind: .contribution, date: date, amount: amount, note: "新成员加入", memberID: member.id)
            book.records.append(record)
            log("新成员「\(name)」加入并注资 \(money(amount))", into: &book, recordID: record.id)
        }
    }

    func contribute(bookID: UUID, amount: Decimal, memberID: UUID?, proportional: Bool = false, note: String = "", date: Date = Date()) throws {
        try update(bookID) { book in
            try requireAmount(amount)
            try requireCapitalEventDate(date, in: book)
            if proportional {
                let allocations = try PartnershipCalculator.split(amount, book: book, date: date)
                for allocation in allocations where allocation.actual > 0 {
                    book.records.append(.init(kind: .contribution, date: date, amount: allocation.actual,
                                              note: note.isEmpty ? "按当前比例注资" : note, memberID: allocation.memberID))
                }
                log("按当前比例注资 \(money(amount))", into: &book)
                return
            }
            try requireMember(memberID, in: book)
            let record = PartnershipRecord(kind: .contribution, date: date, amount: amount, note: note, memberID: memberID)
            book.records.append(record)
            log("注资 \(money(amount))", into: &book, recordID: record.id)
        }
    }

    func withdraw(bookID: UUID, amount: Decimal, memberID: UUID?, note: String = "", date: Date = Date()) throws {
        try update(bookID) { book in
            try requireAmount(amount)
            try requireCapitalEventDate(date, in: book)
            try requireMember(memberID, in: book)
            let availableCash = PartnershipCalculator.memberAvailableCash(book, through: date)
                .first { $0.memberID == memberID }?.actual ?? 0
            guard amount <= availableCash else {
                throw PartnershipError.invalid("取出金额不能超过该成员当前可用现金；收益需先清账才能取出。")
            }
            let record = PartnershipRecord(kind: .withdrawal, date: date, amount: amount, note: note, memberID: memberID)
            book.records.append(record)
            log("取出可用现金 \(money(amount))", into: &book, recordID: record.id)
        }
    }
    func recordStockPurchase(
        bookID: UUID,
        date: Date,
        market: PartnershipStockMarket = .unitedStates,
        symbol: String,
        name: String,
        shares: Decimal,
        price: Decimal,
        fee: Decimal,
        operationID: UUID? = nil,
        note: String = "",
        sourceRecordID: UUID? = nil
    ) throws {
        try update(bookID) { book in
            let symbol = try checkedName(symbol).uppercased()
            let name = try checkedName(name)
            try requireTradeValues(shares: shares, price: price, fee: fee)
            let total = PartnershipCalculator.money(shares * price + fee)
            let availableAtTrade = PartnershipCalculator.memberAvailableCash(book, through: date)
                .reduce(Decimal.zero) { $0 + $1.actual }
            guard availableAtTrade >= total else {
                throw PartnershipError.invalid("可用资金不足，请先注资或清账。")
            }
            let allocations = try PartnershipCalculator.stockCostAllocations(total, book: book, date: date)
            let weightSnapshot = PartnershipCalculator.memberCapitalWeights(book, through: date)
                .filter { $0.amount > 0 }
            let record = PartnershipRecord(
                kind: .buy, date: date, operationID: operationID, sourceRecordID: sourceRecordID,
                sourceKind: sourceRecordID == nil ? nil : .stockTransaction, note: note,
                market: market, symbol: symbol, name: name, shares: shares, price: price, fee: fee,
                allocations: allocations, capitalWeightSnapshot: weightSnapshot
            )
            book.records.append(record)
            log("买入 \(name) \(symbol) \(shares) 股", into: &book, recordID: record.id)
        }
    }

    func recordStockSale(
        bookID: UUID,
        date: Date,
        market: PartnershipStockMarket = .unitedStates,
        symbol: String,
        name: String,
        shares: Decimal,
        price: Decimal,
        fee: Decimal,
        adjustmentRate: Decimal? = nil,
        purchaseID: UUID? = nil,
        operationID: UUID? = nil,
        note: String = "",
        sourceRecordID: UUID? = nil
    ) throws {
        try update(bookID) { book in
            let symbol = try checkedName(symbol).uppercased()
            let name = try checkedName(name)
            try requireTradeValues(shares: shares, price: price, fee: fee)
            let purchases = book.records
                .filter {
                    $0.isPurchase && $0.effectiveMarket == market
                        && $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame
                }
                .filter { purchaseID == nil || $0.id == purchaseID }
                .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
            var remaining = shares
            var matches: [PartnershipSaleMatch] = []
            for purchase in purchases where remaining > 0 {
                let alreadySold = book.records.lazy
                    .filter(\.isSale)
                    .flatMap(\.saleMatches)
                    .filter { $0.purchaseID == purchase.id }
                    .reduce(Decimal.zero) { $0 + $1.shares }
                let available = purchase.shares - alreadySold
                guard available > 0 else { continue }
                let matched = min(available, remaining)
                matches.append(.init(purchaseID: purchase.id, shares: matched))
                remaining -= matched
            }
            guard remaining == 0 else { throw PartnershipError.invalid("可卖股数不足，无法关联到完整的买入记录。") }
            guard matches.allSatisfy({ match in
                guard let purchase = purchases.first(where: { $0.id == match.purchaseID }) else { return false }
                return purchase.date <= date
            }) else {
                throw PartnershipError.invalid("卖出日期不能早于关联买入日期。")
            }
            let operationID = operationID ?? UUID()
            let recordedAt = Date()
            var allocatedFee: Decimal = 0
            for (index, match) in matches.enumerated() {
                guard let purchase = purchases.first(where: { $0.id == match.purchaseID }) else { continue }
                let matchedRatio = match.shares / shares
                let purchaseRatio = match.shares / purchase.shares
                let matchedFee = index == matches.indices.last
                    ? fee - allocatedFee
                    : PartnershipCalculator.money(fee * matchedRatio)
                allocatedFee += matchedFee
                let profit = match.shares * price - matchedFee - purchase.cashAmount * purchaseRatio
                var bases = Dictionary(uniqueKeysWithValues: book.members.map { ($0.id, Decimal.zero) })
                for allocation in purchase.allocations {
                    let memberRatio = purchase.cashAmount > 0 ? allocation.actual / purchase.cashAmount : 0
                    bases[allocation.memberID, default: 0] += profit * memberRatio
                }
                let allocations = try adjustedProfitAllocations(
                    bases: bases,
                    rate: adjustmentRate ?? book.adjustmentRate,
                    book: book
                )
                book.records.append(.init(
                    kind: .sell, date: date, recordedAt: recordedAt, operationID: operationID,
                    sourceRecordID: sourceRecordID, sourceKind: sourceRecordID == nil ? nil : .stockTransaction, note: note,
                    parentRecordID: purchase.id, market: market, symbol: symbol, name: name,
                    shares: match.shares, price: price, fee: matchedFee,
                    saleMatches: [match], allocations: allocations
                ))
            }
            log("卖出 \(name) \(symbol) \(shares) 股", into: &book)
        }
    }

    func recordDividend(
        bookID: UUID,
        date: Date,
        market: PartnershipStockMarket,
        symbol: String,
        name: String,
        grossAmount: Decimal,
        withholdingTax: Decimal,
        fee: Decimal,
        note: String = "",
        sourceRecordID: UUID? = nil
    ) throws {
        try update(bookID) { book in
            let symbol = try checkedName(symbol).uppercased()
            let name = try checkedName(name)
            guard PartnershipCalculator.validAmount(grossAmount),
                  PartnershipCalculator.validAmount(withholdingTax, allowZero: true),
                  PartnershipCalculator.validAmount(fee, allowZero: true),
                  grossAmount >= withholdingTax + fee else {
                throw PartnershipError.invalid("股息、预扣税和费用须为最多两位小数的有效金额，且扣除额不能超过股息。")
            }
            let allocations = try PartnershipCalculator.dividendAllocations(
                grossAmount: grossAmount, deductions: withholdingTax + fee,
                book: book, market: market, symbol: symbol, date: date
            )
            let record = PartnershipRecord(
                kind: .dividend, date: date, sourceRecordID: sourceRecordID,
                sourceKind: sourceRecordID == nil ? nil : .stockDividend, note: note, market: market, symbol: symbol, name: name,
                fee: fee, grossAmount: grossAmount, withholdingTax: withholdingTax, allocations: allocations
            )
            book.records.append(record)
            log("记录股息 \(name) \(symbol) \(money(record.dividendNet))", into: &book, recordID: record.id)
        }
    }

    /// 清账：distributes each member's current profit pool. `reinvest[memberID]`
    /// picks 重投 (true, pool → available cash) or 取回 (false, withdrawn);
    /// members omitted default to reinvest.
    func settle(bookID: UUID, reinvest: [UUID: Bool], date: Date = Date(), renminbiRate: Decimal? = nil,
                rateSource: PartnershipSettlementRateSource? = nil) throws {
        try update(bookID) { book in
            try requireCapitalEventDate(date, in: book)
            let pool = PartnershipCalculator.memberProfitPool(book).filter { $0.actual != 0 }
            guard !pool.isEmpty else { throw PartnershipError.invalid("当前没有可清账的收益。") }
            let choices = pool.map {
                let shouldReinvest = reinvest[$0.memberID] ?? true
                // Reinvestment stays inside the ledger and therefore keeps the
                // exact internal amount. A take-back is an external cash payment:
                // pay only whole cents and leave any sub-cent carry in the pool.
                let settledAmount = shouldReinvest ? $0.actual : PartnershipCalculator.money($0.actual)
                return PartnershipSettlementChoice(
                    memberID: $0.memberID,
                    amount: settledAmount,
                    reinvest: shouldReinvest
                )
            }
            let total = choices.reduce(Decimal.zero) { $0 + $1.amount }
            if let renminbiRate, renminbiRate <= 0 { throw PartnershipError.invalid("清账汇率必须大于零。") }
            let record = PartnershipRecord(kind: .settlement, date: date, amount: total, note: "清账收益池",
                                           settlementChoices: choices, settlementRenminbiRate: renminbiRate,
                                           settlementRateSource: rateSource)
            book.records.append(record)
            log("清账收益池 \(choices.count) 人", into: &book, recordID: record.id)
        }
    }
    /// Only the latest operation can be undone, avoiding recalculation of frozen
    /// history. Records from one user action share an operationID and are removed
    /// together.
    func undoLatestChange(bookID: UUID) throws {
        try undo(bookID) { book in
            guard let last = book.records.last else { throw PartnershipError.invalid("当前没有可撤销的记录。") }
            let description: String
            if let operationID = last.operationID {
                let removed = book.records.filter { $0.operationID == operationID }
                book.records.removeAll { $0.operationID == operationID }
                description = "\(removed.first?.kind.title ?? "操作")（\(removed.count) 条）"
            } else {
                book.records.removeLast()
                description = last.kind.title
            }
            log("撤销\(description)", into: &book)
        }
    }

    /// Restores the most recently undone operation, provided no newer change
    /// has been made to the book.
    func cancelUndoLatestChange(bookID: UUID) throws {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else {
            throw PartnershipError.invalid("账本已不存在。")
        }
        var snapshots = undoneBooks[bookID] ?? []
        guard var restoredBook = snapshots.popLast() else {
            throw PartnershipError.invalid("当前没有可取消的撤回。")
        }
        undoneBooks[bookID] = snapshots.isEmpty ? nil : snapshots
        log("取消撤回，恢复最近一次修改", into: &restoredBook)
        books[index] = restoredBook
        didMutate()
    }

    func canCancelUndo(bookID: UUID) -> Bool {
        !(undoneBooks[bookID] ?? []).isEmpty
    }

    private func undo(_ id: UUID, mutation: (inout PartnershipBook) throws -> Void) throws {
        guard let index = books.firstIndex(where: { $0.id == id }) else {
            throw PartnershipError.invalid("账本已不存在。")
        }
        let original = books[index]
        var draft = original
        try mutation(&draft)
        books[index] = draft
        undoneBooks[id, default: []].append(original)
        didMutate()
    }

    private func update(_ id: UUID, mutation: (inout PartnershipBook) throws -> Void) throws {
        guard let index = books.firstIndex(where: { $0.id == id }) else { throw PartnershipError.invalid("账本已不存在。") }
        var draft = books[index]
        try mutation(&draft)
        books[index] = draft
        undoneBooks[id] = nil
        didMutate()
    }

    private func log(_ action: String, into book: inout PartnershipBook, recordID: UUID? = nil) {
        book.auditLog.append(.init(action: action, affectedRecordID: recordID))
    }
    private func money(_ value: Decimal) -> Decimal { PartnershipCalculator.money(value) }
    private func checkedName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PartnershipError.invalid("名称不能为空。") }
        return result
    }
    private func requireAmount(_ amount: Decimal) throws {
        guard PartnershipCalculator.validAmount(amount) else { throw PartnershipError.invalid("请输入大于零、最多两位小数的金额。") }
    }
    private func requireMember(_ id: UUID?, in book: PartnershipBook) throws {
        guard book.members.contains(where: { $0.id == id }) else { throw PartnershipError.invalid("请选择账本成员。") }
    }
    private func requireTradeValues(shares: Decimal, price: Decimal, fee: Decimal) throws {
        guard PartnershipCalculator.validShareAmount(shares),
              PartnershipCalculator.validAmount(price),
              PartnershipCalculator.validAmount(fee, allowZero: true) else {
            throw PartnershipError.invalid("股数须大于零且最多六位小数；股价和手续费须为最多两位小数的有效金额。")
        }
    }
    private func requireCapitalEventDate(_ date: Date, in book: PartnershipBook) throws {
        guard !book.records.contains(where: { $0.isPurchase && $0.date > date }) else {
            throw PartnershipError.invalid("为保持已冻结的买入比例，注资、取现或清账时间不能早于现有买入记录。请先撤销较晚的交易再补录。")
        }
    }
    private func adjustedProfitAllocations(
        bases: [UUID: Decimal],
        rate: Decimal,
        book: PartnershipBook
    ) throws -> [PartnershipAllocation] {
        guard !rate.isNaN, (0...Decimal(1)).contains(rate) else {
            throw PartnershipError.invalid("分成比例须为 0%～100%。")
        }
        guard let investor = book.members.first(where: \.isManager) else { return [] }
        var result: [PartnershipAllocation] = []
        var allocatedToOthers: Decimal = 0
        for member in book.members where member.id != investor.id {
            let base = PartnershipCalculator.precise(bases[member.id, default: 0])
            let adjustment = PartnershipCalculator.precise(base * rate)
            let actual = PartnershipCalculator.precise(base - adjustment)
            allocatedToOthers += actual
            result.append(.init(memberID: member.id, base: base, adjustment: adjustment, actual: actual))
        }
        let investorBase = PartnershipCalculator.precise(bases[investor.id, default: 0])
        let totalProfit = PartnershipCalculator.precise(bases.values.reduce(Decimal.zero, +))
        let investorActual = PartnershipCalculator.precise(totalProfit - allocatedToOthers)
        result.append(.init(
            memberID: investor.id,
            base: investorBase,
            adjustment: PartnershipCalculator.precise(investorBase - investorActual),
            actual: investorActual
        ))
        return result
    }
    private func didMutate() { mutationNotifier?.moduleStoreDidMutate() }



}
#endif
