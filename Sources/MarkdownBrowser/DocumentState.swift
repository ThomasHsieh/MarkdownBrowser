import AppKit
import Combine
import Foundation

struct OutlineItem: Identifiable, Hashable {
    let id: String
    let level: Int
    let text: String
}

/// 一個視窗的全部狀態：讀哪個檔、側欄內容、以及這個視窗的主題與字體。
///
/// 原本是 `AppState.shared` 單例，多視窗之後改成一個視窗一份 —— 單例的版本
/// 只要 Finder 再開一個檔就會蓋掉正在讀的那一份。跨視窗共用的東西
/// （自訂主題目錄、最近開啟、新視窗的起始設定）在 `AppSettings`。
@MainActor
final class DocumentState: ObservableObject, Identifiable {

    let id = UUID()

    // MARK: 文件

    @Published private(set) var documentURL: URL?
    @Published private(set) var siblings: [URL] = []
    @Published private(set) var outline: [OutlineItem] = []
    @Published var activeHeadingID: String?

    // MARK: 外觀
    //
    // 每個視窗各自一份，起始值取自 AppSettings，改動時也寫回去當下一個視窗的起始值。

    @Published var theme: String {
        didSet {
            settings.theme = theme
            bridge?.setTheme(theme)
        }
    }

    /// 外觀：`auto` 跟隨系統，或強制 `light` / `dark`。
    /// 與主題、字體同樣正交 —— 主題決定版面，外觀只決定明暗那一組顏色。
    @Published var appearance: String {
        didSet {
            settings.appearance = appearance
            applyAppearance()
        }
    }

    /// 中文字體：`kai`（霞鶩文楷）或 `gothic`（更紗黑體）。
    /// 與主題正交 —— 主題管顏色與版面，這個只管用哪套字。
    @Published var fontFamily: String {
        didSet {
            settings.fontFamily = fontFamily
            bridge?.setFontFamily(fontFamily)
        }
    }

    @Published var fontSize: Double {
        didSet {
            settings.fontSize = fontSize
            bridge?.setFontSize(fontSize)
        }
    }

    @Published var sidebarVisible: Bool {
        didSet { settings.sidebarVisible = sidebarVisible }
    }

    // MARK: 內部

    weak var bridge: WebBridge?

    /// 由 `WindowRouter` 在視窗出現時掛上。用來把視窗帶到前景，
    /// 以及把強制的淺色／深色設到視窗上。
    private(set) weak var window: NSWindow?

    private let settings = AppSettings.shared
    private var documentWatcher: FileWatcher?
    private var folderWatcher: FileWatcher?

    init() {
        let settings = AppSettings.shared
        theme = settings.theme
        appearance = settings.appearance
        fontFamily = settings.fontFamily
        fontSize = settings.fontSize
        sidebarVisible = settings.sidebarVisible
    }

    // MARK: - 視窗

    /// 視窗出現後才拿得到 `NSWindow`。強制的淺色／深色是設在視窗上的，
    /// 所以掛上的同時要把外觀補上去。
    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        applyAppearance()
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp?.activate()
    }

    // MARK: - 開檔

    func open(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        documentURL = resolved
        settings.noteOpened(resolved)

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

    func render(keepScroll: Bool) {
        guard let url = documentURL else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        bridge?.render(markdown: text, keepScroll: keepScroll)
    }

    /// 網頁端載入完成後補送一次這個視窗目前的狀態。
    func pushInitialState() {
        guard let bridge else { return }
        bridge.setTheme(theme)
        bridge.setAppearance(resolvedAppearance)
        bridge.setFontFamily(fontFamily)
        bridge.setFontSize(fontSize)
        bridge.setUserTheme(UserAssets.userThemeCSS())
        bridge.setUserFonts(UserAssets.userFontCSS())
        if let url = documentURL {
            bridge.setDocumentDirectory(url.deletingLastPathComponent())
        }
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

    // MARK: - 字級

    func bumpFontSize(_ delta: Double) {
        fontSize = min(40, max(10, (fontSize + delta).rounded()))
    }

    func resetFontSize() { fontSize = AppSettings.defaultFontSize }

    // MARK: - 外觀

    /// `auto` 要問系統現在是哪一種，其餘直接用。
    var resolvedAppearance: String {
        guard appearance == "auto" else { return appearance }
        let current = window?.effectiveAppearance ?? NSApp?.effectiveAppearance
        return current?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    /// 外觀是每個視窗各自的，所以強制模式設在 `NSWindow` 上而不是 `NSApp` ——
    /// 設在 NSApp 會讓所有視窗一起變；而完全不設的話，只有網頁內容變色，
    /// 視窗外框（側欄、工具列、標題列）還是系統的那一套。
    private func applyAppearance() {
        switch appearance {
        case "light": window?.appearance = NSAppearance(named: .aqua)
        case "dark": window?.appearance = NSAppearance(named: .darkAqua)
        default: window?.appearance = nil          // nil = 交還給系統
        }
        pushAppearance()
    }

    func pushAppearance() {
        bridge?.setAppearance(resolvedAppearance)
    }

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

/// Swift 對網頁端說話的介面，由 WebPane 的 Coordinator 實作。一個視窗一份。
@MainActor
protocol WebBridge: AnyObject {
    func render(markdown: String, keepScroll: Bool)
    func setTheme(_ name: String)
    func setAppearance(_ mode: String)
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
