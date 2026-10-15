import AppKit
import Combine
import Foundation

/// 跨視窗共用的東西：新視窗的起始設定、最近開啟清單、書的配對與閱讀位置。
///
/// 字體、字級、外觀本身是「每個視窗各自的狀態」（見 `DocumentState`）——
/// 這裡只留最後一次的選擇，當下一個新視窗的起始值。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    @Published private(set) var recentDocuments: [URL] = []

    // MARK: - 新視窗的起始設定
    //
    // 任何視窗改了設定就更新這裡，所以「下一個視窗」永遠沿用最後一次的選擇。

    var appearance: String {
        didSet { defaults.set(appearance, forKey: Keys.appearance) }
    }

    var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) }
    }

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: Keys.sidebar) }
    }

    var sidebarMode: SidebarMode {
        didSet { defaults.set(sidebarMode.rawValue, forKey: Keys.sidebarMode) }
    }

    /// 對照開關：開著時心得配對到書就自動切成雙欄（docs/SPEC.md 13.3）。第一次安裝預設開。
    var compareEnabled: Bool {
        didSet { defaults.set(compareEnabled, forKey: Keys.compare) }
    }

    /// 書那欄的顯示方式：捲動、翻頁單頁、翻頁雙頁（docs/SPEC.md 13.12）。第一次安裝預設單頁。
    var bookLayout: BookLayout {
        didSet { defaults.set(bookLayout.rawValue, forKey: Keys.bookLayout) }
    }

    /// 雙欄的分隔線位置：書那欄佔內容區的比例。
    var splitRatio: Double {
        didSet { defaults.set(splitRatio, forKey: Keys.splitRatio) }
    }

    /// 手動指定的配對：心得資料夾路徑 → EPUB 路徑。同一本書的各章共用一筆。
    private(set) var bookPairs: [String: String] {
        didSet { defaults.set(bookPairs, forKey: Keys.bookPairs) }
    }

    /// 每個資料夾上次讀的心得。從 Finder 單獨開書、反向配對到心得時，開的就是這一份。
    private(set) var lastNoteByFolder: [String: String] {
        didSet { defaults.set(lastNoteByFolder, forKey: Keys.lastNoteByFolder) }
    }

    /// 每本書的閱讀位置：EPUB 路徑 → `{id, delta}`（可重排）或 `{page}`（固定版面）。
    /// 不寫任何檔案，唯讀閱讀器打開來看不該在書旁邊留下東西。
    private(set) var bookPositions: [String: [String: Any]] {
        didSet { defaults.set(bookPositions, forKey: Keys.bookPositions) }
    }

    /// 上次讀的檔。啟動時若沒有 Finder 指定的檔案，就還原這一份。
    var lastDocumentURL: URL? {
        guard let path = defaults.string(forKey: Keys.lastDocument),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static let defaultFontSize: Double = 17

    /// 「最近開啟」保留幾筆。
    static let recentLimit = 10

    /// 選單與工具列共用的外觀清單。比照 Safari 的「顯示方式 → 外觀」。
    static let appearanceChoices: [(id: String, name: String)] = [
        ("auto", "自動"),
        ("light", "淺色"),
        ("dark", "深色"),
    ]

    /// 選單與工具列共用的字體清單。
    static let fontChoices: [(id: String, name: String)] = [
        ("kai", "楷體"),
        ("gothic", "黑體"),
    ]

    // MARK: 內部

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontSize = "fontSize"
        static let fontFamily = "fontFamily"
        static let appearance = "appearance"
        static let sidebar = "sidebarVisible"
        static let sidebarMode = "sidebarMode"
        static let lastDocument = "lastDocumentBookmark"
        static let recents = "recentDocuments"
        static let compare = "compareEnabled"
        static let splitRatio = "splitRatio"
        static let bookLayout = "bookLayout"
        static let bookPairs = "bookPairs"
        static let lastNoteByFolder = "lastNoteByFolder"
        static let bookPositions = "bookPositions"
    }

    private init() {
        // 舊版存的主題（閱讀／終端機）已合併成唯一一套樣式，不再讀，也不必清
        appearance = defaults.string(forKey: Keys.appearance) ?? "auto"
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "kai"
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? Self.defaultFontSize
        sidebarVisible = defaults.object(forKey: Keys.sidebar) as? Bool ?? true
        sidebarMode = SidebarMode(rawValue: defaults.string(forKey: Keys.sidebarMode) ?? "") ?? .outline
        compareEnabled = defaults.object(forKey: Keys.compare) as? Bool ?? true
        splitRatio = defaults.object(forKey: Keys.splitRatio) as? Double ?? 0.5
        bookLayout = BookLayout(rawValue: defaults.string(forKey: Keys.bookLayout) ?? "") ?? .single
        bookPairs = defaults.dictionary(forKey: Keys.bookPairs) as? [String: String] ?? [:]
        lastNoteByFolder = defaults.dictionary(forKey: Keys.lastNoteByFolder) as? [String: String] ?? [:]
        bookPositions = defaults.dictionary(forKey: Keys.bookPositions) as? [String: [String: Any]] ?? [:]

        recentDocuments = (defaults.stringArray(forKey: Keys.recents) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        observeSystemAppearance()
    }

    // MARK: - 最近開啟

    /// 自己維護「最近開啟」，不靠 NSDocumentController —— 這不是文件型 App，
    /// 系統那份清單管不到筆數上限，也不會把已刪掉的檔剔除。
    func noteOpened(_ url: URL) {
        defaults.set(url.path, forKey: Keys.lastDocument)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        var list = recentDocuments.filter { $0.path != url.path }
        list.insert(url, at: 0)
        if list.count > Self.recentLimit { list.removeLast(list.count - Self.recentLimit) }
        recentDocuments = list
        defaults.set(list.map(\.path), forKey: Keys.recents)
    }

    /// `primary` 為假是對照模式下跟著心得自動打開的書：不算「最近開啟」，
    /// 也不當作上次讀的檔 —— 否則下次啟動會還原成單獨看書。
    func noteOpened(_ url: URL, primary: Bool) {
        if BookPairing.isMarkdown(url) {
            lastNoteByFolder[url.deletingLastPathComponent().path] = url.path
        }
        if primary { noteOpened(url) }
    }

    func clearRecentDocuments() {
        recentDocuments = []
        defaults.removeObject(forKey: Keys.recents)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: - 書

    func setBookPair(folder: URL, book: URL?) {
        bookPairs[folder.path] = book?.standardizedFileURL.path
    }

    func bookPosition(for book: URL) -> [String: Any]? { bookPositions[book.path] }

    func setBookPosition(_ position: [String: Any], for book: URL) {
        bookPositions[book.path] = position
    }

    func lastNote(in folder: URL) -> URL? {
        guard let path = lastNoteByFolder[folder.path], FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - 系統外觀

    /// 跟隨系統的視窗要在使用者切換系統明暗時一起變。
    ///
    /// 不要用 KVO 盯 `NSApp.effectiveAppearance` —— 它不保證 KVO 相容，實測
    /// 系統切換時不會觸發（視窗外框自己變了，網頁內容卻還留在深色）。
    /// 可靠的做法是聽系統廣播的佈景變更通知。通知送達時 effectiveAppearance
    /// 偶爾還沒更新，所以晚一個 runloop 再讀。
    private func observeSystemAppearance() {
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                for document in WindowRouter.shared.documents where document.appearance == "auto" {
                    document.pushAppearance()
                }
            }
        }
    }
}
