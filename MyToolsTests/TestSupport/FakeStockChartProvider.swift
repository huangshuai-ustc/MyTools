import Foundation
@testable import MyTools

actor StockChartProviderCallRecorder {
    private var providerIDs: [String] = []

    func record(_ providerID: String) {
        providerIDs.append(providerID)
    }

    func calls() -> [String] {
        providerIDs
    }
}

struct FakeStockChartProvider: StockChartProvider {
    enum Behavior: Sendable {
        case success(StockChartSnapshot)
        case failure(StockChartError)
    }

    let id: String
    let behavior: Behavior
    let recorder: StockChartProviderCallRecorder

    func fetchChart(for request: StockChartRequest) async throws -> StockChartSnapshot {
        await recorder.record(id)
        switch behavior {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}
