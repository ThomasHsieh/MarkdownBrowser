import Foundation

/// 心得的閱讀位置紀錄（docs/SPEC.md 5.6）：心得路徑 → `{id, part, whole, t}`。
/// 不碰 UserDefaults，`AppSettings` 負責存回去；時間由呼叫端給，測試才決定得了誰新誰舊。
///
/// 上限 500 筆：心得一本書就二、三十份，UserDefaults 整份在啟動時讀進記憶體，只增不減會越來越肥。
struct NotePositionStore {
    private(set) var entries: [String: [String: Any]]
    let limit: Int

    init(entries: [String: [String: Any]], limit: Int = 500) {
        self.entries = entries
        self.limit = limit
    }

    func position(for path: String) -> [String: Any]? {
        entries[path]?.filter { $0.key != "t" }   // 存檔時間是淘汰用的，網頁端用不到
    }

    mutating func set(_ position: [String: Any], for path: String, at time: Double) {
        var entry = position
        entry["t"] = time
        entries[path] = entry
        guard entries.count > limit else { return }
        // 呼叫端給的是現在的時間，剛存的那筆一定最新、不會被丟
        let oldest = entries.sorted { ($0.value["t"] as? Double ?? 0) < ($1.value["t"] as? Double ?? 0) }
        for (key, _) in oldest.prefix(entries.count - limit) { entries[key] = nil }
    }

    /// 心得在 App 開著時被改名：位置跟著搬。
    mutating func move(from old: String, to new: String) {
        guard old != new, let entry = entries[old] else { return }
        entries[new] = entry
        entries[old] = nil
    }
}
