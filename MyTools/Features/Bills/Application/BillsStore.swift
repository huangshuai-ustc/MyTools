#if MYTOOLS_FEATURE_BILLS
import Foundation

struct BillImportOutcome: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int

    var totalCount: Int { insertedCount + updatedCount }
}

@MainActor
final class BillsStore: ObservableObject {
    @Published private(set) var records: [BillRecord]
    @Published private(set) var knownTags: [String]
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    init(records: [BillRecord] = [], knownTags: [String] = []) {
        let normalizedRecords = records.map(Self.normalizedTags(in:))
        self.records = Self.sorted(normalizedRecords)
        self.knownTags = AppTagSupport.merged(knownTags, with: normalizedRecords.flatMap(\.tags))
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(records: [BillRecord], knownTags: [String]? = nil) {
        let normalizedRecords = records.map(Self.normalizedTags(in:))
        self.records = Self.sorted(normalizedRecords)
        self.knownTags = AppTagSupport.merged(
            knownTags ?? self.knownTags,
            with: normalizedRecords.flatMap(\.tags)
        )
        DiagnosticLogger.shared.log(.data, "账单数据替换 count=\(normalizedRecords.count)")
    }

    func upsert(_ record: BillRecord) {
        // 0 元记录（如优惠券全额抵扣）可以导入，也允许编辑保存（AUDIT-075）。
        var stored = normalized(record)
        knownTags = AppTagSupport.merged(knownTags, with: stored.tags)
        stored.updatedAt = Date()
        let isUpdate: Bool
        if let index = records.firstIndex(where: { $0.id == stored.id }) {
            stored.createdAt = records[index].createdAt
            records[index] = stored
            isUpdate = true
        } else {
            stored.createdAt = stored.updatedAt
            records.append(stored)
            isUpdate = false
        }
        records = Self.sorted(records)
        DiagnosticLogger.shared.log(.data, "账单记录\(isUpdate ? "更新" : "新增") id=\(stored.id)")
        didMutate()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        records.removeAll { ids.contains($0.id) }
        DiagnosticLogger.shared.log(.data, "账单记录删除 count=\(ids.count)")
        didMutate()
    }

    @discardableResult
    func importExchange(_ document: BillExchangeDocument) throws -> BillImportOutcome {
        let incomingRecords = try BillExchangeMapper.records(from: document)
        var insertedCount = 0
        var updatedCount = 0

        for incoming in incomingRecords {
            var stored = normalized(incoming)
            knownTags = AppTagSupport.merged(knownTags, with: stored.tags)
            if let index = matchingIndex(for: stored) {
                records[index] = Self.merged(stored, into: records[index])
                updatedCount += 1
            } else {
                stored.createdAt = Date()
                stored.updatedAt = stored.createdAt
                records.append(stored)
                insertedCount += 1
            }
        }

        guard insertedCount > 0 || updatedCount > 0 else {
            return BillImportOutcome(insertedCount: 0, updatedCount: 0)
        }
        records = Self.sorted(records)
        DiagnosticLogger.shared.log(.data, "账单导入完成 inserted=\(insertedCount) updated=\(updatedCount)")
        didMutate()
        return BillImportOutcome(insertedCount: insertedCount, updatedCount: updatedCount)
    }

    func records(in month: Date, calendar: Calendar = .autoupdatingCurrent) -> [BillRecord] {
        records.filter { calendar.isDate($0.occurredAt, equalTo: month, toGranularity: .month) }
    }

    func total(
        direction: BillDirection,
        in month: Date,
        currency: CurrencyCode = .cny,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Decimal {
        records(in: month, calendar: calendar)
            .filter { $0.direction == direction && $0.currency == currency && $0.status != .cancelled }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Re-importing only refreshes platform fields. Category, tags and note are what the user
    /// edits after importing, so the stored values win (tags are merged, an empty note is
    /// filled in). The local origin is kept when the file is the app's own export (AUDIT-042).
    static func merged(_ incoming: BillRecord, into existing: BillRecord) -> BillRecord {
        var result = incoming
        result.id = existing.id
        result.createdAt = existing.createdAt
        result.updatedAt = Date()
        result.category = existing.category
        result.tags = AppTagSupport.merged(existing.tags, with: incoming.tags)
        if !existing.note.isEmpty { result.note = existing.note }
        if incoming.origin.providerIdentifier == BillExchangeSource.myTools.providerIdentifier {
            result.origin = existing.origin
        }
        return result
    }

    private func matchingIndex(for incoming: BillRecord) -> Int? {
        // The app's own export carries the local id as the transaction id, while the stored
        // record keeps its original source, so match by id first (AUDIT-010).
        if incoming.origin.providerIdentifier == BillExchangeSource.myTools.providerIdentifier,
           let index = records.firstIndex(where: { $0.id == incoming.id }) {
            return index
        }
        if let externalID = incoming.origin.externalTransactionID {
            return records.firstIndex {
                $0.origin.providerIdentifier == incoming.origin.providerIdentifier
                    && $0.origin.externalTransactionID == externalID
            }
        }
        return records.firstIndex { $0.id == incoming.id }
    }

    private func normalized(_ record: BillRecord) -> BillRecord {
        var result = record
        result.amount = abs(record.amount)
        result.merchant = normalizedText(record.merchant)
        result.counterparty = normalizedText(record.counterparty)
        result.itemDescription = normalizedText(record.itemDescription)
        result.paymentMethod = normalizedText(record.paymentMethod)
        result.accountHint = normalizedText(record.accountHint)
        result.providerTransactionType = normalizedText(record.providerTransactionType)
        result.providerCategory = normalizedText(record.providerCategory)
        result.counterpartyAccount = normalizedText(record.counterpartyAccount)
        result.merchantTransactionID = normalizedText(record.merchantTransactionID)
        result.providerStatus = normalizedText(record.providerStatus)
        result.note = record.note.trimmingCharacters(in: .whitespacesAndNewlines)
        result.relatedTransactionID = normalizedOptional(record.relatedTransactionID)
        result.tags = normalizedTags(record.tags)
        result.origin.providerIdentifier = normalizedText(record.origin.providerIdentifier)
        result.origin.providerName = normalizedText(record.origin.providerName)
        result.origin.externalTransactionID = normalizedOptional(record.origin.externalTransactionID)
        result.origin.rawFields = Dictionary(uniqueKeysWithValues: record.origin.rawFields.compactMap { key, value in
            let normalizedKey = normalizedText(key)
            guard !normalizedKey.isEmpty else { return nil }
            return (normalizedKey, value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        return result
    }

    private func normalizedText(_ value: String) -> String {
        AppTagSupport.trimmed(value)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        AppTagSupport.trimmedNonEmpty(value)
    }

    private func normalizedTags(_ values: [String]) -> [String] {
        AppTagSupport.normalize(values)
    }

    private static func sorted(_ records: [BillRecord]) -> [BillRecord] {
        records.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.createdAt > $1.createdAt
        }
    }

    private static func normalizedTags(in record: BillRecord) -> BillRecord {
        var result = record
        result.tags = AppTagSupport.normalize(record.tags)
        return result
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
    }
}

#endif
