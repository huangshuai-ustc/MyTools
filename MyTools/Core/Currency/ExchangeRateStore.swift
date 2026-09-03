import Foundation

@MainActor
final class ExchangeRateStore: ObservableObject, ModuleLifecycleParticipant {
    @Published private(set) var renminbiBuyingRates: [CurrencyCode: Decimal] = [.cny: 1]
    @Published private(set) var renminbiSellingRates: [CurrencyCode: Decimal] = [.cny: 1]
    @Published private(set) var updatedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false

    private let repository: any ExchangeRateProviding
    private weak var updateObserver: (any ExchangeRateUpdateObserving)?
    private var lastRequestAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var enabledModules: Set<ToolModule>

    init(
        repository: any ExchangeRateProviding,
        initialEnabledModules: Set<ToolModule> = [.currencyExchange, .myStocks]
    ) {
        self.repository = repository
        self.enabledModules = initialEnabledModules
    }

    private var isCapabilityNeeded: Bool { !enabledModules.isEmpty }

    func attach(updateObserver: any ExchangeRateUpdateObserving) {
        self.updateObserver = updateObserver
    }

    func applyCachedSnapshot(_ snapshot: ExchangeRateSnapshot) {
        apply(snapshot)
    }

    var observedModules: Set<ToolModule> { [.currencyExchange, .myStocks] }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        let wasNeeded = isCapabilityNeeded
        if isEnabled {
            enabledModules.insert(module)
        } else {
            enabledModules.remove(module)
        }
        if isCapabilityNeeded {
            refreshIfNeeded()
        } else if wasNeeded {
            stopRefresh()
        }
    }

    func refreshIfNeeded() {
        guard isCapabilityNeeded else { return }
        if let lastRequestAt {
            let retryInterval: TimeInterval = error == nil ? 60 * 60 : 5 * 60
            guard Date().timeIntervalSince(lastRequestAt) >= retryInterval else { return }
        }
        refresh()
    }

    func refresh() {
        guard isCapabilityNeeded, !isRefreshing else { return }
        isRefreshing = true
        lastRequestAt = Date()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false }
            do {
                let snapshot = try await self.repository.fetchSnapshot()
                guard self.isCapabilityNeeded, !Task.isCancelled else { return }
                self.apply(snapshot)
                self.error = nil
                self.updateObserver?.exchangeRatesDidUpdate(self.renminbiBuyingRates)
                await self.repository.persist(snapshot: snapshot)
            } catch {
                guard self.isCapabilityNeeded, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                DiagnosticLogger.logError(
                    .exchangeRate,
                    operation: "外汇牌价刷新失败",
                    error: error
                )
            }
        }
    }

    func clearLocalCache() {
        refreshTask?.cancel()
        refreshTask = nil
        lastRequestAt = nil
        isRefreshing = false
        error = nil
        renminbiBuyingRates = [.cny: 1]
        renminbiSellingRates = [.cny: 1]
        updatedAt = nil
    }

    private func apply(_ snapshot: ExchangeRateSnapshot) {
        renminbiBuyingRates = snapshot.renminbiBuyingRates
        renminbiSellingRates = snapshot.renminbiSellingRates
        renminbiBuyingRates[.cny] = 1
        renminbiSellingRates[.cny] = 1
        updatedAt = snapshot.updatedAt
    }

    private func stopRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        lastRequestAt = nil
        isRefreshing = false
    }
}
