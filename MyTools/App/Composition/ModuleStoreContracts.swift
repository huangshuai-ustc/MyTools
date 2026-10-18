import Foundation

@MainActor
protocol VaultMutationNotifying: AnyObject {
    func moduleStoreDidMutate()
    func moduleStoreDidMutateLocalOnly()
    func scheduleAttachmentRemovalAfterPersistence(_ attachments: [FileAttachment])
}

extension VaultMutationNotifying {
    func scheduleAttachmentRemovalAfterPersistence(_ attachments: [FileAttachment]) {}
}

@MainActor
protocol ExchangeRateUpdateObserving: AnyObject {
    func exchangeRatesDidUpdate(_ rates: [CurrencyCode: Decimal])
}

@MainActor
protocol ModuleLifecycleParticipant: AnyObject {
    var observedModules: Set<ToolModule> { get }
    func moduleDidChange(_ module: ToolModule, isEnabled: Bool)
}

@MainActor
final class ModuleLifecycleRegistry {
    private var participants: [any ModuleLifecycleParticipant] = []

    func register(_ participant: any ModuleLifecycleParticipant) {
        participants.append(participant)
    }

    func notify(module: ToolModule, isEnabled: Bool) {
        for participant in participants where participant.observedModules.contains(module) {
            participant.moduleDidChange(module, isEnabled: isEnabled)
        }
    }
}

// MARK: - Backup restore coordination

/// A module Store that needs to suppress internal mutations while a backup
/// restore is in progress adopts this protocol. `AppStore` broadcasts the
/// backup-restore lifecycle to all registered participants rather than calling
/// a module-specific method, so future modules do not require changes in
/// `AppStore.restoreBackup`.
@MainActor
protocol BackupRestoreParticipant: AnyObject {
    /// Called with `true` immediately before the backup payload is applied and
    /// with `false` in the `defer` block after the restore completes or throws.
    func backupRestoreStateChanged(isRestoring: Bool)
}

@MainActor
final class BackupRestoreRegistry {
    private var participants: [any BackupRestoreParticipant] = []

    func register(_ participant: any BackupRestoreParticipant) {
        participants.append(participant)
    }

    func notifyStarted() {
        participants.forEach { $0.backupRestoreStateChanged(isRestoring: true) }
    }

    func notifyFinished() {
        participants.forEach { $0.backupRestoreStateChanged(isRestoring: false) }
    }
}

// MARK: - Redundant data cleanup

struct RedundantDataFinding: Identifiable, Equatable, Sendable {
    let ruleID: String
    let module: ToolModule
    let title: String
    let detail: String
    let affectedRecordCount: Int
    let affectedFieldCount: Int
    /// Per-record breakdown shown in Settings so the user can see exactly what will be cleared.
    var items: [RedundantDataItem] = []

    var id: String { "\(module.rawValue).\(ruleID)" }
}

struct RedundantDataItem: Identifiable, Equatable, Sendable {
    let id: String
    let recordTitle: String
    let fieldNames: [String]
}

struct RedundantDataCleanupReport: Equatable, Sendable {
    let findings: [RedundantDataFinding]

    static let empty = RedundantDataCleanupReport(findings: [])

    var affectedFieldCount: Int {
        findings.reduce(0) { $0 + $1.affectedFieldCount }
    }

    var isEmpty: Bool { findings.isEmpty }
}

@MainActor
protocol ModuleDataCleanupParticipant: AnyObject {
    var cleanupModule: ToolModule { get }
    func scanRedundantData() -> [RedundantDataFinding]
    func cleanupRedundantData()
}

@MainActor
extension ModuleDataCleanupParticipant {
    /// Convenience builder: appends a `RedundantDataFinding` only when
    /// `fieldCount > 0`, removing the guard boilerplate from every Store's
    /// `scanRedundantData` implementation.
    func appendFinding(
        to findings: inout [RedundantDataFinding],
        ruleID: String,
        title: String,
        detail: String,
        recordCount: Int,
        fieldCount: Int,
        items: [RedundantDataItem] = []
    ) {
        guard fieldCount > 0 else { return }
        findings.append(RedundantDataFinding(
            ruleID: ruleID,
            module: cleanupModule,
            title: title,
            detail: detail,
            affectedRecordCount: recordCount,
            affectedFieldCount: fieldCount,
            items: items
        ))
    }

    /// Builds a finding whose counts are derived from its itemized records.
    func appendFinding(
        to findings: inout [RedundantDataFinding],
        ruleID: String,
        title: String,
        detail: String,
        items: [RedundantDataItem]
    ) {
        appendFinding(
            to: &findings,
            ruleID: ruleID,
            title: title,
            detail: detail,
            recordCount: items.count,
            fieldCount: items.reduce(0) { $0 + $1.fieldNames.count },
            items: items
        )
    }
}

@MainActor
final class ModuleDataCleanupRegistry {
    private var participants: [any ModuleDataCleanupParticipant] = []

    func register(_ participant: any ModuleDataCleanupParticipant) {
        participants.append(participant)
    }

    func scan(enabledModules: Set<ToolModule>) -> RedundantDataCleanupReport {
        RedundantDataCleanupReport(
            findings: participants
                .filter { enabledModules.contains($0.cleanupModule) }
                .flatMap { $0.scanRedundantData() }
        )
    }

    @discardableResult
    func cleanup(enabledModules: Set<ToolModule>) -> RedundantDataCleanupReport {
        let report = scan(enabledModules: enabledModules)
        guard !report.isEmpty else { return report }
        for participant in participants where enabledModules.contains(participant.cleanupModule) {
            participant.cleanupRedundantData()
        }
        return report
    }
}

// MARK: - Legacy data from removed modules

/// One stored record (or tag list / unknown field) left behind by a removed feature.
struct LegacyDataItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let attachmentStoredFileNames: [String]
}

struct LegacyDataFinding: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let items: [LegacyDataItem]
}

struct LegacyDataReport: Equatable, Sendable {
    let findings: [LegacyDataFinding]

    static let empty = LegacyDataReport(findings: [])

    var isEmpty: Bool { findings.isEmpty }
    var itemCount: Int { findings.reduce(0) { $0 + $1.items.count } }
    var attachmentStoredFileNames: [String] {
        Set(findings.flatMap { $0.items.flatMap(\.attachmentStoredFileNames) }).sorted()
    }
}

/// Finds and removes Vault payloads that no compiled feature can read: the
/// deleted Food Map / Partnership modules and top-level keys unknown to this
/// schema. Bills and Sports Lottery are only switched off at build time, so
/// their data is intentionally left alone.
enum LegacyVaultData {
    private static let removedModules: [(module: ToolModule, keys: [String])] = [
        (.foodMap, ["foodPlaces", "foodPlaceTags"]),
        (.partnership, ["partnershipBooks"])
    ]

    static func scan(_ vault: VaultData) -> LegacyDataReport {
        var findings: [LegacyDataFinding] = []
        let foodItems = records(vault.foodPlaces, preserved: vault.preservedModulePayloads["foodPlaces"], prefix: "foodPlace", titleKeys: ["shopName", "recommendedFood"], fallback: "未命名店铺")
            + tagItem(vault.foodPlaceTags, preserved: vault.preservedModulePayloads["foodPlaceTags"], id: "foodPlaceTags")
        if !foodItems.isEmpty {
            findings.append(LegacyDataFinding(id: ToolModule.foodMap.rawValue, title: "美食地图（已删除）", detail: "店铺记录、标签和店铺照片。", items: foodItems))
        }
        let partnershipItems = records(vault.partnershipBooks, preserved: vault.preservedModulePayloads["partnershipBooks"], prefix: "partnershipBook", titleKeys: ["name"], fallback: "未命名账本")
        if !partnershipItems.isEmpty {
            findings.append(LegacyDataFinding(id: ToolModule.partnership.rawValue, title: "合伙记账（已删除）", detail: "账本、成员和记账流水。", items: partnershipItems))
        }
        // Keys that also back a quarantined module stay put: they are that module's recovery copy.
        let unknownItems = unknownKeys(in: vault).map { key in
            LegacyDataItem(id: "unknown.\(key)", title: key, attachmentStoredFileNames: vault.unknownPayloads[key]?.attachmentStoredFileNames.sorted() ?? [])
        }
        if !unknownItems.isEmpty {
            findings.append(LegacyDataFinding(id: "unknownPayloads", title: "未使用的顶层字段", detail: "当前版本不再读取的档案字段，通常来自旧版本。", items: unknownItems))
        }
        return LegacyDataReport(findings: findings)
    }

    static func removing(from vault: VaultData) -> VaultData {
        var value = vault
        value.foodPlaces = []
        value.foodPlaceTags = []
        value.partnershipBooks = []
        for entry in removedModules {
            value.unavailableModules.remove(entry.module.rawValue)
            for key in entry.keys { value.preservedModulePayloads.removeValue(forKey: key) }
        }
        for key in unknownKeys(in: vault) { value.unknownPayloads.removeValue(forKey: key) }
        return value
    }

    private static func unknownKeys(in vault: VaultData) -> [String] {
        vault.unknownPayloads.keys.filter { vault.preservedModulePayloads[$0] == nil }.sorted()
    }

    private static func records(
        _ typed: [OpaqueModuleValue],
        preserved: OpaqueModuleValue?,
        prefix: String,
        titleKeys: [String],
        fallback: String
    ) -> [LegacyDataItem] {
        var values = typed
        if case .array(let raw)? = preserved { values += raw } else if let preserved { values.append(preserved) }
        return values.enumerated().map { index, value in
            let title = titleKeys.lazy.compactMap { string(value, $0) }.first ?? fallback
            return LegacyDataItem(
                id: "\(prefix).\(string(value, "id") ?? String(index))",
                title: title,
                attachmentStoredFileNames: value.attachmentStoredFileNames.sorted()
            )
        }
    }

    private static func tagItem(_ tags: [String], preserved: OpaqueModuleValue?, id: String) -> [LegacyDataItem] {
        var values = tags
        if case .array(let raw)? = preserved {
            values += raw.compactMap { if case .string(let tag) = $0 { tag } else { nil } }
        }
        guard !values.isEmpty else { return [] }
        return [LegacyDataItem(id: id, title: "标签：\(values.joined(separator: "、"))", attachmentStoredFileNames: [])]
    }

    private static func string(_ value: OpaqueModuleValue, _ key: String) -> String? {
        guard case .object(let object) = value, case .string(let text)? = object[key] else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
