import Foundation
@testable import MyTools

struct StubStockChartHTTPClient: StockChartHTTPClient {
    let responseData: Data

    func data(for url: URL, referer: String) async throws -> Data {
        responseData
    }
}
