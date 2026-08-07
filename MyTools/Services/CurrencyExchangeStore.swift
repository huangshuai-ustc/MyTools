import Foundation

@MainActor
final class CurrencyExchangeStore: ObservableObject, ExchangeRateUpdateObserving {
    @Published private(set) var records: [CurrencyExchangeRecord]
    @Published private(set) var rateAlerts: [CurrencyRateAlert]

    private let alertNotifications: any AlertNotificationRouting
    private weak var moduleSettings: ToolModuleSettings?
    private weak var exchangeRateStore: ExchangeRateStore?
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    init(
        records: [CurrencyExchangeRecord] = [],
        rateAlerts: [CurrencyRateAlert] = [],
        alertNotifications: any AlertNotificationRouting,
        moduleSettings: ToolModuleSettings? = nil,
        exchangeRateStore: ExchangeRateStore? = nil
    ) {
        self.records = records
        self.rateAlerts = rateAlerts
        self.alertNotifications = alertNotifications
        self.moduleSettings = moduleSettings
        self.exchangeRateStore = exchangeRateStore
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(
        records: [CurrencyExchangeRecord],
        rateAlerts: [CurrencyRateAlert]
    ) {
        self.records = records
        self.rateAlerts = rateAlerts
    }

    func moduleVisibilityChanged(isVisible: Bool) {
        guard isVisible, let exchangeRateStore else { return }
        evaluateRateAlerts(using: exchangeRateStore.renminbiBuyingRates)
    }

    func upsertRecord(_ record: CurrencyExchangeRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        didMutate()
    }

    func deleteRecords(ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        didMutate()
    }

    func upsertRateAlert(_ alert: CurrencyRateAlert) {
        guard alert.amount > 0, alert.threshold > 0 else { return }
        if let index = rateAlerts.firstIndex(where: { $0.id == alert.id }) {
            rateAlerts[index] = alert
        } else {
            rateAlerts.append(alert)
        }
        alertNotifications.clearState(for: alert.id)
        didMutate()
    }

    func deleteRateAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        rateAlerts.removeAll { alert in
            if ids.contains(alert.id) {
                alertNotifications.clearState(for: alert.id)
                return true
            }
            return false
        }
        didMutate()
    }

    func clearNotificationState(for ids: Set<UUID>) {
        ids.forEach(alertNotifications.clearState)
    }

    func exchangeRatesDidUpdate(_ rates: [CurrencyCode: Decimal]) {
        evaluateRateAlerts(using: rates)
    }

    private var isModuleVisible: Bool {
        moduleSettings?.isVisible(.currencyExchange) ?? true
    }

    private func evaluateRateAlerts(using rates: [CurrencyCode: Decimal]) {
        guard isModuleVisible else { return }
        let matchingAlertIDs = AppStoreAlertEvaluator.matchingCurrencyAlertIDs(
            alerts: rateAlerts,
            rates: rates
        )
        var triggeredAlertIDs = Set<UUID>()
        for alert in rateAlerts {
            guard alert.isEnabled else {
                _ = alertNotifications.shouldSend(for: alert.id, condition: false)
                continue
            }
            guard let value = alert.convertedValue(using: rates) else { continue }
            guard alertNotifications.shouldSend(
                for: alert.id,
                condition: matchingAlertIDs.contains(alert.id)
            ) else { continue }
            alertNotifications.send(
                title: "换汇价格提醒",
                body: "\(CurrencyExchangeValueFormatter.amount(alert.amount, currency: alert.currency)) 约合 \(CurrencyExchangeValueFormatter.amount(value, currency: .cny))，已\(alert.direction.title) \(CurrencyExchangeValueFormatter.amount(alert.threshold, currency: .cny))。",
                ruleID: alert.id
            )
            triggeredAlertIDs.insert(alert.id)
        }
        disableRateAlerts(ids: triggeredAlertIDs)
    }

    private func disableRateAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var didChange = false
        for index in rateAlerts.indices where ids.contains(rateAlerts[index].id) {
            guard rateAlerts[index].isEnabled else { continue }
            rateAlerts[index].isEnabled = false
            alertNotifications.clearState(for: rateAlerts[index].id)
            didChange = true
        }
        if didChange { didMutate() }
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
    }
}
