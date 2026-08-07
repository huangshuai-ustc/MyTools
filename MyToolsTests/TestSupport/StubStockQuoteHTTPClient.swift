import Foundation
@testable import MyTools

actor StubStockQuoteHTTPClient: StockQuoteHTTPClient {
    private let responseData: Data
    private var requests: [URLRequest] = []

    init(responseData: Data) {
        self.responseData = responseData
    }

    func data(for request: URLRequest) async throws -> Data {
        requests.append(request)
        return responseData
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
