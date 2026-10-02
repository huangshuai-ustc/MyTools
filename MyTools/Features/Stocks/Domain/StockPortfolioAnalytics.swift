#if MYTOOLS_FEATURE_STOCKS
import Foundation

enum StockHoldingsExportScope: String, CaseIterable, Identifiable, Sendable {
    case current, all
    var id: Self { self }
    var title: String { self == .current ? "当前持仓" : "全部持仓" }
}

/// Read-only report of a captured portfolio, in each market's native currency.
/// It is not a Vault backup and does not change persisted business data.
enum StockHoldingsCSVExport {
    static func data(
        stocks: [StockHolding], scope: StockHoldingsExportScope,
        extendedHours: [UUID: StockExtendedHoursPerformance], at date: Date
    ) -> Data {
        let timestamp = ISO8601DateFormatter()
        func number(_ value: Decimal?) -> String {
            value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        }
        // Quote every field, preserve line breaks, and neutralize spreadsheet
        // formulas only for untrusted text, never for negative numeric values.
        func text(_ value: String) -> String {
            let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            return first.map { "=+-@".contains($0) } == true ? "'" + value : value
        }
        func row(_ fields: [String]) -> String {
            fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        var lines = [row(["市场", "股票代码", "名称", "状态", "币种", "持仓股数", "持仓成本", "单股成本", "最新价", "报价时段", "持仓市值", "当日盈亏", "持仓盈亏", "持仓盈亏率(%)", "累计买入成本", "已实现交易收益", "净分红", "已实现收益(含分红)", "累计总收益", "常规报价时间", "导出时间", "成本算法"])]
        let ordered = stocks.sorted {
            if $0.market.rawValue != $1.market.rawValue { return $0.market.rawValue < $1.market.rawValue }
            if $0.symbol != $1.symbol { return $0.symbol < $1.symbol }
            return $0.id.uuidString < $1.id.uuidString
        }
        for stock in ordered {
            let performance = stock.performance(asOf: date)
            guard scope == .current ? performance.shares > 0 : performance.hasPurchaseRecord else { continue }
            let quote = StockActiveQuote.make(stock: stock, extendedHours: extendedHours[stock.id], at: date)
            let valuation = StockHoldingValuation(stock: stock, quote: quote, performance: performance)
            let rate = performance.holdingCost > 0
                ? valuation.holdingProfitLoss.map { $0 / performance.holdingCost * 100 } : nil
            lines.append(row([
                stock.market.title, text(stock.symbol), text(stock.displayName),
                performance.shares > 0 ? "持有" : stock.archivedAt != nil ? "已存档" : "已清仓",
                stock.market.currencyCode, number(performance.shares), number(performance.holdingCost),
                number(performance.averageHoldingCost), number(quote.price), quote.sessionTitle,
                number(valuation.marketValue), number(valuation.todayProfitLoss), number(valuation.holdingProfitLoss),
                number(rate), number(performance.totalBuyCost), number(performance.realizedTradeProfitLoss),
                number(performance.netDividendIncome), number(performance.realizedProfitLoss),
                number(valuation.holdingProfitLoss.map { $0 + performance.realizedProfitLoss }),
                stock.lastQuoteAt.map(timestamp.string(from:)) ?? "", timestamp.string(from: date), "移动加权平均"
            ]))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

/// Human-readable workbook export. The first worksheet is a lossless view of
/// user-entered stock transactions and dividends; the second worksheet is a
/// derived portfolio report. Keeping them separate prevents calculated values
/// from being mistaken for ledger facts.
enum StockHoldingsXLSXExport {
    fileprivate enum Cell {
        case text(String)
        case number(Decimal)
    }

    static func data(
        stocks: [StockHolding],
        scope: StockHoldingsExportScope,
        extendedHours: [UUID: StockExtendedHoursPerformance],
        at date: Date
    ) -> Data {
        let included = includedStocks(stocks, scope: scope, at: date)
        return SimpleXLSXWorkbook.data(sheets: [
            ("原始记录", rawRows(stocks: included)),
            ("持仓汇总", summaryRows(stocks: included, extendedHours: extendedHours, at: date))
        ])
    }

    private static func includedStocks(
        _ stocks: [StockHolding],
        scope: StockHoldingsExportScope,
        at date: Date
    ) -> [StockHolding] {
        stocks.filter { stock in
            let performance = stock.performance(asOf: date)
            return scope == .current ? performance.shares > 0 : performance.hasPurchaseRecord
        }.sorted {
            if $0.market.rawValue != $1.market.rawValue { return $0.market.rawValue < $1.market.rawValue }
            if $0.symbol != $1.symbol { return $0.symbol < $1.symbol }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func rawRows(stocks: [StockHolding]) -> [[Cell]] {
        var rows: [[Cell]] = [[
            .text("记录类型"), .text("市场"), .text("股票代码"), .text("名称"),
            .text("记录ID"), .text("业务日期"), .text("成交时间（市场当地）"),
            .text("同日顺序"), .text("交易方向"),
            .text("交易股数"), .text("每股价格"), .text("交易费用"), .text("分红股数"),
            .text("每股股息"), .text("分红总额"), .text("预扣税"), .text("分红费用"), .text("备注")
        ]]
        let formatter = businessDateFormatter()
        for stock in stocks {
            for transaction in stock.transactionsChronologically {
                rows.append([
                    .text("交易"), .text(stock.market.title), .text(stock.symbol), .text(stock.name),
                    .text(transaction.id.uuidString), .text(formatter.string(from: transaction.tradedAt)),
                    .text(transaction.executedAt.map {
                        executionTimeFormatter(for: stock.market).string(from: $0)
                    } ?? ""),
                    transaction.dayOrder.map { .number(Decimal($0)) } ?? .text(""), .text(transaction.type.title),
                    .number(transaction.quantity), .number(transaction.unitPrice), .number(transaction.fees),
                    .text(""), .text(""), .text(""), .text(""), .text(""), .text("")
                ])
            }
            for dividend in stock.dividends.sorted(by: {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
                return $0.id.uuidString < $1.id.uuidString
            }) {
                rows.append([
                    .text("分红"), .text(stock.market.title), .text(stock.symbol), .text(stock.name),
                    .text(dividend.id.uuidString), .text(formatter.string(from: dividend.receivedAt)),
                    .text(""), .text(""), .text(""), .text(""), .text(""), .text(""),
                    .number(dividend.quantity), .number(dividend.dividendPerShare), .number(dividend.grossAmount),
                    .number(dividend.withholdingTax), .number(dividend.fees), .text(dividend.note)
                ])
            }
        }
        return rows
    }

    private static func summaryRows(
        stocks: [StockHolding],
        extendedHours: [UUID: StockExtendedHoursPerformance],
        at date: Date
    ) -> [[Cell]] {
        var rows: [[Cell]] = [[
            .text("市场"), .text("股票代码"), .text("名称"), .text("状态"), .text("币种"),
            .text("持仓股数"), .text("持仓成本"), .text("单股成本"), .text("最新价"), .text("报价时段"),
            .text("持仓市值"), .text("当日盈亏"), .text("持仓盈亏"), .text("持仓盈亏率(%)"),
            .text("累计买入成本"), .text("已实现交易收益"), .text("净分红"),
            .text("已实现收益(含分红)"), .text("累计总收益"), .text("常规报价时间"),
            .text("导出时间"), .text("成本算法")
        ]]
        let timestamp = ISO8601DateFormatter()
        func optionalNumber(_ value: Decimal?) -> Cell { value.map(Cell.number) ?? .text("") }
        for stock in stocks {
            let performance = stock.performance(asOf: date)
            let quote = StockActiveQuote.make(stock: stock, extendedHours: extendedHours[stock.id], at: date)
            let valuation = StockHoldingValuation(stock: stock, quote: quote, performance: performance)
            let rate = performance.holdingCost > 0
                ? valuation.holdingProfitLoss.map { $0 / performance.holdingCost * 100 }
                : nil
            rows.append([
                .text(stock.market.title), .text(stock.symbol), .text(stock.displayName),
                .text(performance.shares > 0 ? "持有" : stock.archivedAt != nil ? "已存档" : "已清仓"),
                .text(stock.market.currencyCode), .number(performance.shares), .number(performance.holdingCost),
                optionalNumber(performance.averageHoldingCost), optionalNumber(quote.price), .text(quote.sessionTitle),
                optionalNumber(valuation.marketValue), optionalNumber(valuation.todayProfitLoss),
                optionalNumber(valuation.holdingProfitLoss), optionalNumber(rate), .number(performance.totalBuyCost),
                .number(performance.realizedTradeProfitLoss), .number(performance.netDividendIncome),
                .number(performance.realizedProfitLoss),
                optionalNumber(valuation.holdingProfitLoss.map { $0 + performance.realizedProfitLoss }),
                .text(stock.lastQuoteAt.map(timestamp.string(from:)) ?? ""), .text(timestamp.string(from: date)),
                .text("移动加权平均")
            ])
        }
        return rows
    }

    private static func businessDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func executionTimeFormatter(for market: StockMarket) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = StockChartSeriesProcessor.marketCalendar(market)
        formatter.timeZone = formatter.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}

/// Minimal dependency-free XLSX writer using inline strings and stored ZIP
/// entries. It intentionally implements only the workbook features required by
/// the read-only stock export.
private enum SimpleXLSXWorkbook {
    typealias Cell = StockHoldingsXLSXExport.Cell

    static func data(sheets: [(name: String, rows: [[Cell]])]) -> Data {
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", utf8(contentTypes(sheetCount: sheets.count))),
            ("_rels/.rels", utf8(packageRelationships)),
            ("xl/workbook.xml", utf8(workbook(sheets: sheets))),
            ("xl/_rels/workbook.xml.rels", utf8(workbookRelationships(sheetCount: sheets.count))),
            ("xl/styles.xml", utf8(styles))
        ]
        for (index, sheet) in sheets.enumerated() {
            entries.append(("xl/worksheets/sheet\(index + 1).xml", utf8(worksheet(rows: sheet.rows))))
        }
        return zip(entries)
    }

    private static func worksheet(rows: [[Cell]]) -> String {
        let maximumColumns = rows.map(\.count).max() ?? 1
        let finalReference = "\(columnName(maximumColumns))\(max(rows.count, 1))"
        let body = rows.enumerated().map { rowIndex, row in
            let cells = row.enumerated().map { columnIndex, cell in
                let reference = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                let style = rowIndex == 0 ? " s=\"1\"" : ""
                switch cell {
                case .text(let value):
                    return "<c r=\"\(reference)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                case .number(let value):
                    return "<c r=\"\(reference)\"\(style)><v>\(NSDecimalNumber(decimal: value).stringValue)</v></c>"
                }
            }.joined()
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:\(finalReference)"/>
          <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
          <sheetFormatPr defaultRowHeight="15"/>
          <sheetData>\(body)</sheetData>
          <autoFilter ref="A1:\(finalReference)"/>
        </worksheet>
        """
    }

    private static func workbook(sheets: [(name: String, rows: [[Cell]])]) -> String {
        let nodes = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(xml(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(nodes)</sheets></workbook>
        """
    }

    private static func contentTypes(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(sheets)</Types>
        """
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheets)<Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
    }

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Aptos"/></font><font><b/><sz val="11"/><name val="Aptos"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """

    private static func columnName(_ index: Int) -> String {
        var value = index
        var result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(65 + value % 26)!) + result
            value /= 26
        }
        return result
    }

    private static func xml(_ value: String) -> String {
        let valid = value.unicodeScalars.filter {
            $0.value == 0x9 || $0.value == 0xA || $0.value == 0xD
                || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value)
                || (0x10000...0x10FFFF).contains($0.value)
        }
        return String(String.UnicodeScalarView(valid))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func utf8(_ value: String) -> Data { Data(value.utf8) }

    private static func zip(_ entries: [(String, Data)]) -> Data {
        var localHeaders = Data()
        var centralHeaders = Data()
        for (name, contents) in entries {
            let nameData = Data(name.utf8)
            let checksum = crc32(contents)
            let offset = UInt32(localHeaders.count)
            var local = Data()
            local += littleEndian(UInt32(0x04034B50)); local += littleEndian(UInt16(20))
            local += littleEndian(UInt16(0x0800)); local += littleEndian(UInt16(0))
            local += littleEndian(UInt16(0)); local += littleEndian(UInt16(0)); local += littleEndian(checksum)
            local += littleEndian(UInt32(contents.count)); local += littleEndian(UInt32(contents.count))
            local += littleEndian(UInt16(nameData.count)); local += littleEndian(UInt16(0)); local += nameData; local += contents
            localHeaders += local

            var central = Data()
            central += littleEndian(UInt32(0x02014B50)); central += littleEndian(UInt16(20)); central += littleEndian(UInt16(20))
            central += littleEndian(UInt16(0x0800)); central += littleEndian(UInt16(0)); central += littleEndian(UInt16(0)); central += littleEndian(UInt16(0))
            central += littleEndian(checksum); central += littleEndian(UInt32(contents.count)); central += littleEndian(UInt32(contents.count))
            central += littleEndian(UInt16(nameData.count)); central += littleEndian(UInt16(0)); central += littleEndian(UInt16(0))
            central += littleEndian(UInt16(0)); central += littleEndian(UInt16(0)); central += littleEndian(UInt32(0)); central += littleEndian(offset); central += nameData
            centralHeaders += central
        }
        var end = Data()
        end += littleEndian(UInt32(0x06054B50)); end += littleEndian(UInt16(0)); end += littleEndian(UInt16(0))
        end += littleEndian(UInt16(entries.count)); end += littleEndian(UInt16(entries.count))
        end += littleEndian(UInt32(centralHeaders.count)); end += littleEndian(UInt32(localHeaders.count)); end += littleEndian(UInt16(0))
        return localHeaders + centralHeaders + end
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            var value = UInt32(byte) ^ (crc & 0xFF)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 }
            crc = value ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func littleEndian(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}

/// A quote tick does not change the transaction ledger. Cache only the replay;
/// valuation remains cheap and uses the current quote and session.
struct StockPerformanceCache {
    private struct Entry {
        let transactions: [StockTransaction]
        let dividends: [StockDividend]
        let calendar: Calendar
        let computedAt: Date
        let validUntil: Date
        let performance: StockHolding.Performance
    }
    private var entries: [UUID: Entry] = [:]
    private(set) var replayCount = 0

    mutating func performance(for stock: StockHolding, at now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> StockHolding.Performance {
        if let entry = entries[stock.id],
           entry.transactions == stock.transactions, entry.dividends == stock.dividends,
           entry.calendar == calendar, now >= entry.computedAt, now < entry.validUntil {
            return entry.performance
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let nextTransaction = stock.transactions.lazy.map(\.tradedAt).filter { $0 > now }.min() ?? nextDay
        let performance = stock.performance(asOf: now, calendar: calendar)
        entries[stock.id] = Entry(transactions: stock.transactions, dividends: stock.dividends,
                                  calendar: calendar, computedAt: now, validUntil: min(nextDay, nextTransaction),
                                  performance: performance)
        replayCount += 1
        return performance
    }

    mutating func retain(_ ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}

/// The quote actually in effect for a holding right now.
///
/// 这是整个股票模块**唯一**的报价判定入口：持仓行、看盘行、市场概况和顶部总览都必须
/// 经过它，任何一处自己去读 `latestPrice`/`previousClose` 就会重新引入「上面按昨收、
/// 下面按盘前」的分裂。
///
/// 只有美股有盘前盘后。价格、涨跌额、涨跌幅永远同源：常规报价三者都取行情源的
/// `latestPrice`/`previousClose`/`changePercent`，扩展时段三者都取
/// `StockExtendedHoursPerformance`（其金额与百分比由 `StockChartPresentation` 的同一
/// 基准派生）。混用两边（用行情源的 `previousClose` 算金额、用图表基准算百分比）正是
/// 「-$1.59（+0.45%）」的来源，所以扩展时段缺任意一项就整组回退到常规报价，绝不拼接。
struct StockActiveQuote {
    /// 这组数字属于哪个时段。行内不再画角标——看盘页顶部的时段条和持仓页总览已经
    /// 说明了当前时段——所以它只用于无障碍朗读。
    let sessionTitle: String
    let price: Decimal?
    let changeAmount: Decimal?
    let percent: Decimal?

    static func make(
        stock: StockHolding,
        extendedHours: StockExtendedHoursPerformance?,
        at now: Date = Date()
    ) -> StockActiveQuote {
        let regular = StockActiveQuote(
            sessionTitle: "当前价格",
            price: stock.latestPrice,
            changeAmount: difference(stock.latestPrice, stock.previousClose),
            percent: stock.changePercent
        )
        guard stock.market == .unitedStates else { return regular }
        switch StockMarketTradingCalendar.session(for: stock.market, at: now) {
        case .preMarket:
            // 价格、涨跌额、涨跌幅必须整套齐备才切到盘前：缺一个就说明这份缓存不属于
            // 当前交易日（`StockChartPresentation.preMarketPerformance` 会按当天校验），
            // 此时整行回退到常规报价，迷你图也跟着画同一段。
            guard let extendedHours,
                  let price = extendedHours.preMarketPrice,
                  let change = extendedHours.preMarketChange,
                  let percent = extendedHours.preMarketPercent else { return regular }
            return StockActiveQuote(
                sessionTitle: "盘前",
                price: price,
                changeAmount: change,
                percent: percent
            )
        case .postMarket:
            guard let extendedHours,
                  let price = extendedHours.postMarketPrice,
                  let change = extendedHours.postMarketChange,
                  let percent = extendedHours.postMarketPercent else { return regular }
            return StockActiveQuote(
                sessionTitle: "盘后",
                price: price,
                changeAmount: change,
                percent: percent
            )
        case .regular, .closed:
            return regular
        }
    }

    private static func difference(_ price: Decimal?, _ reference: Decimal?) -> Decimal? {
        guard let price, let reference else { return nil }
        return price - reference
    }
}

/// 一只股票在当前时段的全部派生金额，全部由同一个 `StockActiveQuote` 算出。
///
/// 持仓行、市场概况和顶部总览都用它，所以「总览 = 各行之和」是**构造上成立**的，而不是
/// 两条链路碰巧一致。`StockHolding` 上同名的 `marketValue`/`todayProfitLoss`/
/// `holdingProfitLoss` 只看常规报价，聚合时不要再直接用它们。
///
/// 语义与 `StockHolding` 的同名属性对齐：清仓后市值确定为 0、当日盈亏为 nil（没有敞口
/// 就没有当日涨跌）；持有中缺价格时全部为 nil，缺涨跌额时只有当日两项为 nil。
struct StockHoldingValuation {
    let marketValue: Decimal?
    /// 上一个基准时刻的持仓市值，即 `todayChangeRate` 的分母。基准跟着报价走：常规时段
    /// 是昨收，盘前是上一个已结算收盘，盘后是当日盘中收盘。
    let previousMarketValue: Decimal?
    let todayProfitLoss: Decimal?
    let holdingProfitLoss: Decimal?

    /// `performance` 传入已算好的交易回放结果可避免重复回放；不传就自己算一份。聚合场景
    /// **务必**传，否则每构造一个估值就要把这只股票的全部交易重排一遍（见
    /// `StockHolding.performance(asOf:)` 的说明）。
    init(
        stock: StockHolding,
        quote: StockActiveQuote,
        performance: StockHolding.Performance? = nil
    ) {
        let performance = performance ?? stock.performance()
        let shares = performance.shares
        guard shares > 0 else {
            marketValue = 0
            previousMarketValue = 0
            todayProfitLoss = nil
            holdingProfitLoss = -performance.holdingCost
            return
        }
        guard let price = quote.price else {
            marketValue = nil
            previousMarketValue = nil
            todayProfitLoss = nil
            holdingProfitLoss = nil
            return
        }
        let value = shares * price
        marketValue = value
        holdingProfitLoss = value - performance.holdingCost
        guard let change = quote.changeAmount else {
            previousMarketValue = nil
            todayProfitLoss = nil
            return
        }
        todayProfitLoss = shares * change
        previousMarketValue = shares * (price - change)
    }

    init(
        stock: StockHolding,
        extendedHours: StockExtendedHoursPerformance?,
        at now: Date = Date(),
        performance: StockHolding.Performance? = nil
    ) {
        self.init(
            stock: stock,
            quote: StockActiveQuote.make(stock: stock, extendedHours: extendedHours, at: now),
            performance: performance
        )
    }
}

struct StockPortfolioSummary {
    let market: StockMarket
    let stockCount: Int
    let openPositionCount: Int
    let holdingCost: Decimal
    let netDividendIncome: Decimal
    let realizedProfitLoss: Decimal
    let knownMarketValue: Decimal
    let todayProfitLoss: Decimal?
    let profitLoss: Decimal?
    let hasMissingQuotes: Bool

    var totalProfitLoss: Decimal? {
        profitLoss.map { $0 + realizedProfitLoss }
    }

    /// Unrealized return for all currently held positions in this market.
    /// Both operands use the market's native currency, so no conversion is
    /// needed until summaries from different markets are combined.
    var holdingProfitRate: Decimal? {
        guard holdingCost != 0, let profitLoss else { return nil }
        return profitLoss / holdingCost
    }

    /// 传入 `extendedHours` 才能让市场概况与持仓行在美股盘前/盘后保持同口径；默认空表
    /// 等价于「只看常规报价」，老调用点与测试无需改动。
    init(
        market: StockMarket,
        stocks: [StockHolding],
        extendedHours: [UUID: StockExtendedHoursPerformance] = [:],
        at now: Date = Date(),
        performances: [UUID: StockHolding.Performance] = [:]
    ) {
        self.market = market
        let marketStocks = stocks.filter { $0.market == market }
        stockCount = marketStocks.count

        // 每只股票只回放一次交易，下面所有小计都从同一份快照里取。原实现对
        // `currentShares`/`holdingCost`/`realizedProfitLoss` 各做一次 `reduce`，再为估值
        // 读两次、为两个 `contains` 各读一次，合计每只股票 7 次完整回放。
        let entries = marketStocks.map { stock -> (
            performance: StockHolding.Performance,
            valuation: StockHoldingValuation
        ) in
            let performance = performances[stock.id] ?? stock.performance(asOf: now)
            return (
                performance: performance,
                // 与持仓行同一个判定入口，所以「市值 = 各行市值之和」是构造上成立的。
                valuation: StockHoldingValuation(
                    stock: stock,
                    extendedHours: extendedHours[stock.id],
                    at: now,
                    performance: performance
                )
            )
        }

        var openPositions = 0
        var cost = Decimal.zero
        var dividends = Decimal.zero
        var realized = Decimal.zero
        var value = Decimal.zero
        var daily = Decimal.zero
        var missingDailyChange = false
        var missingQuotes = false
        for entry in entries {
            let isOpenPosition = entry.performance.shares > 0
            if isOpenPosition { openPositions += 1 }
            cost += entry.performance.holdingCost
            dividends += entry.performance.netDividendIncome
            realized += entry.performance.realizedProfitLoss
            value += entry.valuation.marketValue ?? 0
            daily += entry.valuation.todayProfitLoss ?? 0
            guard isOpenPosition else { continue }
            if entry.valuation.todayProfitLoss == nil { missingDailyChange = true }
            if entry.valuation.marketValue == nil { missingQuotes = true }
        }

        openPositionCount = openPositions
        holdingCost = cost
        netDividendIncome = dividends
        realizedProfitLoss = realized
        knownMarketValue = value
        todayProfitLoss = missingDailyChange ? nil : daily
        hasMissingQuotes = missingQuotes
        profitLoss = missingQuotes ? nil : value - cost
    }
}

struct StockConvertedPortfolioSummary {
    let marketValue: Decimal?
    let todayProfitLoss: Decimal?
    let holdingProfitLoss: Decimal?
    /// 已落袋的部分：卖出实现的盈亏加净分红（`StockHolding.realizedProfitLoss`
    /// 的定义）。它不依赖行情，只要每个市场都有汇率就能算，所以缺行情时仍然可用，
    /// 与 `holdingProfitLoss` 的可用条件不同。
    let realizedProfitLoss: Decimal?
    let totalProfitLoss: Decimal?
    /// Yesterday's closing value of the shares still held, converted with the
    /// same multipliers. This is the denominator `todayChangeRate` needs; it is
    /// nil whenever any held position is missing a quote or an exchange rate.
    let previousMarketValue: Decimal?

    /// Today's move as a rate of yesterday's closing value.
    var todayChangeRate: Decimal? {
        guard let todayProfitLoss,
              let previousMarketValue,
              previousMarketValue > 0 else { return nil }
        return todayProfitLoss / previousMarketValue
    }

    /// `extendedHours` 与持仓行用的是同一份 `StockStore.extendedHoursPerformance`，所以
    /// 顶部大字在美股盘前/盘后与下面每一行同口径。代价是盘前流动性稀薄时大字会跟着跳，
    /// 这是刻意接受的：宁可一起动，也不要上下两个口径。
    init(
        stocks: [StockHolding],
        multipliers: [StockMarket: Decimal],
        extendedHours: [UUID: StockExtendedHoursPerformance] = [:],
        at now: Date = Date(),
        performances: [UUID: StockHolding.Performance] = [:]
    ) {
        var value = Decimal.zero
        var daily = Decimal.zero
        var previousValue = Decimal.zero
        var holding = Decimal.zero
        var realized = Decimal.zero
        var canCalculateValue = true
        var canCalculateDaily = true
        /// 已实现收益只需要汇率，不需要行情。
        var canConvertCurrencies = true

        for stock in stocks {
            // 每只股票一次回放：原实现为 `hasPurchaseRecord`、`realizedProfitLoss`、
            // `currentShares` 与估值各读一遍，合计 5 次。
            let performance = performances[stock.id] ?? stock.performance(asOf: now)
            guard performance.hasPurchaseRecord else { continue }
            guard let multiplier = multipliers[stock.market] else {
                canConvertCurrencies = false
                canCalculateValue = false
                canCalculateDaily = false
                continue
            }
            realized += performance.realizedProfitLoss * multiplier
            if performance.shares > 0 {
                let valuation = StockHoldingValuation(
                    stock: stock,
                    extendedHours: extendedHours[stock.id],
                    at: now,
                    performance: performance
                )
                if let marketValue = valuation.marketValue,
                   let holdingProfitLoss = valuation.holdingProfitLoss {
                    value += marketValue * multiplier
                    holding += holdingProfitLoss * multiplier
                } else {
                    canCalculateValue = false
                }
                // 分母跟着报价走：`previousMarketValue` 是本行百分比的基准市值，不再
                // 单独去读 `previousClose`（盘前那是前一天的收盘，与大字口径打架）。
                if let todayProfitLoss = valuation.todayProfitLoss,
                   let previousMarketValue = valuation.previousMarketValue {
                    daily += todayProfitLoss * multiplier
                    previousValue += previousMarketValue * multiplier
                } else {
                    canCalculateDaily = false
                }
            }
        }

        marketValue = canCalculateValue ? value : nil
        todayProfitLoss = canCalculateDaily ? daily : nil
        previousMarketValue = canCalculateDaily ? previousValue : nil
        holdingProfitLoss = canCalculateValue ? holding : nil
        realizedProfitLoss = canConvertCurrencies ? realized : nil
        totalProfitLoss = canCalculateValue ? holding + realized : nil
    }
}

struct StockAllocationSnapshot {
    private let holdingShares: [UUID: Decimal]
    private let marketShares: [StockMarket: Decimal]
    let isComplete: Bool

    init(
        stocks: [StockHolding],
        marketValueMultipliers: [StockMarket: Decimal],
        extendedHours: [UUID: StockExtendedHoursPerformance] = [:],
        at now: Date = Date(),
        performances: [UUID: StockHolding.Performance] = [:]
    ) {
        var valuesByHolding: [UUID: Decimal] = [:]
        var valuesByMarket = Dictionary(
            uniqueKeysWithValues: StockMarket.allCases.map { ($0, Decimal.zero) }
        )
        var total = Decimal.zero
        var complete = true

        for stock in stocks {
            // 占比的分子分母都用与持仓行相同的报价，否则盘前的占比会和行内市值不匹配。
            let valuation = StockHoldingValuation(
                stock: stock,
                extendedHours: extendedHours[stock.id],
                at: now,
                performance: performances[stock.id] ?? stock.performance(asOf: now)
            )
            guard let marketValue = valuation.marketValue else {
                complete = false
                break
            }
            let convertedValue: Decimal
            if marketValue == 0 {
                convertedValue = 0
            } else if let multiplier = marketValueMultipliers[stock.market] {
                convertedValue = marketValue * multiplier
            } else {
                complete = false
                break
            }
            valuesByHolding[stock.id] = convertedValue
            valuesByMarket[stock.market, default: 0] += convertedValue
            total += convertedValue
        }

        guard complete else {
            holdingShares = [:]
            marketShares = [:]
            isComplete = false
            return
        }

        if total > 0 {
            holdingShares = valuesByHolding.mapValues { $0 / total }
            marketShares = valuesByMarket.mapValues { $0 / total }
        } else {
            holdingShares = valuesByHolding.mapValues { _ in 0 }
            marketShares = valuesByMarket.mapValues { _ in 0 }
        }
        isComplete = true
    }

    func holdingShare(for stockID: UUID) -> Decimal? {
        guard isComplete else { return nil }
        return holdingShares[stockID] ?? 0
    }

    func marketShare(for market: StockMarket) -> Decimal? {
        guard isComplete else { return nil }
        return marketShares[market] ?? 0
    }
}

/// Cost-basis allocation for the currently held positions. Unlike market-value
/// allocation, this remains available when a quote is missing; only the
/// exchange-rate inputs needed to compare different currencies are required.
struct StockCostAllocationSnapshot {
    private let holdingShares: [UUID: Decimal]
    let isComplete: Bool

    init(stocks: [StockHolding], costMultipliers: [StockMarket: Decimal], performances: [UUID: StockHolding.Performance] = [:]) {
        var valuesByHolding: [UUID: Decimal] = [:]
        var total = Decimal.zero

        for stock in stocks {
            // 一次回放取代 `currentShares` + `holdingCost` × 2 三次。
            let performance = performances[stock.id] ?? stock.performance()
            guard performance.shares > 0, performance.holdingCost > 0 else { continue }
            guard let multiplier = costMultipliers[stock.market] else {
                holdingShares = [:]
                isComplete = false
                return
            }
            let convertedCost = performance.holdingCost * multiplier
            valuesByHolding[stock.id] = convertedCost
            total += convertedCost
        }

        if total > 0 {
            holdingShares = valuesByHolding.mapValues { $0 / total }
        } else {
            holdingShares = valuesByHolding.mapValues { _ in 0 }
        }
        isComplete = true
    }

    func holdingShare(for stockID: UUID) -> Decimal? {
        guard isComplete else { return nil }
        return holdingShares[stockID]
    }
}

#endif
