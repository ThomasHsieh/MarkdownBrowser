import Foundation
import Testing
@testable import MarkdownBrowser

/// 書的章 ↔ 心得的對應（docs/SPEC.md 13.6）。只驗「第幾個目錄項目對到哪個檔、哪個標題」，
/// 不驗正規化的中間結果。書名、章名、心得全部是編的。
@MainActor
@Suite struct ChapterMapTests {

    /// 每個測試一個資料夾，放在家目錄底下（CLAUDE.md：/tmp 與 /private/tmp 路徑比對不起來）
    let folder: URL

    init() throws {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkdownBrowser-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // swift-testing 的 struct 沒有 deinit，各測試結束時自己收
    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    private func note(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func toc(_ entries: [(String, Int)]) -> [EpubBook.TocEntry] {
        entries.enumerated().map { i, e in
            EpubBook.TocEntry(label: e.0, path: "Text/s\(i).xhtml", fragment: nil, level: e.1)
        }
    }

    private func flat(_ labels: String...) -> [EpubBook.TocEntry] { toc(labels.map { ($0, 1) }) }

    /// 對到檔頭（整份心得、不指定標題）
    private func whole(_ file: URL) -> ChapterMap.Target { ChapterMap.Target(file: file, heading: nil) }

    // MARK: - 數字開頭的目錄章名

    @Test func 全形數字開頭的章名對到第N章心得的檔頭() throws {
        defer { cleanUp() }
        let ch1 = try note("書_心得_第1章.md", """
            # 《樣本書》讀書心得——第1章

            > 第 1 章　沒有誰是傻子
            > 題辭：一句話。

            ## 一、自己下的小標
            """)
        let ch2 = try note("書_心得_第2章.md", """
            # 《樣本書》讀書心得——第2章

            > 第 2 章　好運與壞運
            """)
        let map = ChapterMap.build(toc: flat("封面", "１　沒有誰是傻子", "２　好運與壞運"), notes: [ch1, ch2])
        #expect(map.targets == [nil, whole(ch1), whole(ch2)])
    }

    @Test func 半形兩位數章號在章名對不上時退回章號() throws {
        defer { cleanUp() }
        // 兩個字的章名（「存錢」）只認 h1 結尾，這裡在引言裡，靠的是開頭的「10」
        let ch10 = try note("書_心得_第10章.md", """
            # 《樣本書》讀書心得——第10章

            > 第 10 章　存錢
            """)
        let map = ChapterMap.build(toc: flat("９　別的章", "10　存錢"), notes: [ch10])
        // 只靠章號時對到單檔心得的 h1（捲到 h1 就是檔案開頭），所以只驗對到哪個檔
        #expect(map.targets[0] == nil)
        #expect(map.targets[1]?.file == ch10)
    }

    @Test func 章名換了譯法也靠開頭的數字對到同一章() throws {
        defer { cleanUp() }
        let ch3 = try note("書_心得_第3章.md", """
            # 《樣本書》讀書心得——第3章

            > 第 3 章　知足常樂
            """)
        let map = ChapterMap.build(toc: flat("３　永遠不夠"), notes: [ch3])
        #expect(map.targets[0]?.file == ch3)
    }

    @Test func 心得標題以數字開頭不算章號() throws {
        defer { cleanUp() }
        // 單檔心得：「3 個原則」不是第 3 章
        let single = try note("書_心得.md", """
            # 《樣本書》讀書心得

            ## 3 個原則
            """)
        let map = ChapterMap.build(toc: flat("第 3 章　完全不同的章名"), notes: [single])
        #expect(map.targets == [nil])
    }

    @Test func 小節編號不被當成章號拿掉() throws {
        defer { cleanUp() }
        // 「2.1 」不是「數字＋空白」。要是被拿掉，會先對到前面那個只寫「好運氣」的標題
        let single = try note("書_心得.md", """
            # 《樣本書》讀書心得

            ## 好運氣

            ## 2.1 好運氣
            """)
        let map = ChapterMap.build(toc: flat("2.1 好運氣"), notes: [single])
        #expect(map.targets == [ChapterMap.Target(file: single, heading: "2.1 好運氣")])
    }

    // MARK: - 重疊比例

    @Test func 推薦序多一個序號也對到心得的小節() throws {
        defer { cleanUp() }
        // 檔頭已經對到前言：重疊比例那一步不管檔頭有沒有對到都比
        let front = try note("書_心得_推薦序與前言.md", """
            # 《樣本書》讀書心得——推薦序與前言

            > 推薦序（王小明、李大華）、前言〈一場最精采的表演〉

            ## 推薦序一：讀懂金錢比賺多少更重要（王小明）

            ## 推薦序二：掃掉看不見的投資錯誤（李大華）

            ## 前言之一：停車場看到的事
            """)
        let map = ChapterMap.build(
            toc: flat("推薦序　讀懂金錢比賺多少更重要／王小明",
                      "推薦序　掃掉看不見的投資錯誤／李大華",
                      "前言　一場最精采的表演"),
            notes: [front])
        #expect(map.targets == [
            ChapterMap.Target(file: front, heading: "推薦序一：讀懂金錢比賺多少更重要（王小明）"),
            ChapterMap.Target(file: front, heading: "推薦序二：掃掉看不見的投資錯誤（李大華）"),
            whole(front),
        ])
    }

    @Test func 重疊剛好八成算對到_未滿八成不算() throws {
        defer { cleanUp() }
        // 檔頭對到「前言」，第 2 步不看它的標題，只剩重疊比例這一步能對
        let notes = try note("書_心得_雜項.md", """
            # 《樣本書》讀書心得——前言

            ## 天地玄黃宇宙洪荒（某）

            ## 甲乙丙丁戊己庚辛壬（某）
            """)
        let map = ChapterMap.build(
            toc: flat("前言",
                      "天地玄黃宇宙洪荒日月",          // 10 字，共同 8 字 = 80%
                      "甲乙丙丁戊己庚辛壬癸子丑"),      // 12 字，共同 9 字 = 75%
            notes: [notes])
        #expect(map.targets == [
            whole(notes),
            ChapterMap.Target(file: notes, heading: "天地玄黃宇宙洪荒（某）"),
            nil,
        ])
    }

    @Test func 章名不到八個字不看重疊比例() throws {
        defer { cleanUp() }
        let notes = try note("書_心得_雜項.md", """
            # 《樣本書》讀書心得——前言

            ## 序一：短短的標題
            """)
        let map = ChapterMap.build(toc: flat("前言", "序　短短的標題"), notes: [notes])
        #expect(map.targets == [whole(notes), nil])
    }

    // MARK: - 既有規則（回歸）

    @Test func 同一個章名出現在好幾份的開頭_取章名佔那一行最多的那份() throws {
        defer { cleanUp() }
        let summary = try note("書_心得_全書總結.md", """
            # 《樣本書》讀書心得——全書總結

            > 全書三章加作者的話與前言，逐章心得見同目錄各檔
            """)
        // h1 不以章名結尾，比的只是引言那一行章名佔多少
        let preface = try note("書_心得_開場.md", """
            # 《樣本書》讀書心得——開場

            > 作者的話
            """)
        let map = ChapterMap.build(toc: flat("作者的話"), notes: [summary, preface])
        #expect(map.targets == [whole(preface)])
    }

    @Test func 兩個字的章名只認h1結尾() throws {
        defer { cleanUp() }
        let other = try note("書_心得_第1章.md", """
            # 《樣本書》讀書心得——第1章

            > 前言
            """)
        let preface = try note("書_心得_前言.md", """
            # 《樣本書》讀書心得——前言
            """)
        let map = ChapterMap.build(toc: flat("前言"), notes: [other, preface])
        #expect(map.targets == [whole(preface)])
    }

    @Test func 上層與下層對到同一份時留下層() throws {
        defer { cleanUp() }
        let ch1 = try note("書_心得_第1章.md", """
            # 《樣本書》讀書心得——第1章

            > 第一部　追尋使命
            > 第一章　找到方向
            """)
        let map = ChapterMap.build(
            toc: toc([("第一部　追尋使命", 1), ("第一章　找到方向", 2), ("第二章　開始行動", 2)]),
            notes: [ch1])
        #expect(map.targets == [nil, whole(ch1), nil])
    }

    @Test func 上層已經對到的子項目不再比標題() throws {
        defer { cleanUp() }
        // 子項目的同名標題寫在第 4 章底下，不能被它搶走
        let single = try note("書_心得.md", """
            # 《樣本書》讀書心得

            ### 第 3 章 提領策略

            ### 第 4 章 稅務

            #### 投資組合存續年數
            """)
        let map = ChapterMap.build(
            toc: toc([("第 3 章　提領策略", 1), ("3.1 投資組合存續年數", 2), ("第 4 章　稅務", 1)]),
            notes: [single])
        #expect(map.targets == [
            ChapterMap.Target(file: single, heading: "第 3 章 提領策略"),
            nil,
            ChapterMap.Target(file: single, heading: "第 4 章 稅務"),
        ])
    }
}
