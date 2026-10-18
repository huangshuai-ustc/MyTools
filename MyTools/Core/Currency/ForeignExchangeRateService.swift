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

        let rates = Self.parseRates(from: html)
        guard rates.contains(where: { $0.currencyCode == "USD" }) else {
            throw ForeignExchangeRateError.rateUnavailable
        }
        return rates
    }

    static func parseRates(from html: String) -> [ForeignExchangeRate] {
        CurrencyCode.selectableCases.compactMap { currency -> ForeignExchangeRate? in
            guard let bankName = currency.bankOfChinaName else { return nil }
            return parseRate(currencyCode: currency.rawValue, bankName: bankName, from: html)
        }
    }

    /// Row cells: name, 现汇买入, 现钞买入, 现汇卖出, 现钞卖出, 折算价, 发布时间.
    /// Currencies without spot prices (CZK, ILS) fall back to the cash
    /// prices instead of disappearing from the snapshot (AUDIT-045).
    private static func parseRate(
        currencyCode: String,
        bankName: String,
        from html: String
    ) -> ForeignExchangeRate? {
        let escapedName = NSRegularExpression.escapedPattern(for: bankName)
        let rowPattern = "<tr[^>]*data-currency\\s*=\\s*['\"]" + escapedName + "['\"][^>]*>(.*?)</tr>"
        guard let rowExpression = try? NSRegularExpression(
            pattern: rowPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
              let cellExpression = try? NSRegularExpression(
                pattern: "<td([^>]*)>(.*?)</td>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
              ),
              let row = rowExpression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let rowRange = Range(row.range(at: 1), in: html) else { return nil }
        let rowHTML = String(html[rowRange])
        let cells = cellExpression.matches(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML)).map { match in
            (
                attributes: Range(match.range(at: 1), in: rowHTML).map { String(rowHTML[$0]) } ?? "",
                text: Range(match.range(at: 2), in: rowHTML)
                    .map { String(rowHTML[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            )
        }
        guard cells.count >= 5,
              cells[0].text == bankName else { return nil }
        func price(_ index: Int) -> Decimal? {
            Decimal(string: cells[index].text, locale: Locale(identifier: "en_US_POSIX"))
                .flatMap { $0 > 0 ? $0 : nil }
        }
        guard let rawBuyingRate = price(1) ?? price(2),
              let rawSellingRate = price(3) ?? price(4) else { return nil }

        let updatedAt = cells.first { $0.attributes.contains("pjrq") }
            .flatMap { parseBankDate($0.text) } ?? Date()
        return ForeignExchangeRate(
            currencyCode: currencyCode,
            renminbiBuyingPerUnit: rawBuyingRate / 100,
            renminbiSellingPerUnit: rawSellingRate / 100,
            updatedAt: updatedAt
        )
    }

    private static func parseBankDate(_ text: String) -> Date? {
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
