import Foundation

struct ForeignExchangeRate: Sendable {
    let currencyCode: String
    /// 中国银行现汇买入价：用户结汇，1 单位外币可换多少人民币。
    let renminbiBuyingPerUnit: Decimal
    /// 中国银行现汇卖出价：用户购汇，购买 1 单位外币需要多少人民币。
    let renminbiSellingPerUnit: Decimal
    let updatedAt: Date
}

enum ForeignExchangeRateError: LocalizedError, Sendable {
    case invalidResponse
    case rateUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "中国银行外汇牌价返回了无效数据。"
        case .rateUnavailable: return "暂时无法取得中国银行结售汇牌价。"
        }
    }
}

actor ForeignExchangeRateService {
    /// 一次读取中国银行页面中的全部受支持币种，股票和换汇功能共用这份结果。
    func fetchRates() async throws -> [ForeignExchangeRate] {
        guard let url = URL(string: "https://www.boc.cn/sourcedb/whpj/") else {
            throw ForeignExchangeRateError.invalidResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("MyTools/1.3", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let html = decodeHTML(data) else {
            throw ForeignExchangeRateError.invalidResponse
        }

        let rates = CurrencyCode.selectableCases.compactMap { currency -> ForeignExchangeRate? in
            guard let bankName = currency.bankOfChinaName else { return nil }
            return parseRate(currencyCode: currency.rawValue, bankName: bankName, from: html)
        }
        guard rates.contains(where: { $0.currencyCode == "USD" }) else {
            throw ForeignExchangeRateError.rateUnavailable
        }
        return rates
    }

    private func parseRate(
        currencyCode: String,
        bankName: String,
        from html: String
    ) -> ForeignExchangeRate? {
        let escapedName = NSRegularExpression.escapedPattern(for: bankName)
        let pattern = "<tr[^>]*data-currency\\s*=\\s*['\"]"
            + escapedName
            + "['\"][^>]*>\\s*<td[^>]*>\\s*"
            + escapedName
            + "\\s*</td>\\s*<td[^>]*>\\s*([0-9.]+)\\s*</td>"
            + "\\s*<td[^>]*>.*?</td>"
            + "\\s*<td[^>]*>\\s*([0-9.]+)\\s*</td>.*?"
            + "<td[^>]*class\\s*=\\s*['\"]pjrq['\"][^>]*>\\s*([^<]+)\\s*</td>"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let buyingRateRange = Range(match.range(at: 1), in: html),
              let sellingRateRange = Range(match.range(at: 2), in: html),
              let rawBuyingRate = Decimal(
                string: String(html[buyingRateRange]),
                locale: Locale(identifier: "en_US_POSIX")
              ),
              let rawSellingRate = Decimal(
                string: String(html[sellingRateRange]),
                locale: Locale(identifier: "en_US_POSIX")
              ),
              rawBuyingRate > 0,
              rawSellingRate > 0 else { return nil }

        let updatedAt: Date
        if let dateRange = Range(match.range(at: 3), in: html) {
            updatedAt = parseBankDate(String(html[dateRange])) ?? Date()
        } else {
            updatedAt = Date()
        }
        return ForeignExchangeRate(
            currencyCode: currencyCode,
            renminbiBuyingPerUnit: rawBuyingRate / 100,
            renminbiSellingPerUnit: rawSellingRate / 100,
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
