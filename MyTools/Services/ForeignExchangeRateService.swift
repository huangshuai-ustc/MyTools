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
        case .rateUnavailable: return "暂时无法取得中国银行现汇买入价。"
        }
    }
}

actor ForeignExchangeRateService {
    /// 一次读取中国银行页面中的全部受支持币种，股票和换汇功能共用这份结果。
    func fetchBuyingRates() async throws -> [ForeignExchangeRate] {
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

        let rates = CurrencyCode.selectableCases.compactMap { currency -> ForeignExchangeRate? in
            guard let bankName = currency.bankOfChinaName else { return nil }
            return parseBuyingRate(currencyCode: currency.rawValue, bankName: bankName, from: html)
        }
        guard rates.contains(where: { $0.currencyCode == "USD" }) else {
            throw ForeignExchangeRateError.rateUnavailable
        }
        return rates
    }

    private func parseBuyingRate(
        currencyCode: String,
        bankName: String,
        from html: String
    ) -> ForeignExchangeRate? {
        let escapedName = NSRegularExpression.escapedPattern(for: bankName)
        let pattern = "<tr[^>]*data-currency\\s*=\\s*['\"]"
            + escapedName
            + "['\"][^>]*>\\s*<td[^>]*>\\s*"
            + escapedName
            + "\\s*</td>\\s*<td[^>]*>\\s*([0-9.]+)\\s*</td>.*?<td[^>]*class\\s*=\\s*['\"]pjrq['\"][^>]*>\\s*([^<]+)\\s*</td>"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let rateRange = Range(match.range(at: 1), in: html),
              let rawRate = Decimal(
                string: String(html[rateRange]),
                locale: Locale(identifier: "en_US_POSIX")
              ),
              rawRate > 0 else { return nil }

        let updatedAt: Date
        if let dateRange = Range(match.range(at: 2), in: html) {
            updatedAt = parseBankDate(String(html[dateRange])) ?? Date()
        } else {
            updatedAt = Date()
        }
        return ForeignExchangeRate(
            currencyCode: currencyCode,
            renminbiPerUnit: rawRate / 100,
            updatedAt: updatedAt
        )
    }

    private func parseBankDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
    }
}
