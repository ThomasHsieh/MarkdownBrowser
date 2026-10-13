import Foundation
import SwiftUI

/// 側欄鏡像的一條標記。真正的資料在網頁端（見 `docs/SPEC.md` 12.8），
/// 這裡只是它送過來的顯示用副本。
struct HighlightItem: Identifiable, Hashable {
    let id: String
    let style: String
    let text: String
    let note: String
    let heading: String?
    let headingText: String?
    let orphan: Bool

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String,
              let style = raw["style"] as? String,
              let text = raw["text"] as? String else { return nil }
        self.id = id
        self.style = style
        self.text = text
        self.note = raw["note"] as? String ?? ""
        self.heading = raw["heading"] as? String
        self.headingText = raw["headingText"] as? String
        self.orphan = raw["orphan"] as? Bool ?? false
    }

    /// 側欄的色點。跟工具列的色票同一組實色 —— 它們是圖示，不是內文樣式。
    var color: Color {
        switch style {
        case "green": return Color(red: 0x5F / 255, green: 0xB8 / 255, blue: 0x78 / 255)
        case "blue": return Color(red: 0x5F / 255, green: 0x8F / 255, blue: 0xD0 / 255)
        case "purple": return Color(red: 0xA0 / 255, green: 0x7C / 255, blue: 0xE0 / 255)
        case "pink": return Color(red: 0xE0 / 255, green: 0x66 / 255, blue: 0x8F / 255)
        default: return .primary
        }
    }
}

/// 側欄下半部顯示什麼。每個視窗各自記住。
enum SidebarMode: String {
    case outline
    case highlights
}

/// 標記的 sidecar 檔：`<原檔名去掉副檔名>_highlights.json`，跟文件放在同一個資料夾。
///
/// 只有使用者的動作才會寫它 —— 打開、重新比對、發現某條對不上都不寫，
/// 否則唯讀閱讀器光是「打開來看」就會在 git 裡留下變動。
enum SidecarFile {

    static let suffix = "_highlights.json"

    /// 支援的格式版本。檔案寫著更新的版本就只讀不寫，免得把看不懂的欄位丟掉。
    static let version = 1

    enum ReadResult {
        case none
        case ok(String)
        /// 讀得到但不能用。**一律唯讀、絕不覆蓋** —— git 合併衝突留下的
        /// `<<<<<<<` 就是這種情況，當作「沒有標記」的話畫一條線就會把它蓋掉。
        case invalid(String)
    }

    static func url(for document: URL) -> URL {
        document.deletingLastPathComponent()
            .appendingPathComponent(document.deletingPathExtension().lastPathComponent + suffix)
    }

    static func read(for document: URL) -> ReadResult {
        read(at: url(for: document))
    }

    static func read(at file: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: file.path) else { return .none }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return .invalid("無法讀取標記檔，已停止寫入以免覆蓋")
        }
        if text.contains("<<<<<<<") || text.contains(">>>>>>>") {
            return .invalid("標記檔有 git 合併衝突，已停止寫入以免覆蓋")
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["highlights"] is [Any] else {
            return .invalid("標記檔格式錯誤，已停止寫入以免覆蓋")
        }
        if let v = object["version"] as? Int, v > version {
            return .invalid("標記檔的格式版本比這個 App 新，已停止寫入以免覆蓋")
        }
        // 網頁端載入時會略過看不懂的條目，下一次存檔就等於把它們刪了。
        // 所以只要有一條會被略過或被改掉，整個檔就只讀不寫。
        let entries = object["highlights"] as? [Any] ?? []
        guard entries.allSatisfy(isUnderstood) else {
            return .invalid("標記檔有這個 App 看不懂的條目，已停止寫入以免覆蓋")
        }
        return .ok(text)
    }

    static let styles: Set<String> = ["green", "blue", "purple", "pink", "underline"]

    /// 跟 highlights.js 的 load() 對齊：那邊會丟掉或補預設值的欄位，這裡都算看不懂。
    private static func isUnderstood(_ entry: Any) -> Bool {
        guard let h = entry as? [String: Any],
              h["id"] is String,
              let style = h["style"] as? String, styles.contains(style),
              h["exact"] is String else { return false }
        for key in ["prefix", "suffix", "note", "created"] where h[key] != nil {
            guard h[key] is String else { return false }
        }
        if let heading = h["heading"], !(heading is String || heading is NSNull) { return false }
        return true
    }

    /// `nil` 代表標記全刪光了：刪檔，不留一個空的 sidecar。原子寫入（暫存檔再 rename）。
    static func write(_ json: String?, for document: URL) throws {
        let file = url(for: document)
        if let json {
            try json.write(to: file, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// 開檔時就檢查能不能寫：DMG、唯讀磁碟、別人的共享資料夾。
    static func isWritable(for document: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: document.deletingLastPathComponent().path) else { return false }
        let file = url(for: document)
        return !fm.fileExists(atPath: file.path) || fm.isWritableFile(atPath: file.path)
    }

    /// 同資料夾裡「對應的檔已經不存在」的 sidecar —— 多半是 `.md` 被改名了。
    /// 讀不出來的跳過，不拿壞檔去認領。
    static func orphans(near document: URL) -> [(url: URL, json: String)] {
        let dir = document.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let stems = Set(files.filter { !$0.lastPathComponent.hasSuffix(suffix) }
            .map { $0.deletingPathExtension().lastPathComponent })
        return files.compactMap { file in
            let name = file.lastPathComponent
            guard name.hasSuffix(suffix) else { return nil }
            guard !stems.contains(String(name.dropLast(suffix.count))) else { return nil }
            guard case .ok(let json) = read(at: file) else { return nil }
            return (file, json)
        }
    }
}
