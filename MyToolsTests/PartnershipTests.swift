import Foundation
import Testing
@testable import MyTools

@MainActor
struct PartnershipTests {
#if MYTOOLS_FEATURE_PARTNERSHIP
    private func makeStore() throws -> PartnershipStore {
        let store = PartnershipStore()
        try store.create(name: "合伙", manager: "我", partner: "对方", amounts: [9000, 1500], rate: Decimal(5) / 100)
        return store
    }

    @Test func signedAdjustmentAndRoundingConserveTotal() throws {
        let store = try makeStore()
        let book = try #require(store.books.first)
        let partner = book.members[1].id
        for total: Decimal in [7000, -7000, Decimal(1) / 100, -Decimal(1) / 100] {
            let result = try PartnershipCalculator.split(total, book: book, adjusted: true)
            #expect(result.reduce(Decimal(0)) { $0 + $1.actual } == total)
            if abs(total) == 7000 {
                #expect(result.first { $0.memberID == partner }?.actual == (total > 0 ? 950 : -950))
            }
        }
    }

    @Test func contributionsPreserveThenChangeRatiosAndHistory() throws {
        let store = try makeStore()
        let book = try #require(store.books.first)
        try store.record(bookID: book.id, kind: .settlement, amount: 7000, memberID: nil)
        let frozen = store.books[0].entries.last
        try store.record(bookID: book.id, kind: .contribution, amount: 700, memberID: nil, proportional: true)
        var summary = PartnershipCalculator.summary(store.books[0])
        #expect(summary.positions[0].capital == 9600)
        #expect(summary.positions[1].capital == 1600)
        try store.record(bookID: book.id, kind: .contribution, amount: 8000, memberID: book.members[1].id)
        summary = PartnershipCalculator.summary(store.books[0])
        #expect(summary.positions[0].capital == summary.positions[1].capital)
        #expect(store.books[0].entries.contains(frozen!))
    }

    @Test func valuationSettlementAndNewMemberDoNotDiluteHistory() throws {
        let store = try makeStore()
        let book = store.books[0]
        try store.record(bookID: book.id, kind: .valuation, amount: 17500, memberID: nil)
        #expect(throws: PartnershipError.self) { try store.addMember(bookID: book.id, name: "第三人", amount: 3500) }
        #expect(store.books[0].members.count == 2)
        try store.record(bookID: book.id, kind: .settlement, amount: 7000, memberID: nil)
        let before = PartnershipCalculator.summary(store.books[0])
        #expect(before.pendingProfit == 0)
        try store.addMember(bookID: book.id, name: "第三人", amount: 3500)
        let after = PartnershipCalculator.summary(store.books[0])
        #expect(after.netValue == 21000)
        #expect(after.positions.last?.profit == 0)
        #expect(after.positions[0].profit == before.positions[0].profit)
    }

    @Test func withdrawalRedeemsCapitalAndProfitAndCannotOverdraw() throws {
        let store = try makeStore()
        let book = store.books[0]
        let partner = book.members[1].id
        try store.record(bookID: book.id, kind: .settlement, amount: 7000, memberID: nil)
        try store.record(bookID: book.id, kind: .withdrawal, amount: 1225, memberID: partner)
        var position = PartnershipCalculator.summary(store.books[0]).positions[1]
        #expect(position.capital == 750)
        #expect(position.profit == 475)
        #expect(throws: PartnershipError.self) {
            try store.record(bookID: book.id, kind: .withdrawal, amount: 1226, memberID: partner)
        }
        try store.record(bookID: book.id, kind: .withdrawal, amount: 1225, memberID: partner)
        position = PartnershipCalculator.summary(store.books[0]).positions[1]
        #expect(position.capital == 0)
        #expect(position.equity == 0)
    }

    @Test func tinyMultiMemberContributionConservesCash() throws {
        let store = try makeStore()
        let id = store.books[0].id
        try store.addMember(bookID: id, name: "第三人", amount: 9000)
        let before = PartnershipCalculator.summary(store.books[0]).contributed
        try store.record(bookID: id, kind: .contribution, amount: Decimal(1) / 100, memberID: nil, proportional: true)
        let after = PartnershipCalculator.summary(store.books[0]).contributed
        #expect(after - before == Decimal(1) / 100)
        #expect(store.books[0].entries.allSatisfy { $0.amount > 0 })
    }

    @Test func zeroValuationAndUndoWork() throws {
        let store = try makeStore()
        let id = store.books[0].id
        try store.record(bookID: id, kind: .valuation, amount: 0, memberID: nil)
        #expect(PartnershipCalculator.summary(store.books[0]).pendingProfit == -10500)
        try store.undoLast(bookID: id)
        #expect(PartnershipCalculator.summary(store.books[0]).netValue == 10500)
        #expect(throws: PartnershipError.self) {
            try store.record(bookID: id, kind: .contribution, amount: Decimal(1) / 1000, memberID: store.books[0].members[0].id)
        }
    }

    @Test func defaultOffAndExplicitChoiceSurvivesReload() throws {
        let defaults = try #require(UserDefaults(suiteName: "PartnershipTests.\(UUID())"))
        let settings = ToolModuleSettings(defaults: defaults)
        #expect(!settings.isVisible(.partnership))
        settings.setVisible(true, for: .partnership)
        #expect(ToolModuleSettings(defaults: defaults).isVisible(.partnership))
        settings.setVisible(false, for: .partnership)
        #expect(!ToolModuleSettings(defaults: defaults).isVisible(.partnership))
    }

    @Test func persistenceCloudAndBackupRoundTrip() async throws {
        let store = try makeStore()
        let book = store.books[0]
        let vault = VaultData(partnershipBooks: [book])
        let decoded = try JSONDecoder().decode(VaultData.self, from: JSONEncoder().encode(vault))
        #expect(decoded.partnershipBooks == [book])
        let legacy = try JSONDecoder().decode(VaultData.self, from: Data("{}".utf8))
        #expect(legacy.partnershipBooks.isEmpty)
        let snapshot = try CloudSyncSnapshotBuilder.make(vault: vault, secrets: [], attachmentStore: AttachmentStore(), enabledModules: [.partnership])
        #expect(snapshot.items.count == 1)
        let changes = snapshot.items.map { CloudSyncChange.upsert(kind: $0.kind, id: $0.id, payload: $0.payload) }
        let merged = try CloudSyncMerger.apply(changes, to: VaultData(), secrets: [], enabledModules: [.partnership])
        #expect(merged.vault.partnershipBooks == [book])
        let deleted = try CloudSyncMerger.apply([.delete(kind: .partnershipBook, id: book.id)], to: vault, secrets: [], enabledModules: [.partnership])
        #expect(deleted.vault.partnershipBooks.isEmpty)
        let ignored = try CloudSyncMerger.apply(changes, to: VaultData(), secrets: [], enabledModules: [])
        #expect(ignored.vault.partnershipBooks.isEmpty)
        let processor = AppStoreBackupProcessor()
        for included: Set<ToolModule> in [[], [.partnership]] {
            let bytes = try await processor.makeBackup(vault: vault, secrets: [], includedModules: included, password: "test-password")
            let restored = try await processor.restorePayload(from: bytes, password: "test-password")
            #expect(restored.vault.partnershipBooks == (included.isEmpty ? [] : [book]))
        }
        let imported = VaultBackupPayload(vault: vault, includedModules: [.partnership])
        let restored = AppStoreBackupMerger.merge(localVault: VaultData(), localSecrets: [], imported: imported)
        #expect(restored.vault.partnershipBooks == [book])
    }
#else
    @Test func excludedModuleRetainsOpaqueVaultButDoesNotRegisterOrSync() throws {
        let json = Data(#"{"partnershipBooks":[{"id":"foreign","future":{"amount":123.45}}]}"#.utf8)
        let vault = try JSONDecoder().decode(VaultData.self, from: json)
        let decoded = try JSONDecoder().decode(VaultData.self, from: JSONEncoder().encode(vault))
        #expect(vault.partnershipBooks == decoded.partnershipBooks)
        #expect(!CompiledToolModules.contains(.partnership))
        let snapshot = try CloudSyncSnapshotBuilder.make(vault: vault, secrets: [], attachmentStore: AttachmentStore())
        #expect(!snapshot.items.contains { $0.kind == .partnershipBook })
    }
#endif
}
