import AppKit
import Combine
import Foundation

/// 跨視窗共用的東西：新視窗的起始設定、自訂主題目錄、最近開啟清單。
///
/// 主題、字體、字級、外觀本身是「每個視窗各自的狀態」（見 `DocumentState`）——
/// 這裡只留最後一次的選擇，當下一個新視窗的起始值。真正全 App 共用的只有
/// 自訂主題與字型的檔案集合，以及最近開啟清單。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    /// 選單上的主題清單：內建兩套 ＋ `~/.config/markdownbrowser/themes/*.css`。
    @Published private(set) var themes: [ThemeInfo] = UserAssets.builtInThemes

    @Published private(set) var recentDocuments: [URL] = []

    // MARK: - 新視窗的起始設定
    //
    // 任何視窗改了設定就更新這裡，所以「下一個視窗」永遠沿用最後一次的選擇。

    var theme: String {
        didSet { defaults.set(theme, forKey: Keys.theme) }
    }

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
    private var configWatcher: FileWatcher?

    private enum Keys {
        static let theme = "theme"
        static let fontSize = "fontSize"
        static let fontFamily = "fontFamily"
        static let appearance = "appearance"
        static let sidebar = "sidebarVisible"
        static let lastDocument = "lastDocumentBookmark"
        static let recents = "recentDocuments"
    }

    private init() {
        theme = defaults.string(forKey: Keys.theme) ?? "reading"
        appearance = defaults.string(forKey: Keys.appearance) ?? "auto"
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "kai"
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? Self.defaultFontSize
        sidebarVisible = defaults.object(forKey: Keys.sidebar) as? Bool ?? true

        recentDocuments = (defaults.stringArray(forKey: Keys.recents) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        UserAssets.ensureDirectories()
        refreshThemes()
        observeSystemAppearance()

        // 改了自訂主題的 CSS 立刻生效。檔案集合是全 App 共用的，所以改動要推給每個視窗。
        configWatcher = FileWatcher(url: UserAssets.themesDirectory, debounce: 0.2) { [weak self] in
            Task { @MainActor in self?.refreshThemes(reinject: true) }
        }
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

    func clearRecentDocuments() {
        recentDocuments = []
        defaults.removeObject(forKey: Keys.recents)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: - 主題

    func refreshThemes(reinject: Bool = false) {
        themes = UserAssets.builtInThemes + UserAssets.userThemes()
        guard reinject else { return }
        let css = UserAssets.userThemeCSS()
        let fonts = UserAssets.userFontCSS()
        for document in WindowRouter.shared.documents {
            document.bridge?.setUserTheme(css)
            document.bridge?.setUserFonts(fonts)
        }
    }

    func openConfigDirectory() {
        UserAssets.ensureDirectories()
        NSWorkspace.shared.open(UserAssets.configDirectory)
    }

    func exportBuiltInThemes() {
        if let dir = try? UserAssets.exportBuiltInThemes() {
            refreshThemes(reinject: true)
            NSWorkspace.shared.open(dir)
        }
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
