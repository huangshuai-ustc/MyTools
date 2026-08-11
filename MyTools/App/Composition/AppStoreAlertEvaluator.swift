import Foundation

enum AppStoreAlertEvaluator {
    static func matchingCurrencyAlertIDs(
        alerts: [CurrencyRateAlert],
        rates: [CurrencyCode: Decimal]
    ) -> Set<UUID> {
        Set(alerts.compactMap { alert in
            guard alert.isEnabled,
                  let value = alert.convertedValue(using: rates),
                  alert.direction.matches(value, threshold: alert.threshold) else {
                return nil
            }
            return alert.id
        })
    }

#if MYTOOLS_FEATURE_STOCKS
    static func matchingStockAlertIDs(
        alerts: [StockPriceAlert],
        stocks: [StockHolding]
    ) -> Set<UUID> {
        var pricesByStockID: [UUID: Decimal] = [:]
        for stock in stocks {
            if let latestPrice = stock.latestPrice {
                pricesByStockID[stock.id] = latestPrice
            }
        }
        return Set(alerts.compactMap { alert in
            guard alert.isEnabled,
                  let stockID = alert.stockID,
                  let price = pricesByStockID[stockID],
                  alert.direction.matches(price, threshold: alert.threshold) else {
                return nil
            }
            return alert.id
        })
    }
#endif
}
