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
    }

    func upsert(_ record: BillRecord) {
        var stored = normalized(record)
        guard stored.amount > 0 else { return }
        knownTags = AppTagSupport.merged(knownTags, with: stored.tags)
        stored.updatedAt = Date()
        if let index = records.firstIndex(where: { $0.id == stored.id }) {
            stored.createdAt = records[index].createdAt
            records[index] = stored
        } else {
            stored.createdAt = stored.updatedAt
            records.append(stored)
        }
        records = Self.sorted(records)
        didMutate()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        records.removeAll { ids.contains($0.id) }
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
                stored.id = records[index].id
                stored.createdAt = records[index].createdAt
                stored.updatedAt = Date()
                records[index] = stored
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

    private func matchingIndex(for incoming: BillRecord) -> Int? {
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
