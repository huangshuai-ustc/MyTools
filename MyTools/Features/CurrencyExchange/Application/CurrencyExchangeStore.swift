#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
import Foundation

@MainActor
final class CurrencyExchangeStore: ObservableObject, ExchangeRateUpdateObserving, ModuleLifecycleParticipant {
    @Published private(set) var records: [CurrencyExchangeRecord]
    @Published private(set) var rateAlerts: [CurrencyRateAlert]

    private let alertNotifications: any AlertNotificationRouting
    private var isModuleVisible: Bool
    private weak var exchangeRateStore: ExchangeRateStore?
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    init(
        records: [CurrencyExchangeRecord] = [],
        rateAlerts: [CurrencyRateAlert] = [],
        alertNotifications: any AlertNotificationRouting,
        isModuleVisible: Bool = true,
        exchangeRateStore: ExchangeRateStore? = nil
    ) {
        self.records = records
        self.rateAlerts = rateAlerts
        self.alertNotifications = alertNotifications
        self.isModuleVisible = isModuleVisible
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
        DiagnosticLogger.shared.log(.data, "换汇数据替换 records=\(records.count) alerts=\(rateAlerts.count)")
    }

    func moduleVisibilityChanged(isVisible: Bool) {
        guard isVisible, let exchangeRateStore else { return }
        evaluateRateAlerts(using: exchangeRateStore.renminbiBuyingRates)
    }

    var observedModules: Set<ToolModule> { [.currencyExchange] }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        isModuleVisible = isEnabled
        moduleVisibilityChanged(isVisible: isEnabled)
    }

    func upsertRecord(_ record: CurrencyExchangeRecord) {
        let isUpdate = records.contains { $0.id == record.id }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        DiagnosticLogger.shared.log(.data, "换汇记录\(isUpdate ? "更新" : "新增") id=\(record.id)")
        didMutate()
    }

    func deleteRecords(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        records.removeAll { ids.contains($0.id) }
        DiagnosticLogger.shared.log(.data, "换汇记录删除 count=\(ids.count)")
        didMutate()
    }

    func upsertRateAlert(_ alert: CurrencyRateAlert) {
        guard alert.amount > 0, alert.threshold > 0 else {
            DiagnosticLogger.shared.log(.data, "汇率提醒被拒绝（无效金额或阈值） id=\(alert.id)", level: .warning)
            return
        }
        let isUpdate = rateAlerts.contains { $0.id == alert.id }
        if let index = rateAlerts.firstIndex(where: { $0.id == alert.id }) {
            rateAlerts[index] = alert
        } else {
            rateAlerts.append(alert)
        }
        alertNotifications.clearState(for: alert.id)
        DiagnosticLogger.shared.log(.data, "汇率提醒\(isUpdate ? "更新" : "新增") id=\(alert.id)")
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
        DiagnosticLogger.shared.log(.data, "汇率提醒删除 count=\(ids.count)")
        didMutate()
    }

    func clearNotificationState(for ids: Set<UUID>) {
        ids.forEach(alertNotifications.clearState)
    }

    func exchangeRatesDidUpdate(_ rates: [CurrencyCode: Decimal]) {
        evaluateRateAlerts(using: rates)
    }

    private func evaluateRateAlerts(using rates: [CurrencyCode: Decimal]) {
        guard isModuleVisible else { return }
        let matchingAlertIDs = AppStoreAlertEvaluator.matchingCurrencyAlertIDs(
            alerts: rateAlerts,
            rates: rates
        )
        let triggeredAlertIDs = AppStoreAlertEvaluator.dispatchAlerts(
            alerts: rateAlerts,
            matchingIDs: matchingAlertIDs,
            isEnabled: \.isEnabled,
            notifications: alertNotifications
        ) { alert in
            guard let value = alert.convertedValue(using: rates) else { return nil }
            return (
                title: "换汇价格提醒",
                body: "\(CurrencyExchangeValueFormatter.amount(alert.amount, currency: alert.currency)) 约合 \(CurrencyExchangeValueFormatter.amount(value, currency: .cny))，已\(alert.direction.title) \(CurrencyExchangeValueFormatter.amount(alert.threshold, currency: .cny))。"
            )
        }
        if !triggeredAlertIDs.isEmpty {
            DiagnosticLogger.shared.log(.notification, "汇率提醒触发 count=\(triggeredAlertIDs.count)")
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

#endif
