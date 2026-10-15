import Testing
@testable import StenoKit

@Suite("Word counts for display")
struct WordCountTests {
    @Test("English counts as a whitespace split does", arguments: [
        ("Send the draft to Dana by Friday, and don't forget the 3.5 GB file.", 14),
        ("well-known e.g. U.S.A. 10:30 50% #tag @dana 🎉 👩🏽‍💻", 9),
        ("Thanks — see you at 7", 6),
        ("  Hi Dana,\n\n\tThanks for the notes.  ", 6),
        ("Yes.", 1),
        ("", 0),
        ("   \n ", 0),
    ])
    func english(text: String, words: Int) {
        #expect(WordCount.count(text) == words)
        #expect(WordCount.count(text) == text.split(whereSeparator: \.isWhitespace).count)
    }

    @Test("Chinese and Japanese split into their words", arguments: [
        // 我们 明天 下午 三点 开会 讨论 新 的 设计 方案
        ("我们明天下午三点开会讨论新的设计方案。", 10),
        // 今日 は 東京 で 会議 が あり ます
        ("今日は東京で会議があります。", 8),
        // 오늘 회의는 오후 세 시에 시작합니다: Korean already puts spaces between its words.
        ("오늘 회의는 오후 세 시에 시작합니다.", 6),
    ])
    func cjk(text: String, words: Int) {
        #expect(WordCount.count(text) == words)
    }

    @Test("Mixed text counts each language its own way", arguments: [
        // 我 用 Steno 写 了 三 封 邮件
        ("我用 Steno 写了三封邮件。", 8),
        // Meet me at 星巴克 tomorrow — 好 吗
        ("Meet me at 星巴克 tomorrow — 好吗?", 8),
        // 新しい iPhone は 本当 に 速い
        ("新しい iPhone は本当に速い", 6),
    ])
    func mixed(text: String, words: Int) {
        #expect(WordCount.count(text) == words)
    }

    @Test("A piece of only marks still counts as one word")
    func marksOnly() {
        #expect(WordCount.count("「」") == 1)
        #expect(WordCount.count("。") == 1)
    }
}
