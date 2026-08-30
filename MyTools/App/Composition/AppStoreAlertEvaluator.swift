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

    // MARK: - Generic dispatch

    /// Dispatch phase: for each alert in `matchingIDs`, call `shouldSend` and
    /// fire the notification if the transition just occurred; collect triggered
    /// IDs for the caller to disable. Also resets edge-detect state for alerts
    /// that are disabled or no longer matching so future re-entries fire again.
    ///
    /// This generic loop was previously duplicated verbatim in `StockStore` and
    /// `CurrencyExchangeStore`. Centralising it here ensures both modules share
    /// the same "fire once on rising edge, then disable" semantics.
    @MainActor
    static func dispatchAlerts<Alert: Identifiable>(
        alerts: [Alert],
        matchingIDs: Set<UUID>,
        isEnabled: (Alert) -> Bool,
        notifications: any AlertNotificationRouting,
        makeNotification: (Alert) -> (title: String, body: String)?
    ) -> Set<UUID> where Alert.ID == UUID {
        var triggeredIDs = Set<UUID>()
        for alert in alerts {
            guard isEnabled(alert) else {
                // Reset edge-detect state so the alert can fire again if re-enabled.
                _ = notifications.shouldSend(for: alert.id, condition: false)
                continue
            }
            guard notifications.shouldSend(
                for: alert.id,
                condition: matchingIDs.contains(alert.id)
            ) else { continue }
            guard let notification = makeNotification(alert) else { continue }
            notifications.send(title: notification.title, body: notification.body, ruleID: alert.id)
            triggeredIDs.insert(alert.id)
        }
        return triggeredIDs
    }
}
