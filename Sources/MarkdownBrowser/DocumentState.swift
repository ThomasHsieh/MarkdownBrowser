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

    @Published var sidebarMode: SidebarMode {
        didSet { settings.sidebarMode = sidebarMode }
    }

    // MARK: 標記
    //
    // 網頁端是標記資料的唯一真相，這裡只有側欄要的鏡像與 sidecar 檔的讀寫。

    @Published private(set) var highlights: [HighlightItem] = []
    @Published private(set) var sidecarExists = false

    /// 唯讀的原因；`nil` 代表可以寫。資料夾不能寫、sidecar 讀不出來都會設。
    @Published private(set) var highlightsReadOnly: String?

    /// 最後一次讀到或寫入的 sidecar 內容。自己寫檔也會觸發資料夾的監聽，
    /// 內容一樣就是自己的回音，不重新載入。
    private var lastSidecarText: String?

    /// 寫入失敗、還留在記憶體裡的內容。外層 Optional 是「有沒有待寫」，
    /// 內層 `nil` 是「要刪檔」。
    private var pendingSave: String??

    /// 這個檔已經問過要不要認領孤兒 sidecar 了，同一次開啟不再問。
    private var offeredOrphansFor: String?

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
        sidebarMode = settings.sidebarMode
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

    /// 一律經過 `WindowRouter.open(_:in:)` 進來，那裡保證一檔一窗。
    func open(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        // 換檔前先把打到一半的註記寫進舊檔的 sidecar，寫完（或寫不進去、問過了）才換。
        // 不能只發出 commitNote 就往下走：寫入結果晚一步才回來，那時 documentURL
        // 已經換掉，失敗就沒有地方可以出警示。離開一份文件等同關掉它。
        guard documentURL != nil else { performOpen(resolved); return }
        prepareToCloseAsync { [self] in
            resolvePendingSave()
            performOpen(resolved)
        }
    }

    private func performOpen(_ resolved: URL) {
        documentURL = resolved
        settings.noteOpened(resolved)
        highlights = []
        offeredOrphansFor = nil

        bridge?.setDocumentDirectory(resolved.deletingLastPathComponent())
        refreshSiblings()
        render(keepScroll: false)

        documentWatcher = FileWatcher(url: resolved, onRename: { [weak self] newURL in
            self?.followRename(to: newURL)
        }) { [weak self] in
            self?.render(keepScroll: true)
        }
        // 資料夾的監聽同時負責 sidecar：git pull、checkout 都是換檔，會反映在資料夾上
        folderWatcher = FileWatcher(url: resolved.deletingLastPathComponent(), debounce: 0.3) { [weak self] in
            self?.refreshSiblings()
            self?.reloadSidecarIfChanged()
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = documentURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { WindowRouter.shared.open(url, in: self) }
    }

    /// `keepScroll` 為真是重載同一份文件：標記沿用網頁端記憶體裡的（那才是唯一的真相），
    /// 只重新比對錨點。為假是換了檔，才從 sidecar 讀進來。
    func render(keepScroll: Bool) {
        guard let url = documentURL else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        bridge?.render(markdown: text, keepScroll: keepScroll,
                       highlights: keepScroll ? nil : loadSidecar(for: url))
        if !keepScroll { offerOrphanSidecars(for: url) }
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

    // MARK: - 標記：sidecar 讀寫

    /// 讀 sidecar，順便決定唯讀狀態與警示列。回傳要送給網頁端的內容。
    private func loadSidecar(for url: URL) -> [String: Any] {
        var json: String?
        var banner: (String, [(String, String)])?
        switch SidecarFile.read(for: url) {
        case .none:
            lastSidecarText = nil
            highlightsReadOnly = SidecarFile.isWritable(for: url) ? nil : "此資料夾無法寫入，不能標記"
        case .ok(let text):
            lastSidecarText = text
            json = text
            highlightsReadOnly = SidecarFile.isWritable(for: url) ? nil : "此資料夾無法寫入，不能標記"
        case .invalid(let reason):
            // 記下壞檔的原文：同一份壞檔不會反覆觸發重新載入，修好之後內容一變就會
            lastSidecarText = try? String(contentsOf: SidecarFile.url(for: url), encoding: .utf8)
            highlightsReadOnly = reason
            banner = (reason, [("reveal", "在 Finder 中顯示")])
        }
        sidecarExists = FileManager.default.fileExists(atPath: SidecarFile.url(for: url).path)
        pendingSave = nil
        if let banner { bridge?.setHighlightBanner(banner.0, actions: banner.1) }
        else { bridge?.setHighlightBanner(nil, actions: []) }
        return ["doc": url.path, "json": json ?? NSNull(),
                "writable": highlightsReadOnly == nil, "reason": highlightsReadOnly ?? ""]
    }

    /// 網頁端送來的存檔請求。`doc` 是它當時在讀的檔 —— 換檔前最後一筆註記會晚一步才到，
    /// 那時 `documentURL` 已經換了，要寫回它自己的 sidecar，不能寫到新檔去。
    func saveHighlights(doc: String, json: String?) {
        guard let url = documentURL, url.path == doc else {
            // 舊檔已經不在（被改名、刪掉）就不寫，免得在原地生出孤兒；
            // 舊的 sidecar 讀不出來（合併衝突）也不寫，絕不覆蓋
            let old = URL(fileURLWithPath: doc)
            guard FileManager.default.fileExists(atPath: old.path) else { return }
            if case .invalid = SidecarFile.read(for: old) { return }
            try? SidecarFile.write(json, for: old)
            return
        }
        guard highlightsReadOnly == nil else { return }
        do {
            try SidecarFile.write(json, for: url)
            lastSidecarText = json
            sidecarExists = json != nil
            if pendingSave != nil {
                pendingSave = nil
                bridge?.setHighlightBanner(nil, actions: [])
            }
        } catch {
            // 不跳對話框：註記每 500 ms 寫一次，失敗時會連續轟炸。標記還在網頁端的記憶體裡，
            // 下次有異動就會再送一次；關視窗時還沒寫進去才問（resolvePendingSave）。
            pendingSave = .some(json)
            bridge?.setHighlightBanner("標記無法儲存：\(error.localizedDescription)",
                                       actions: [("retry", "重試")])
        }
    }

    func setHighlights(doc: String, items: [HighlightItem]) {
        guard documentURL?.path == doc else { return }
        highlights = items
    }

    func handleBannerAction(_ id: String) {
        switch id {
        case "retry":
            if let pending = pendingSave, let url = documentURL { saveHighlights(doc: url.path, json: pending) }
        case "reveal":
            revealSidecarInFinder()
        default:
            break
        }
    }

    /// sidecar 被外部改動（git pull、checkout、手動修好合併衝突）就重新載入。
    /// 跟自己最後寫的一樣就是回音，不理。
    private func reloadSidecarIfChanged() {
        guard let url = documentURL else { return }
        let file = SidecarFile.url(for: url)
        sidecarExists = FileManager.default.fileExists(atPath: file.path)
        let current = try? String(contentsOf: file, encoding: .utf8)
        guard current != lastSidecarText else { return }
        bridge?.setHighlights(loadSidecar(for: url))
    }

    /// 關視窗、換檔、結束 App 時還有沒寫進去的標記：這是唯一會打斷你的時候，
    /// 再不處理資料就真的沒了。
    func resolvePendingSave() {
        guard let pending = pendingSave, let url = documentURL else { return }
        while true {
            let alert = NSAlert()
            alert.messageText = "有標記尚未儲存"
            alert.informativeText = "「\(url.lastPathComponent)」的標記寫不進標記檔。"
            alert.addButton(withTitle: "再試一次")
            alert.addButton(withTitle: "拷貝為 JSON")
            alert.addButton(withTitle: "放棄")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try SidecarFile.write(pending, for: url)
                    pendingSave = nil
                    return
                } catch { continue }
            case .alertSecondButtonReturn:
                copyToPasteboard(pending ?? "")
                pendingSave = nil
                return
            default:
                pendingSave = nil
                return
            }
        }
    }

    /// 視窗要關了：打到一半的註記用回傳值自己寫（網頁端的訊息可能來不及送到），
    /// 還有沒寫進去的標記就問。
    func prepareToClose() {
        // 要等 commitNote 的回呼：最後一筆註記是在回呼裡才寫的，寫入失敗也是那時才知道。
        // 閉包強持有 self，視窗關了這份狀態也還活著；網頁端沒回應就 1.5 秒後照常處理。
        var resolved = false
        let finish = { [self] in
            guard !resolved else { return }
            resolved = true
            resolvePendingSave()
        }
        prepareToCloseAsync(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { finish() } }
    }

    func prepareToCloseAsync(_ done: @escaping () -> Void) {
        guard let url = documentURL, highlightsReadOnly == nil, let bridge else { done(); return }
        bridge.commitNote { [self] json in
            if let json {
                do { try SidecarFile.write(json, for: url); lastSidecarText = json }
                catch { pendingSave = .some(json) }
            }
            done()
        }
    }

    func revealSidecarInFinder() {
        guard let url = documentURL else { return }
        let file = SidecarFile.url(for: url)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func copyToPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: - 標記：改名

    /// App 開著時檔案被改名（多半是 AI 用 `git mv` 改了章名）：視窗跟到新檔，
    /// sidecar 一起改名。這是「只有使用者動作才寫檔」唯一的例外 —— 它在跟上一個
    /// 已經發生的改名，比留下孤兒乾淨。
    private func followRename(to newURL: URL) {
        guard let old = documentURL else { return }
        let finish: (String?) -> Void = { [weak self] json in
            guard let self else { return }
            // 打到一半的註記先寫進舊的 sidecar，再整個搬過去
            if let json, self.highlightsReadOnly == nil { try? SidecarFile.write(json, for: old) }
            let from = SidecarFile.url(for: old), to = SidecarFile.url(for: newURL)
            let fm = FileManager.default
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
            // 一檔一窗：新檔名若已經開在別的視窗，就交給那個視窗，這裡不重複開。
            // 不帶到前景 —— 改名多半是 AI 在背景做的，不該搶走焦點
            WindowRouter.shared.open(newURL, in: self, activate: false)
        }
        if let bridge { bridge.commitNote(completion: finish) } else { finish(nil) }
    }

    /// 打開一個沒有 sidecar 的檔：同資料夾裡有「對應的檔已經不存在」的 sidecar，
    /// 就拿它試比對目前的內容，過半數對得上才問要不要接上。
    private func offerOrphanSidecars(for url: URL) {
        guard offeredOrphansFor != url.path, let bridge else { return }
        guard case .none = SidecarFile.read(for: url), highlightsReadOnly == nil else { return }
        let candidates = SidecarFile.orphans(near: url)
        guard !candidates.isEmpty else { return }
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url.lastPathComponent, $0) })
        bridge.probeHighlights(candidates.map { ["name": $0.url.lastPathComponent, "json": $0.json] }) { [weak self] results in
            guard let self, self.documentURL == url else { return }
            self.offeredOrphansFor = url.path
            let best = results
                .filter { $0.total > 0 && $0.matched * 2 > $0.total }
                .max { Double($0.matched) / Double($0.total) < Double($1.matched) / Double($1.total) }
            guard let best, let source = byName[best.name] else { return }

            let alert = NSAlert()
            alert.messageText = "找到 \(best.matched) 條可能屬於這個檔案的標記"
            let stem = String(best.name.dropLast(SidecarFile.suffix.count))
            alert.informativeText = "來自「\(stem)」（共 \(best.total) 條，對得上 \(best.matched) 條）。原檔可能被改名了，要接上嗎？"
            alert.addButton(withTitle: "接上")
            alert.addButton(withTitle: "不要")
            let apply: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .alertFirstButtonReturn, self.documentURL == url else { return }
                let target = SidecarFile.url(for: url)
                guard !FileManager.default.fileExists(atPath: target.path) else { return }
                do {
                    try FileManager.default.moveItem(at: source.url, to: target)
                    self.bridge?.setHighlights(self.loadSidecar(for: url))
                } catch {
                    self.bridge?.setHighlightBanner("無法接上標記檔：\(error.localizedDescription)", actions: [])
                }
            }
            if let window = self.window { alert.beginSheetModal(for: window, completionHandler: apply) }
            else { apply(alert.runModal()) }
        }
    }

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

    // 標記（docs/SPEC.md 12.8）
    func render(markdown: String, keepScroll: Bool, highlights: [String: Any]?)
    func setHighlights(_ payload: [String: Any])
    func setHighlightBanner(_ text: String?, actions: [(String, String)])
    func revealHighlight(_ id: String)
    func deleteHighlight(_ id: String)
    func highlightSelection(completion: @escaping (Bool) -> Void)
    func commitNote(completion: @escaping (String?) -> Void)
    func probeHighlights(_ candidates: [[String: String]],
                         completion: @escaping ([(name: String, matched: Int, total: Int)]) -> Void)
}
