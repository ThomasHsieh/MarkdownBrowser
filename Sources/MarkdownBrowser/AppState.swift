import AppKit
import Combine
import Foundation

struct OutlineItem: Identifiable, Hashable {
    let id: String
    let level: Int
    let text: String
}

/// App 的全部狀態。單視窗，所以直接用一個共用實例 ——
/// AppDelegate 收到 Finder 的開檔請求時也拿得到。
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: 文件

    @Published private(set) var documentURL: URL?
    @Published private(set) var siblings: [URL] = []
    @Published private(set) var outline: [OutlineItem] = []
    @Published private(set) var recentDocuments: [URL] = []
    @Published var activeHeadingID: String?

    // MARK: 外觀（都存進 UserDefaults）

    @Published var theme: String {
        didSet {
            defaults.set(theme, forKey: Keys.theme)
            bridge?.setTheme(theme)
        }
    }

    /// 中文字體：`kai`（霞鶩文楷）或 `gothic`（更紗黑體）。
    /// 與主題正交 —— 主題管顏色與版面，這個只管用哪套字。
    @Published var fontFamily: String {
        didSet {
            defaults.set(fontFamily, forKey: Keys.fontFamily)
            bridge?.setFontFamily(fontFamily)
        }
    }

    @Published var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            bridge?.setFontSize(fontSize)
        }
    }

    @Published var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: Keys.sidebar) }
    }

    @Published private(set) var themes: [ThemeInfo] = UserAssets.builtInThemes

    // MARK: 內部

    weak var bridge: WebBridge?

    private let defaults = UserDefaults.standard
    private var documentWatcher: FileWatcher?
    private var folderWatcher: FileWatcher?
    private var configWatcher: FileWatcher?

    private enum Keys {
        static let theme = "theme"
        static let fontSize = "fontSize"
        static let fontFamily = "fontFamily"
        static let sidebar = "sidebarVisible"
        static let lastDocument = "lastDocumentBookmark"
        static let recents = "recentDocuments"
    }

    /// 「最近開啟」保留幾筆。
    static let recentLimit = 10

    private init() {
        theme = defaults.string(forKey: Keys.theme) ?? "reading"
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "kai"
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 17
        sidebarVisible = defaults.object(forKey: Keys.sidebar) as? Bool ?? true

        recentDocuments = (defaults.stringArray(forKey: Keys.recents) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        UserAssets.ensureDirectories()
        refreshThemes()

        // 改了自訂主題的 CSS 立刻生效。
        configWatcher = FileWatcher(url: UserAssets.themesDirectory, debounce: 0.2) { [weak self] in
            Task { @MainActor in self?.refreshThemes(reinject: true) }
        }
    }

    // MARK: - 開檔

    func open(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        documentURL = resolved
        defaults.set(resolved.path, forKey: Keys.lastDocument)
        NSDocumentController.shared.noteNewRecentDocumentURL(resolved)
        pushRecent(resolved)

        bridge?.setDocumentDirectory(resolved.deletingLastPathComponent())
        refreshSiblings()
        render(keepScroll: false)

        documentWatcher = FileWatcher(url: resolved) { [weak self] in
            self?.render(keepScroll: true)
        }
        folderWatcher = FileWatcher(url: resolved.deletingLastPathComponent(), debounce: 0.3) { [weak self] in
            self?.refreshSiblings()
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = documentURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// 自己維護「最近開啟」，不靠 NSDocumentController —— 這不是文件型 App，
    /// 系統那份清單管不到筆數上限，也不會把已刪掉的檔剔除。
    private func pushRecent(_ url: URL) {
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

    func restoreLastDocument() {
        guard documentURL == nil,
              let path = defaults.string(forKey: Keys.lastDocument),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }

    func render(keepScroll: Bool) {
        guard let url = documentURL else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        bridge?.render(markdown: text, keepScroll: keepScroll)
    }

    /// 網頁端載入完成後補送一次目前狀態。
    func pushInitialState() {
        bridge?.setTheme(theme)
        bridge?.setFontFamily(fontFamily)
        bridge?.setFontSize(fontSize)
        bridge?.setUserTheme(UserAssets.userThemeCSS())
        bridge?.setUserFonts(UserAssets.userFontCSS())
        render(keepScroll: false)
    }

    // MARK: - 側欄

    private func refreshSiblings() {
        guard let url = documentURL else { siblings = []; return }
        let dir = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let markdown = files.filter { ["md", "markdown", "mdown", "mkd", "mdwn"].contains($0.pathExtension.lowercased()) }
        siblings = ChapterSort.sorted(markdown)
    }

    func setOutline(_ items: [OutlineItem]) { outline = items }

    // MARK: - 主題

    private func refreshThemes(reinject: Bool = false) {
        themes = UserAssets.builtInThemes + UserAssets.userThemes()
        if reinject {
            bridge?.setUserTheme(UserAssets.userThemeCSS())
            bridge?.setUserFonts(UserAssets.userFontCSS())
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

    // MARK: - 字級

    func bumpFontSize(_ delta: Double) {
        fontSize = min(40, max(10, (fontSize + delta).rounded()))
    }

    func resetFontSize() { fontSize = 17 }

    /// 選單與工具列共用的字體清單。
    static let fontChoices: [(id: String, name: String)] = [
        ("kai", "楷體"),
        ("gothic", "黑體"),
    ]

    // MARK: - 外部程式

    func openInMarkEdit() {
        guard let url = documentURL else { return }
        let candidates = ["app.markedit.MarkEdit", "com.markedit.MarkEdit"]
        for bundleID in candidates {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        // 沒裝 MarkEdit 就退回系統預設的編輯器。
        NSWorkspace.shared.open(url)
    }

    func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Swift 對網頁端說話的介面，由 WebPane 的 Coordinator 實作。
@MainActor
protocol WebBridge: AnyObject {
    func render(markdown: String, keepScroll: Bool)
    func setTheme(_ name: String)
    func setFontFamily(_ name: String)
    func setFontSize(_ px: Double)
    func setUserTheme(_ css: String)
    func setUserFonts(_ css: String)
    func setDocumentDirectory(_ url: URL)
    func scrollToHeading(_ id: String)
    func openFind()
    func findNext()
    func findPrev()
    func printDocument()
}
