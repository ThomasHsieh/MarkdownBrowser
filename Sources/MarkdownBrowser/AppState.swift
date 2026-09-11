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
    @Published var activeHeadingID: String?

    // MARK: 外觀（都存進 UserDefaults）

    @Published var theme: String {
        didSet {
            defaults.set(theme, forKey: Keys.theme)
            bridge?.setTheme(theme)
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
        static let sidebar = "sidebarVisible"
        static let lastDocument = "lastDocumentBookmark"
    }

    private init() {
        theme = defaults.string(forKey: Keys.theme) ?? "reading"
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 17
        sidebarVisible = defaults.object(forKey: Keys.sidebar) as? Bool ?? true

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
