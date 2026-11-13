import Foundation
import Testing
@testable import MarkdownBrowser

/// 心得閱讀位置的紀錄（docs/SPEC.md 5.6）：上限淘汰與改名搬 key。
/// 上限用 3 筆代替 500 筆，時間由測試給，誰新誰舊才不必等真實時間。
@Suite struct NotePositionStoreTests {

    private func pos(_ id: String) -> [String: Any] { ["id": id, "part": 0.5, "whole": 0.2] }

    @Test func 未滿上限時新增不丟舊的() {
        var store = NotePositionStore(entries: [:], limit: 3)
        store.set(pos("a"), for: "/書/第1章.md", at: 100)
        store.set(pos("b"), for: "/書/第2章.md", at: 200)

        #expect(store.position(for: "/書/第1章.md")?["id"] as? String == "a")
        #expect(store.position(for: "/書/第2章.md")?["id"] as? String == "b")
    }

    /// 存的順序跟時間不一致：淘汰看的是存檔時間，不是插入順序
    @Test func 超過上限時丟最舊的剛存的留著() {
        var store = NotePositionStore(entries: [:], limit: 3)
        store.set(pos("a"), for: "/書/第1章.md", at: 300)
        store.set(pos("b"), for: "/書/第2章.md", at: 100)
        store.set(pos("c"), for: "/書/第3章.md", at: 200)
        store.set(pos("d"), for: "/書/第4章.md", at: 400)

        #expect(store.entries.count == 3)
        #expect(store.position(for: "/書/第2章.md") == nil)
        #expect(store.position(for: "/書/第1章.md") != nil)
        #expect(store.position(for: "/書/第3章.md") != nil)
        #expect(store.position(for: "/書/第4章.md")?["id"] as? String == "d")
    }

    @Test func 已滿時更新同一份不會擠掉別人() {
        var store = NotePositionStore(entries: [:], limit: 3)
        store.set(pos("a"), for: "/書/第1章.md", at: 100)
        store.set(pos("b"), for: "/書/第2章.md", at: 200)
        store.set(pos("c"), for: "/書/第3章.md", at: 300)
        store.set(pos("a2"), for: "/書/第1章.md", at: 400)

        #expect(store.entries.count == 3)
        #expect(store.position(for: "/書/第1章.md")?["id"] as? String == "a2")
        #expect(store.position(for: "/書/第2章.md") != nil)
    }

    @Test func 改名時位置搬到新路徑() {
        var store = NotePositionStore(entries: [:], limit: 3)
        store.set(pos("a"), for: "/書/第1章.md", at: 100)
        store.move(from: "/書/第1章.md", to: "/書/第1章_改名.md")

        #expect(store.position(for: "/書/第1章.md") == nil)
        #expect(store.position(for: "/書/第1章_改名.md")?["id"] as? String == "a")
    }

    /// 舊檔沒讀過、新檔名讀過（改名成以前用過的名字）：新檔名的紀錄不能被清掉
    @Test func 舊路徑沒紀錄時改名不動任何紀錄() {
        var store = NotePositionStore(entries: [:], limit: 3)
        store.set(pos("b"), for: "/書/第2章.md", at: 100)
        store.move(from: "/書/草稿.md", to: "/書/第2章.md")

        #expect(store.entries.count == 1)
        #expect(store.position(for: "/書/第2章.md")?["id"] as? String == "b")
    }

    /// 存檔時間是淘汰用的，不送給網頁端
    @Test func 讀出來的位置不含存檔時間() {
        var store = NotePositionStore(entries: [:], limit: 3)
        store.set(pos("a"), for: "/書/第1章.md", at: 100)

        let keys = Set(store.position(for: "/書/第1章.md")?.keys ?? [:].keys)
        #expect(keys == ["id", "part", "whole"])
    }
}
