import Foundation

@MainActor
protocol VaultMutationNotifying: AnyObject {
    func moduleStoreDidMutate()
    func moduleStoreDidMutateLocalOnly()
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

    var id: String { "\(module.rawValue).\(ruleID)" }
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
        fieldCount: Int
    ) {
        guard fieldCount > 0 else { return }
        findings.append(RedundantDataFinding(
            ruleID: ruleID,
            module: cleanupModule,
            title: title,
            detail: detail,
            affectedRecordCount: recordCount,
            affectedFieldCount: fieldCount
        ))
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
