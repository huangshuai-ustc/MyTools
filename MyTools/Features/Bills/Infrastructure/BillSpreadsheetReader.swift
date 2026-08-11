#if MYTOOLS_FEATURE_BILLS
import Compression
import CoreFoundation
import Foundation

enum BillSpreadsheetReaderError: LocalizedError {
    case invalidWorkbook
    case unsupportedCompression
    case oversizedEntry
    case invalidWorksheet
    case undecodableText

    var errorDescription: String? {
        switch self {
        case .invalidWorkbook:
            return "Excel 账单文件结构无效或已损坏。"
        case .unsupportedCompression:
            return "Excel 账单使用了暂不支持的压缩方式。"
        case .oversizedEntry:
            return "Excel 账单中的单个工作表过大，已停止读取。"
        case .invalidWorksheet:
            return "Excel 账单中没有可读取的工作表。"
        case .undecodableText:
            return "无法识别账单文本编码。"
        }
    }
}

enum BillDelimitedTextReader {
    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let value = String(data: data.dropFirst(3), encoding: .utf8) {
            return value
        }
        if let value = String(data: data, encoding: .utf8) {
            return value
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        guard let value = String(data: data, encoding: gb18030) else {
            throw BillSpreadsheetReaderError.undecodableText
        }
        return value
    }

    static func rows(from text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = text.startIndex

        func finishField() {
            row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
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
            } else if character == delimiter, !isQuoted {
                finishField()
            } else if character.isNewline, !isQuoted {
                finishRow()
            } else if character.isNewline {
                field.append("\n")
            } else {
                field.append(character)
            }
            index = nextIndex
        }

        if !field.isEmpty || !row.isEmpty {
            finishRow()
        }
        return rows
    }
}

enum BillXLSXReader {
    static func worksheetRows(from data: Data) throws -> [[String]] {
        let archive = try XLSXArchive(data: data)
        let sharedStrings: [String]
        if let sharedStringData = try archive.data(for: "xl/sharedStrings.xml") {
            sharedStrings = try XLSXSharedStringsParser.parse(sharedStringData)
        } else {
            sharedStrings = []
        }

        let worksheetNames = archive.entryNames
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        for worksheetName in worksheetNames {
            guard let worksheetData = try archive.data(for: worksheetName) else { continue }
            let rows = try XLSXWorksheetParser.parse(worksheetData, sharedStrings: sharedStrings)
            if !rows.isEmpty { return rows }
        }
        throw BillSpreadsheetReaderError.invalidWorksheet
    }
}

private struct XLSXArchive {
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let localFileSignature: UInt32 = 0x04034B50
    private static let maximumEntrySize = 64 * 1_024 * 1_024

    struct Entry {
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    let entries: [String: Entry]
    var entryNames: [String] { Array(entries.keys) }

    init(data: Data) throws {
        guard data.count >= 22 else { throw BillSpreadsheetReaderError.invalidWorkbook }
        self.data = data
        let searchStart = Swift.max(0, data.count - 65_557)
        guard let directoryEnd = stride(from: data.count - 22, through: searchStart, by: -1)
            .first(where: { data.littleEndianUInt32(at: $0) == Self.endOfCentralDirectorySignature }),
              let entryCount = data.littleEndianUInt16(at: directoryEnd + 10),
              let directoryOffset = data.littleEndianUInt32(at: directoryEnd + 16) else {
            throw BillSpreadsheetReaderError.invalidWorkbook
        }

        var parsed: [String: Entry] = [:]
        var offset = Int(directoryOffset)
        for _ in 0..<Int(entryCount) {
            guard data.littleEndianUInt32(at: offset) == Self.centralDirectorySignature,
                  let method = data.littleEndianUInt16(at: offset + 10),
                  let compressedSize = data.littleEndianUInt32(at: offset + 20),
                  let uncompressedSize = data.littleEndianUInt32(at: offset + 24),
                  let nameLength = data.littleEndianUInt16(at: offset + 28),
                  let extraLength = data.littleEndianUInt16(at: offset + 30),
                  let commentLength = data.littleEndianUInt16(at: offset + 32),
                  let localHeaderOffset = data.littleEndianUInt32(at: offset + 42) else {
                throw BillSpreadsheetReaderError.invalidWorkbook
            }
            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw BillSpreadsheetReaderError.invalidWorkbook
            }
            parsed[name] = Entry(
                compressionMethod: method,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset)
            )
            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }
        entries = parsed
    }

    func data(for name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard entry.uncompressedSize <= Self.maximumEntrySize,
              data.littleEndianUInt32(at: entry.localHeaderOffset) == Self.localFileSignature,
              let nameLength = data.littleEndianUInt16(at: entry.localHeaderOffset + 26),
              let extraLength = data.littleEndianUInt16(at: entry.localHeaderOffset + 28) else {
            throw entry.uncompressedSize > Self.maximumEntrySize
                ? BillSpreadsheetReaderError.oversizedEntry
                : BillSpreadsheetReaderError.invalidWorkbook
        }
        let payloadStart = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadStart >= 0, payloadEnd <= data.count else {
            throw BillSpreadsheetReaderError.invalidWorkbook
        }
        let compressedData = data[payloadStart..<payloadEnd]
        switch entry.compressionMethod {
        case 0:
            return Data(compressedData)
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var result = Data(count: entry.uncompressedSize)
            let decodedSize = result.withUnsafeMutableBytes { destination in
                compressedData.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        entry.uncompressedSize,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        entry.compressedSize,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decodedSize == entry.uncompressedSize else {
                throw BillSpreadsheetReaderError.invalidWorkbook
            }
            return result
        default:
            throw BillSpreadsheetReaderError.unsupportedCompression
        }
    }
}

private final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private var values: [String] = []
    private var currentValue = ""
    private var textBuffer = ""
    private var isInsideItem = false
    private var isInsideText = false

    static func parse(_ data: Data) throws -> [String] {
        let delegate = XLSXSharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? BillSpreadsheetReaderError.invalidWorkbook
        }
        return delegate.values
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            isInsideItem = true
            currentValue = ""
        } else if elementName == "t", isInsideItem {
            isInsideText = true
            textBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideText { textBuffer.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t", isInsideText {
            currentValue.append(textBuffer)
            isInsideText = false
        } else if elementName == "si", isInsideItem {
            values.append(currentValue)
            isInsideItem = false
        }
    }
}

private final class XLSXWorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentRowNumber: Int?
    private var currentCells: [Int: String] = [:]
    private var currentColumn: Int?
    private var currentType = ""
    private var currentRawValue = ""
    private var currentInlineValue = ""
    private var textBuffer = ""
    private var activeElement: String?

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func parse(_ data: Data, sharedStrings: [String]) throws -> [[String]] {
        let delegate = XLSXWorksheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? BillSpreadsheetReaderError.invalidWorksheet
        }
        return delegate.rows
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            currentRowNumber = attributeDict["r"].flatMap(Int.init)
            currentCells = [:]
        case "c":
            currentColumn = attributeDict["r"].flatMap(Self.columnIndex)
            currentType = attributeDict["t"] ?? ""
            currentRawValue = ""
            currentInlineValue = ""
        case "v", "t":
            guard currentColumn != nil else { return }
            activeElement = elementName
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeElement != nil { textBuffer.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v" where activeElement == "v":
            currentRawValue.append(textBuffer)
            activeElement = nil
        case "t" where activeElement == "t":
            currentInlineValue.append(textBuffer)
            activeElement = nil
        case "c":
            guard let column = currentColumn else { return }
            if currentType == "s", let index = Int(currentRawValue), sharedStrings.indices.contains(index) {
                currentCells[column] = sharedStrings[index]
            } else if currentType == "inlineStr" {
                currentCells[column] = currentInlineValue
            } else {
                currentCells[column] = currentRawValue
            }
            currentColumn = nil
        case "row":
            let rowNumber = currentRowNumber ?? (rows.count + 1)
            while rows.count < rowNumber - 1 { rows.append([]) }
            let maximumColumn = currentCells.keys.max() ?? -1
            var row = Array(repeating: "", count: maximumColumn + 1)
            for (column, value) in currentCells { row[column] = value }
            rows.append(row)
            currentRowNumber = nil
        default:
            break
        }
    }

    private static func columnIndex(_ reference: String) -> Int? {
        var value = 0
        var foundLetter = false
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            foundLetter = true
            value = value * 26 + Int(scalar.value - 64)
        }
        return foundLetter ? value - 1 : nil
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

#endif
