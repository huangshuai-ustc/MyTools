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
}
