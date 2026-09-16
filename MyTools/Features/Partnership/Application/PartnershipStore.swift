#if MYTOOLS_FEATURE_PARTNERSHIP
import Foundation
import Combine

@MainActor
final class PartnershipStore: ObservableObject {
    @Published private(set) var books: [PartnershipBook]
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    init(books: [PartnershipBook] = []) { self.books = books }
    func attach(mutationNotifier: any VaultMutationNotifying) { self.mutationNotifier = mutationNotifier }
    func replace(books: [PartnershipBook]) { self.books = books }

    func create(name: String, manager: String, partner: String, amounts: [Decimal], rate: Decimal) throws {
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
            book.entries.append(.init(kind: .contribution, amount: amount, memberID: member.id, note: "初始出资"))
        }
        books.append(book)
        didMutate()
    }

    func rename(id: UUID, name: String) throws {
        let name = try checkedName(name)
        try update(id) { $0.name = name }
    }

    func delete(id: UUID) {
        books.removeAll { $0.id == id }
        didMutate()
    }

    func addMember(bookID: UUID, name: String, amount: Decimal) throws {
        let name = try checkedName(name)
        try update(bookID) { book in
            try requireSettled(book)
            try requireAmount(amount)
            guard !book.members.contains(where: { $0.name == name }) else { throw PartnershipError.invalid("成员姓名不能重复。") }
            let member = PartnershipMember(name: name)
            book.members.append(member)
            book.entries.append(.init(kind: .contribution, amount: amount, memberID: member.id, note: "新成员加入"))
        }
    }

    func record(bookID: UUID, kind: PartnershipEntryKind, amount: Decimal, memberID: UUID?, proportional: Bool = false, note: String = "") throws {
        try update(bookID) { book in
            guard PartnershipCalculator.validAmount(amount, allowNegative: kind == .settlement, allowZero: kind == .valuation) else {
                throw PartnershipError.invalid("请输入有效金额（最多两位小数）；仅盈亏允许负数，净值允许零。")
            }
            var entry = PartnershipEntry(kind: kind, amount: amount, memberID: memberID, note: note)
            let summary = PartnershipCalculator.summary(book)
            switch kind {
            case .contribution:
                try requireSettled(book)
                if proportional {
                    let allocations = try PartnershipCalculator.split(amount, book: book, adjusted: false)
                    for allocation in allocations where allocation.actual > 0 {
                        book.entries.append(.init(kind: kind, amount: allocation.actual, memberID: allocation.memberID, note: note.isEmpty ? "按当前比例注资" : note))
                    }
                    return
                }
                try requireMember(memberID, in: book)
            case .withdrawal:
                try requireSettled(book)
                try requireMember(memberID, in: book)
                guard let position = summary.positions.first(where: { $0.id == memberID }),
                      position.equity > 0, amount <= position.equity, amount <= summary.netValue else {
                    throw PartnershipError.invalid("取出金额不能超过个人权益或账户净值。")
                }
                entry.capitalRedeemed = amount == position.equity ? position.capital
                    : PartnershipCalculator.money(position.capital * amount / position.equity)
            case .settlement:
                if summary.valuation != nil, summary.pendingProfit != amount {
                    throw PartnershipError.invalid("已记录净值，请结算其与账面值的差额，或先更新净值。")
                }
                guard summary.bookValue + amount >= 0 else { throw PartnershipError.invalid("亏损不能超过账户账面价值。") }
                entry.allocations = try PartnershipCalculator.split(amount, book: book, adjusted: true)
            case .valuation:
                break
            }
            book.entries.append(entry)
        }
    }

    /// Only the latest event can be undone, avoiding recalculation of frozen history.
    func undoLast(bookID: UUID) throws {
        try update(bookID) { book in
            guard book.entries.count > 2 else { throw PartnershipError.invalid("初始出资不能撤销；可删除整个账本。") }
            book.entries.removeLast()
        }
    }

    private func update(_ id: UUID, mutation: (inout PartnershipBook) throws -> Void) throws {
        guard let index = books.firstIndex(where: { $0.id == id }) else { throw PartnershipError.invalid("账本已不存在。") }
        var draft = books[index]
        try mutation(&draft)
        books[index] = draft
        didMutate()
    }
    private func checkedName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PartnershipError.invalid("名称不能为空。") }
        return result
    }
    private func requireSettled(_ book: PartnershipBook) throws {
        guard PartnershipCalculator.summary(book).pendingProfit == 0 else {
            throw PartnershipError.invalid("变更资金或成员前，请先结算当前净值盈亏，避免新资金参与历史盈亏。")
        }
    }
    private func requireAmount(_ amount: Decimal) throws {
        guard PartnershipCalculator.validAmount(amount) else { throw PartnershipError.invalid("请输入大于零、最多两位小数的金额。") }
    }
    private func requireMember(_ id: UUID?, in book: PartnershipBook) throws {
        guard book.members.contains(where: { $0.id == id }) else { throw PartnershipError.invalid("请选择账本成员。") }
    }
    private func didMutate() { mutationNotifier?.moduleStoreDidMutate() }
}
#endif
