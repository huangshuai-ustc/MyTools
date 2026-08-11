#if MYTOOLS_FEATURE_DOCUMENTS
import Foundation

struct CredentialOCRSuggestion: Equatable, Sendable {
    var holderName: String?
    var documentNumber: String?
    var issuingAuthority: String?
    var issuedAt: Date?
    var validityStart: Date?
    var validityEnd: Date?
    var isPermanent = false
    var fieldValues: [String: String] = [:]

    var isEmpty: Bool {
        holderName == nil
            && documentNumber == nil
            && issuingAuthority == nil
            && issuedAt == nil
            && validityStart == nil
            && validityEnd == nil
            && !isPermanent
            && fieldValues.isEmpty
    }
}

enum CredentialOCRParser {
    static func parse(
        _ result: OCRResult,
        for type: CredentialDocumentType,
        calendar: Calendar = .autoupdatingCurrent
    ) -> CredentialOCRSuggestion {
        let lines = result.lines.map(\.text)
        let text = lines.joined(separator: "\n")
        let recognizedLabels = recognizedLabels(for: type)
        var suggestion = CredentialOCRSuggestion()

        suggestion.holderName = value(
            afterAny: ["持有人姓名", "姓名", "权利人"],
            in: lines,
            stoppingAt: recognizedLabels
        )
        suggestion.issuingAuthority = value(
            afterAny: ["签发机关", "发证机关", "登记机构", "签发单位", "授予单位"],
            in: lines,
            stoppingAt: recognizedLabels
        )
        suggestion.documentNumber = documentNumber(in: text, lines: lines, type: type)
        var birthDate = date(
            afterAny: ["出生日期", "出生"],
            in: lines,
            stoppingAt: recognizedLabels,
            calendar: calendar
        )
        suggestion.issuedAt = date(
            afterAny: ["签发日期", "初次领证日期", "发证日期", "登记日期"],
            in: lines,
            stoppingAt: recognizedLabels,
            calendar: calendar
        )

        if let validityIndex = lines.firstIndex(where: {
            $0.contains("有效期") || $0.contains("有效期限")
        }) {
            let endIndex = min(validityIndex + 1, lines.index(before: lines.endIndex))
            let validityText = lines[validityIndex...endIndex].joined(separator: " ")
            suggestion.isPermanent = validityText.contains("长期")
            let dates = dates(in: validityText, calendar: calendar)
            if dates.count >= 2 {
                suggestion.validityStart = dates[0]
                suggestion.validityEnd = dates[1]
            } else if let onlyDate = dates.first {
                suggestion.validityEnd = onlyDate
            }
        }

        if birthDate == nil,
           type == .identityCard,
           let number = suggestion.documentNumber {
            birthDate = identityCardBirthDate(number, calendar: calendar)
        }
        if let birthDate {
            suggestion.fieldValues["出生日期"] = AppDateFormatter.string(from: birthDate)
        }
        if suggestion.issuedAt == nil, type == .identityCard {
            suggestion.issuedAt = suggestion.validityStart
        }

        for field in type.defaultFields {
            if let value = value(
                afterAny: [field.label],
                in: lines,
                stoppingAt: recognizedLabels,
                allowsContinuation: field.kind == .multiline
            ), !value.isEmpty {
                suggestion.fieldValues[field.label] = value
            }
        }
        for (label, value) in explicitKeyValuePairs(in: lines) {
            guard !recognizedLabels.contains(label), suggestion.fieldValues[label] == nil else {
                continue
            }
            suggestion.fieldValues[label] = value
        }
        return suggestion
    }

    private static func documentNumber(
        in text: String,
        lines: [String],
        type: CredentialDocumentType
    ) -> String? {
        let patterns: [String]
        switch type {
        case .identityCard:
            patterns = [#"(?<!\d)\d{17}[0-9Xx](?!\w)"#]
        case .passport:
            patterns = [#"(?<![A-Z0-9])[A-Z][0-9]{8}(?![A-Z0-9])"#]
        case .hongKongMacaoPermit:
            patterns = [#"(?<![A-Z0-9])[CW][0-9]{8,10}(?![A-Z0-9])"#]
        case .driversLicense:
            patterns = [#"(?<!\d)\d{17}[0-9Xx](?!\w)"#]
        case .educationCertificate, .degreeCertificate, .propertyOwnershipCertificate, .other:
            patterns = []
        }
        let normalized = text.uppercased().replacingOccurrences(of: " ", with: "")
        for pattern in patterns {
            if let value = firstMatch(pattern, in: normalized) {
                return value.uppercased()
            }
        }
        return value(
            afterAny: ["公民身份号码", "证件号码", "护照号码", "证号", "编号"],
            in: lines,
            stoppingAt: recognizedLabels(for: type)
        )?.replacingOccurrences(of: " ", with: "")
    }

    private static func value(
        afterAny labels: [String],
        in lines: [String],
        stoppingAt recognizedLabels: [String],
        allowsContinuation: Bool = false
    ) -> String? {
        for (index, line) in lines.enumerated() {
            for label in labels {
                guard let range = line.range(of: label) else { continue }
                var pieces: [String] = []
                let trailing = valueSegment(
                    in: line,
                    after: range.upperBound,
                    stoppingAt: recognizedLabels
                )
                if !trailing.isEmpty { pieces.append(trailing) }

                var nextIndex = index + 1
                while lines.indices.contains(nextIndex) {
                    let next = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !next.isEmpty else {
                        nextIndex += 1
                        continue
                    }
                    let startsAnotherField = recognizedLabels.contains { next.contains($0) }
                    guard !startsAnotherField, !looksLikeDocumentNumber(next) else { break }
                    if pieces.isEmpty || allowsContinuation {
                        pieces.append(next)
                    }
                    if !allowsContinuation { break }
                    nextIndex += 1
                }
                let combined = pieces.joined()
                if !combined.isEmpty { return combined }
            }
        }
        return nil
    }

    private static func date(
        afterAny labels: [String],
        in lines: [String],
        stoppingAt recognizedLabels: [String],
        calendar: Calendar
    ) -> Date? {
        guard let raw = value(
            afterAny: labels,
            in: lines,
            stoppingAt: recognizedLabels
        ) else { return nil }
        return dates(in: raw, calendar: calendar).first
    }

    private static func valueSegment(
        in line: String,
        after start: String.Index,
        stoppingAt recognizedLabels: [String]
    ) -> String {
        let remainingRange = start..<line.endIndex
        let nextLabelStart = recognizedLabels.compactMap { label in
            line.range(of: label, range: remainingRange)?.lowerBound
        }.min()
        let end = nextLabelStart ?? line.endIndex
        return line[start..<end]
            .trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,\t"))
    }

    private static func explicitKeyValuePairs(in lines: [String]) -> [(String, String)] {
        lines.compactMap { line in
            guard let separator = line.firstIndex(where: { $0 == "：" || $0 == ":" || $0 == "\t" }) else {
                return nil
            }
            let label = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 16, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    private static func recognizedLabels(for type: CredentialDocumentType) -> [String] {
        let coreLabels = [
            "持有人姓名", "公民身份号码", "初次领证日期", "出生日期", "有效期限",
            "签发机关", "发证机关", "登记机构", "签发单位", "授予单位", "签发日期",
            "发证日期", "登记日期", "证件号码", "护照号码", "姓名", "权利人", "出生",
            "有效期", "证号", "编号"
        ]
        return Array(Set(coreLabels + type.defaultFields.map(\.label))).sorted {
            $0.count > $1.count
        }
    }

    private static func looksLikeDocumentNumber(_ text: String) -> Bool {
        let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
        return firstMatch(#"^\d{17}[0-9X]$"#, in: compact) != nil
            || firstMatch(#"^[A-Z][0-9]{8,10}$"#, in: compact) != nil
    }

    private static func dates(in text: String, calendar: Calendar) -> [Date] {
        let patterns = [
            #"(?:19|20)\d{2}[年./-]\d{1,2}[月./-]\d{1,2}日?"#,
            #"(?:19|20)\d{6}"#
        ]
        var values: [Date] = []
        for pattern in patterns {
            for match in allMatches(pattern, in: text) {
                if let value = parseDate(match, calendar: calendar), !values.contains(value) {
                    values.append(value)
                }
            }
        }
        return values.sorted()
    }

    private static func parseDate(_ raw: String, calendar: Calendar) -> Date? {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 8,
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.suffix(2)) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func identityCardBirthDate(_ number: String, calendar: Calendar) -> Date? {
        let normalized = number.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard normalized.count == 18 else { return nil }
        let start = normalized.index(normalized.startIndex, offsetBy: 6)
        let end = normalized.index(start, offsetBy: 8)
        return parseDate(String(normalized[start..<end]), calendar: calendar)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }
}

extension CredentialDocument {
    mutating func applyOCRSuggestion(
        _ suggestion: CredentialOCRSuggestion,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        if let value = suggestion.holderName { holderName = value }
        if let value = suggestion.documentNumber { documentNumber = value }
        if let value = suggestion.issuingAuthority { issuingAuthority = value }
        if let value = suggestion.issuedAt { issuedAt = value }

        if type == .identityCard {
            if let startDate = suggestion.validityStart {
                issuedAt = startDate
            }
            if suggestion.isPermanent {
                validity = CredentialValidity(kind: .permanent)
            } else if let startDate = suggestion.validityStart,
                      let endDate = suggestion.validityEnd,
                      let term = CredentialValidityKind.identityCardTerm(
                          from: startDate,
                          to: endDate,
                          calendar: calendar
                      ) {
                validity = CredentialValidity(kind: term)
            }
        } else if suggestion.isPermanent {
            validity.kind = .permanent
            validity.startDate = suggestion.validityStart
            validity.endDate = nil
        } else if suggestion.validityStart != nil || suggestion.validityEnd != nil {
            validity.kind = .dateRange
            validity.startDate = suggestion.validityStart
            validity.endDate = suggestion.validityEnd ?? validity.endDate ?? Date()
        }

        for (label, value) in suggestion.fieldValues.sorted(by: { $0.key < $1.key }) {
            if let index = fields.firstIndex(where: {
                $0.label.localizedCaseInsensitiveCompare(label) == .orderedSame
            }) {
                fields[index].value = value
            } else {
                fields.append(
                    CredentialField(
                        label: label,
                        value: value,
                        kind: Self.inferredOCRFieldKind(for: label)
                    )
                )
            }
        }
    }

    private static func inferredOCRFieldKind(for label: String) -> CredentialFieldKind {
        ["地址", "住址", "坐落", "备注", "说明"].contains { label.contains($0) }
            ? .multiline
            : .text
    }
}

#endif
