import Foundation

@MainActor
protocol VaultMutationNotifying: AnyObject {
    func moduleStoreDidMutate()
}

@MainActor
protocol ExchangeRateUpdateObserving: AnyObject {
    func exchangeRatesDidUpdate(_ rates: [CurrencyCode: Decimal])
}
