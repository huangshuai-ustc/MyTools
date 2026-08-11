#if MYTOOLS_FEATURE_BILLS
import Foundation

struct BillOCRAmountCandidate: Identifiable, Equatable, Sendable {
    var id: String { "\(amount)-\(sourceLine)" }
    let amount: Decimal
    let sourceLine: String
    let score: Int
}

struct BillOCRSuggestion: Equatable, Sendable {
    var amountCandidates: [BillOCRAmountCandidate] = []
    var occurredAt: Date?
    var direction: BillDirection = .expense
    var merchant: String?
    var paymentMethod: String?
}

enum BillOCRParser {
    private static let amountPatterns = [
        #"(?:[¥￥]|RMB\s*|CNY\s*)([-+]?\d[\d,]*(?:\.\d{1,2})?)"#,
        #"([-+]?\d[\d,]*(?:\.\d{1,2})?)\s*元"#
    ]
    private static let paidAmountKeywords = ["实付", "实际支付", "付款金额", "支付金额"]
    private static let totalAmountKeywords = ["合计", "总计", "订单金额", "交易金额"]
    private static let incomeKeywords = ["收入", "收款到账", "已收款", "到账金额", "收入金额"]
    private static let merchantLabels = ["商户名称", "商家名称", "收款方"]
    private static let ignoredMerchantKeywords = [
        "支付成功", "交易成功", "付款成功", "订单号", "交易号", "商户单号", "支付方式",
        "实付", "支付金额", "付款金额", "合计", "总计", "交易时间", "收款方",
        "微信支付", "支付宝", "Apple Pay", "银行卡"
    ]

    static func parse(_ result: OCRResult, calendar: Calendar = .autoupdatingCurrent) -> BillOCRSuggestion {
        let lines = result.lines.map(\.text).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let fullText = lines.joined(separator: "\n")
        let direction: BillDirection
        if containsAny(fullText, values: ["退款", "已退回", "退回金额"]) {
            direction = .refund
        } else if containsAny(fullText, values: incomeKeywords) {
            direction = .income
        } else {
            direction = .expense
        }

        return BillOCRSuggestion(
            amountCandidates: amountCandidates(in: lines),
            occurredAt: firstDate(in: fullText, calendar: calendar),
            direction: direction,
            merchant: merchant(in: lines),
            paymentMethod: paymentMethod(in: fullText)
        )
    }

    private static func amountCandidates(in lines: [String]) -> [BillOCRAmountCandidate] {
        var candidates: [BillOCRAmountCandidate] = []
        for line in lines {
            for pattern in amountPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    continue
                }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in regex.matches(in: line, range: range) {
                    guard match.numberOfRanges > 1,
                          let valueRange = Range(match.range(at: 1), in: line),
                          let amount = DecimalTextParser.decimal(
                            from: String(line[valueRange]).replacingOccurrences(of: ",", with: "")
                          ), amount > 0 else { continue }
                    var score = 0
                    if paidAmountKeywords.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                        score += 200
                    } else if totalAmountKeywords.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                        score += 100
                    }
                    if line.contains("¥") || line.contains("￥") || line.contains("元") { score += 30 }
                    if String(line[valueRange]).contains(".") { score += 10 }
                    candidates.append(BillOCRAmountCandidate(amount: amount, sourceLine: line, score: score))
                }
            }
        }

        var seen = Set<Decimal>()
        return candidates
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.amount > rhs.amount : lhs.score > rhs.score
            }
            .filter { seen.insert($0.amount).inserted }
    }

    private static func merchant(in lines: [String]) -> String? {
        for line in lines {
            for label in merchantLabels {
                guard let range = line.range(of: label, options: [.caseInsensitive]) else { continue }
                let value = line[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ：:"))
                if value.count >= 2, value.count <= 40 {
                    return value
                }
            }
        }
        return lines.first { line in
            line.count >= 2
                && line.count <= 40
                && !ignoredMerchantKeywords.contains { line.localizedCaseInsensitiveContains($0) }
                && !line.contains("¥")
                && !line.contains("￥")
                && firstDate(in: line, calendar: .autoupdatingCurrent) == nil
        }
    }

    private static func paymentMethod(in text: String) -> String? {
        if text.localizedCaseInsensitiveContains("微信") { return "微信支付" }
        if text.localizedCaseInsensitiveContains("支付宝") { return "支付宝" }
        if text.localizedCaseInsensitiveContains("Apple Pay") { return "Apple Pay" }
        if text.localizedCaseInsensitiveContains("银行卡") { return "银行卡" }
        return nil
    }

    private static func firstDate(in text: String, calendar: Calendar) -> Date? {
        let pattern = #"(20\d{2})[年./-](\d{1,2})[月./-](\d{1,2})日?(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func integer(at index: Int) -> Int? {
            guard index < match.numberOfRanges,
                  match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = integer(at: 1)
        components.month = integer(at: 2)
        components.day = integer(at: 3)
        components.hour = integer(at: 4) ?? 0
        components.minute = integer(at: 5) ?? 0
        components.second = integer(at: 6) ?? 0
        return calendar.date(from: components)
    }

    private static func containsAny(_ text: String, values: [String]) -> Bool {
        values.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

#endif
