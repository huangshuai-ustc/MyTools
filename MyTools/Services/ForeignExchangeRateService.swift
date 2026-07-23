import Foundation

struct ForeignExchangeRate: Sendable {
    let currencyCode: String
    let renminbiPerUnit: Decimal
    let updatedAt: Date
}

enum ForeignExchangeRateError: LocalizedError, Sendable {
    case invalidResponse
    case rateUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "中国银行外汇牌价返回了无效数据。"
        case .rateUnavailable: return "暂时无法取得中国银行美元现汇买入价。"
        }
    }
}

actor ForeignExchangeRateService {
    func fetchUSDBuyingRate() async throws -> ForeignExchangeRate {
        guard let url = URL(string: "https://www.boc.cn/sourcedb/whpj/") else {
            throw ForeignExchangeRateError.invalidResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("MyTools/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let html = decodeHTML(data) else {
            throw ForeignExchangeRateError.invalidResponse
        }

        let pattern = #"<tr[^>]*data-currency=['\"]美元['\"][^>]*>.*?<td[^>]*>\s*美元\s*</td>\s*<td[^>]*>\s*([0-9.]+)\s*</td>.*?<td[^>]*class=['\"]pjrq['\"][^>]*>\s*([^<]+)\s*</td>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let rateRange = Range(match.range(at: 1), in: html),
              let rawRate = Decimal(string: String(html[rateRange]), locale: Locale(identifier: "en_US_POSIX")) else {
            throw ForeignExchangeRateError.rateUnavailable
        }

        let updatedAt: Date
        if let dateRange = Range(match.range(at: 2), in: html) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
            updatedAt = formatter.date(from: String(html[dateRange]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date()
        } else {
            updatedAt = Date()
        }

        return ForeignExchangeRate(currencyCode: "USD", renminbiPerUnit: rawRate / 100, updatedAt: updatedAt)
    }

    private func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
    }
}

