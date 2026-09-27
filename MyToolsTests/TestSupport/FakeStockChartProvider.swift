import Foundation
@testable import MyTools

actor StockChartProviderCallRecorder {
    private var providerIDs: [String] = []
    private var requestedRanges: [StockChartRange] = []

    func record(_ providerID: String, range: StockChartRange) {
        providerIDs.append(providerID)
        requestedRanges.append(range)
    }

    func calls() -> [String] {
        providerIDs
    }

    func ranges() -> [StockChartRange] {
        requestedRanges
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
    var delay: Duration = .zero
    var behaviorsByRange: [StockChartRange: Behavior] = [:]
    var ignoresCancellation = false

    func fetchChart(for request: StockChartRequest) async throws -> StockChartSnapshot {
        await recorder.record(id, range: request.range)
        if delay > .zero {
            if ignoresCancellation {
                let components = delay.components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
                }
            } else { try await Task.sleep(for: delay) }
        }
        switch behaviorsByRange[request.range] ?? behavior {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}
