import Foundation
import Synchronization

/// Shared dictionary ordering for user-facing names. Han characters are
/// transliterated to unaccented Pinyin before comparison so Latin and Chinese
/// names participate in one alphabet instead of being split into script groups.
///
/// 拼音转写走 ICU，单次就要几十微秒；排序比较是 n log n 次、列表又是 SwiftUI 计算属性，
/// 一次渲染会排好几遍。165 条保密资料不缓存时一次排序约 80ms，进入页面主线程卡了 0.6s。
/// 所以每个字符串的排序键只算一次，纯 ASCII（股票代码、英文名）直接跳过转写。
enum AppAlphabeticalSort {
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")
    private static let foldingOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    /// 超过上限整表清空即可：列表里的名字数量远小于它，清空后下一次排序重新填满。
    private static let cacheLimit = 4_096
    private static let cache = Mutex<[String: SortKey]>([:])

    private struct SortKey: Sendable {
        /// 拼音、去空白后的主键。
        let primary: String
        /// 主键相同时的次序：保留原文空白与字形，只做大小写/重音/全半角折叠。
        let folded: String
    }

    static func comparison(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsKey = key(for: lhs)
        let rhsKey = key(for: rhs)
        let keyComparison = lhsKey.primary.compare(
            rhsKey.primary,
            options: [.numeric],
            range: nil,
            locale: comparisonLocale
        )
        guard keyComparison == .orderedSame else { return keyComparison }

        return lhsKey.folded.compare(
            rhsKey.folded,
            options: [.numeric],
            range: nil,
            locale: comparisonLocale
        )
    }

    /// ICU 转写器第一次使用要加载约 50ms 的数据，启动时放到后台先跑一次，
    /// 免得落在第一次进列表页的主线程上。
    static func prewarm() {
        Task.detached(priority: .utility) {
            _ = "拼音".applyingTransform(.toLatin, reverse: false)
        }
    }

    static func isOrderedBefore(
        _ lhs: String,
        _ rhs: String,
        lhsTieBreaker: String = "",
        rhsTieBreaker: String = ""
    ) -> Bool {
        let result = comparison(lhs, rhs)
        if result != .orderedSame { return result == .orderedAscending }
        return lhsTieBreaker < rhsTieBreaker
    }

    private static func key(for value: String) -> SortKey {
        if let cached = cache.withLock({ $0[value] }) { return cached }
        let key = makeKey(for: value)
        cache.withLock { entries in
            if entries.count >= cacheLimit { entries.removeAll(keepingCapacity: true) }
            entries[value] = key
        }
        return key
    }

    private static func makeKey(for value: String) -> SortKey {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let latin = trimmed.allSatisfy(\.isASCII)
            ? trimmed
            : trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
        let primary = latin
            .folding(options: foldingOptions, locale: comparisonLocale)
            .lowercased(with: comparisonLocale)
            .filter { !$0.isWhitespace }
        return SortKey(
            primary: primary,
            folded: value.folding(options: foldingOptions, locale: comparisonLocale)
        )
    }
}
