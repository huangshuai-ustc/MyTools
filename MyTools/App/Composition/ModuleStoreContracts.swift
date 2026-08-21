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
