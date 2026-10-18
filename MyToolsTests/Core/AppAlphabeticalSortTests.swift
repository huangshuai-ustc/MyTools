import Testing
@testable import MyTools

struct AppAlphabeticalSortTests {
    @Test func latinAndChineseNamesShareOnePinyinAlphabet() {
        let names = ["浙江银行", "A Bank", "招商银行", "北京银行", "阿里银行"]

        let sorted = names.sorted {
            AppAlphabeticalSort.isOrderedBefore($0, $1)
        }

        #expect(sorted == ["A Bank", "阿里银行", "北京银行", "招商银行", "浙江银行"])
    }

    @Test func pinyinToneAndCaseDoNotSplitEquivalentInitials() {
        let names = ["中信", "apple", "Apple 2", "Apple 10", "重庆"]

        let sorted = names.sorted {
            AppAlphabeticalSort.isOrderedBefore($0, $1)
        }

        #expect(sorted == ["apple", "Apple 2", "Apple 10", "重庆", "中信"])
    }

    /// 排序键带缓存、ASCII 跳过转写：重复排序结果必须稳定，股票代码按数字序排列。
    @Test func cachedKeysKeepOrderingStableAcrossRepeatedSorts() {
        let names = ["600519", "AAPL", "00700", "招商银行", "Ａｐｐｌｅ", "aapl", "60051"]
        let expected = ["00700", "60051", "600519", "AAPL", "aapl", "Ａｐｐｌｅ", "招商银行"]

        for _ in 0..<3 {
            let sorted = names.shuffled().sorted {
                AppAlphabeticalSort.isOrderedBefore($0, $1, lhsTieBreaker: $0, rhsTieBreaker: $1)
            }
            #expect(sorted == expected)
        }
    }
}
