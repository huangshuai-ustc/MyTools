import Foundation
import Testing
@testable import MyTools

struct AppStoreAlertEvaluatorTests {
    @Test func currencyAlertsUseConvertedAmountAndStrictComparison() {
        let aboveID = UUID()
        let belowID = UUID()
        let equalID = UUID()
        let disabledID = UUID()
        let missingRateID = UUID()
        let alerts = [
            CurrencyRateAlert(id: aboveID, amount: 100, direction: .above, threshold: 699),
            CurrencyRateAlert(id: belowID, amount: 100, direction: .below, threshold: 701),
            CurrencyRateAlert(id: equalID, amount: 100, direction: .above, threshold: 700),
            CurrencyRateAlert(
                id: disabledID,
                amount: 100,
                direction: .above,
                threshold: 1,
                isEnabled: false
            ),
            CurrencyRateAlert(
                id: missingRateID,
                currency: .eur,
                amount: 100,
                direction: .above,
                threshold: 1
            )
        ]

        let matches = AppStoreAlertEvaluator.matchingCurrencyAlertIDs(
            alerts: alerts,
            rates: [.usd: 7]
        )

        #expect(matches == [aboveID, belowID])
    }

    @Test func stockAlertsIgnoreMissingStockPriceAndDisabledRules() {
        let stockID = UUID()
        let noPriceStockID = UUID()
        var stock = StockHolding()
        stock.id = stockID
        stock.latestPrice = 50
        var noPriceStock = StockHolding()
        noPriceStock.id = noPriceStockID

        let aboveID = UUID()
        let belowID = UUID()
        let equalID = UUID()
        let missingStockID = UUID()
        let missingPriceID = UUID()
        let disabledID = UUID()
        let alerts = [
            StockPriceAlert(id: aboveID, stockID: stockID, direction: .above, threshold: 49),
            StockPriceAlert(id: belowID, stockID: stockID, direction: .below, threshold: 51),
            StockPriceAlert(id: equalID, stockID: stockID, direction: .above, threshold: 50),
            StockPriceAlert(id: missingStockID, stockID: UUID(), direction: .above, threshold: 1),
            StockPriceAlert(id: missingPriceID, stockID: noPriceStockID, direction: .above, threshold: 1),
            StockPriceAlert(
                id: disabledID,
                stockID: stockID,
                direction: .above,
                threshold: 1,
                isEnabled: false
            )
        ]

        let matches = AppStoreAlertEvaluator.matchingStockAlertIDs(
            alerts: alerts,
            stocks: [stock, noPriceStock]
        )

        #expect(matches == [aboveID, belowID])
    }
}
