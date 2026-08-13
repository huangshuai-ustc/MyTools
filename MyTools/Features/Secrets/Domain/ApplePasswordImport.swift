#if MYTOOLS_FEATURE_SECRETS
import Foundation

enum ApplePasswordImportError: LocalizedError, Equatable {
    case unsupportedFile
    case unreadableFile
    case missingHeaders([String])
    case noRecords

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "当前支持导入 Apple 密码 App 导出的 CSV 文件。请先在 Numbers 中将表格导出为 CSV。"
        case .unreadableFile:
            return "无法读取密码文件，请确认文件使用 UTF-8 编码。"
        case .missingHeaders(let headers):
            return "密码文件缺少必要列：\(headers.joined(separator: "、"))。"
        case .noRecords:
            return "密码文件中没有可导入的登录凭据。"
        }
    }
}

struct ApplePasswordImportPreview: Equatable, Identifiable, Sendable {
    let fileName: String
    let items: [SecretItem]

    var id: String { fileName }
}

enum ApplePasswordImporter {
    private static let requiredHeaders = ["Title", "URL", "Username", "Password"]

    static func decode(data: Data, fileName: String) throws -> ApplePasswordImportPreview {
        guard fileName.lowercased().hasSuffix(".csv") else {
            throw ApplePasswordImportError.unsupportedFile
        }
        let text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let decoded = String(data: data.dropFirst(3), encoding: .utf8) {
            text = decoded
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            throw ApplePasswordImportError.unreadableFile
        }

        let rows = CSVReader.rows(from: text)
        guard let headerIndex = rows.firstIndex(where: { row in
            Set(row.map(normalizedHeader)).isSuperset(of: requiredHeaders.map(normalizedHeader))
        }) else {
            let availableHeaders = rows.first?.map(normalizedHeader) ?? []
            let missing = requiredHeaders.filter { required in
                !availableHeaders.contains(normalizedHeader(required))
            }
            throw ApplePasswordImportError.missingHeaders(missing.isEmpty ? requiredHeaders : missing)
        }

        let headers = rows[headerIndex].map(normalizedHeader)
        let items = rows.dropFirst(headerIndex + 1).compactMap { row -> SecretItem? in
            let values = Dictionary(uniqueKeysWithValues: headers.enumerated().map { index, header in
                (header, row.indices.contains(index) ? row[index] : "")
            })
            let title = trimmed(values[normalizedHeader("Title")])
            let url = trimmed(values[normalizedHeader("URL")])
            let username = trimmed(values[normalizedHeader("Username")])
            let password = values[normalizedHeader("Password")] ?? ""
            let notes = trimmed(values[normalizedHeader("Notes")])
            let otpAuth = trimmed(values[normalizedHeader("OTPAuth")])
            guard !title.isEmpty || !url.isEmpty || !username.isEmpty || !password.isEmpty else {
                return nil
            }

            var fields = [
                SecretField(label: "用户名", value: username, kind: .username),
                SecretField(label: "密码", value: password, kind: .password),
                SecretField(label: "URL", value: url, kind: .url)
            ]
            if !otpAuth.isEmpty {
                fields.append(SecretField(label: "OTPAuth", value: otpAuth, kind: .token))
            }
            return SecretItem(
                title: title.isEmpty ? fallbackTitle(url: url, username: username) : title,
                category: .login,
                purpose: .personal,
                fields: fields,
                note: notes
            )
        }
        guard !items.isEmpty else { throw ApplePasswordImportError.noRecords }
        return ApplePasswordImportPreview(fileName: fileName, items: items)
    }

    private static func normalizedHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{feff}", with: "")
            .lowercased()
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackTitle(url: String, username: String) -> String {
        guard let host = URL(string: url)?.host(), !host.isEmpty else {
            return username.isEmpty ? "未命名登录凭据" : username
        }
        return host
    }
}

private enum CSVReader {
    static func rows(from text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = text.startIndex

        func finishField() {
            row.append(field)
            field = ""
        }

        func finishRow() {
            finishField()
            rows.append(row)
            row = []
        }

        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            if character == "\"" {
                if isQuoted, nextIndex < text.endIndex, text[nextIndex] == "\"" {
                    field.append("\"")
                    index = text.index(after: nextIndex)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                finishField()
            } else if (character == "\n" || character == "\r"), !isQuoted {
                if character == "\r", nextIndex < text.endIndex, text[nextIndex] == "\n" {
                    index = nextIndex
                }
                finishRow()
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty { finishRow() }
        return rows
    }
}
#endif
