import AppKit
import Combine
import Foundation

struct OutlineItem: Identifiable, Hashable {
    let id: String
    let level: Int
    let text: String
    /// 書的標題所在的章（`EpubBook.toc` 的索引）；心得沒有
    var chapter: Int? = nil
}

/// 一欄的文件：讀哪個檔、它的大綱、標記與 sidecar 檔。
///
/// 對照模式下一個視窗有兩欄（左書右心得），兩欄都要標記、都要監聽檔案、都要在
/// 關窗前把註記寫完 —— 所以這些從 `DocumentState` 抽出來，心得（`DocumentState`
/// 本身）與書（`BookPane`）共用同一份。主題、字體這類「整個視窗」的設定
/// 留在 `DocumentState`，這裡透過 `windowState` 去拿。
@MainActor
class PaneDocument: ObservableObject, Identifiable {

    let id = UUID()

    // MARK: 文件

    @Published fileprivate(set) var documentURL: URL?
    @Published private(set) var outline: [OutlineItem] = []
    @Published var activeHeadingID: String?

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

    private var documentWatcher: FileWatcher?
    private var folderWatcher: FileWatcher?

    /// 這一欄所在視窗的狀態。心得那欄就是自己，書那欄是它的宿主。
    var windowState: DocumentState? { nil }

    /// 用來把對話框掛成 sheet。
    var paneWindow: NSWindow? { windowState?.window }

    // MARK: - 開檔

    /// 換檔前先把打到一半的註記寫進舊檔的 sidecar，寫完（或寫不進去、問過了）才換。
    /// 不能只發出 commitNote 就往下走：寫入結果晚一步才回來，那時 documentURL
    /// 已經換掉，失敗就沒有地方可以出警示。離開一份文件等同關掉它。
    func loadDocument(_ url: URL, then done: (() -> Void)? = nil) {
        let resolved = url.resolvingSymlinksInPath()
        guard documentURL != nil else { performOpen(resolved); done?(); return }
        prepareToCloseAsync { [self] in
            resolvePendingSave()
            performOpen(resolved)
            done?()
        }
    }

    private func performOpen(_ resolved: URL) {
        documentURL = resolved
        highlights = []
        offeredOrphansFor = nil
        didOpen(resolved)
        render(keepScroll: false)

        documentWatcher = FileWatcher(url: resolved, onRename: { [weak self] newURL in
            self?.followRename(to: newURL)
        }) { [weak self] in
            self?.render(keepScroll: true)
        }
        // 資料夾的監聽同時負責 sidecar：git pull、checkout 都是換檔，會反映在資料夾上
        folderWatcher = FileWatcher(url: resolved.deletingLastPathComponent(), debounce: 0.3) { [weak self] in
            self?.folderDidChange()
            self?.reloadSidecarIfChanged()
        }
    }

    /// 把這一欄清空：書被搬到別的視窗、心得被另一個視窗接走時用。
    /// 呼叫前要先 `prepareToCloseAsync`，打到一半的註記才不會丟。
    func unload() {
        documentWatcher = nil
        folderWatcher = nil
        documentURL = nil
        outline = []
        activeHeadingID = nil
        highlights = []
        sidecarExists = false
        highlightsReadOnly = nil
        lastSidecarText = nil
        pendingSave = nil
        didUnload()
    }

    /// 子類別的掛勾。
    func didOpen(_ url: URL) {}
    func didUnload() {}
    func folderDidChange() {}

    /// `keepScroll` 為真是重載同一份文件：標記沿用網頁端記憶體裡的（那才是唯一的真相），
    /// 只重新比對錨點。為假是換了檔，才從 sidecar 讀進來。
    func render(keepScroll: Bool) {
        guard let url = documentURL else { return }
        let payload = keepScroll ? nil : loadSidecar(for: url)
        guard renderContent(url, keepScroll: keepScroll, highlights: payload) else { return }
        flushPendingSync()
        if !keepScroll { offerOrphanSidecars(for: url) }
    }

    // MARK: - 同步

    /// 換檔之後要做的同步。網頁端還沒載入完（新開的欄）就先存著，渲染完再送。
    private var pendingSync: [String: Any]?

    func queueSync(_ request: [String: Any]) {
        pendingSync = request
        flushPendingSync()
    }

    func cancelPendingSync() { pendingSync = nil }

    private func flushPendingSync() {
        guard let request = pendingSync, documentURL != nil, let bridge, bridge.isReady else { return }
        pendingSync = nil
        bridge.syncTo(request)
    }

    /// 真正把內容送給網頁端。回傳有沒有送出去（讀不到檔就沒有）。
    func renderContent(_ url: URL, keepScroll: Bool, highlights: [String: Any]?) -> Bool { false }

    /// 網頁端載入完成後補送一次這個視窗目前的狀態。
    func pushInitialState() {
        guard let bridge, let window = windowState else { return }
        bridge.setTheme(window.theme)
        bridge.setAppearance(window.resolvedAppearance)
        bridge.setFontFamily(window.fontFamily)
        bridge.setFontSize(window.fontSize)
        bridge.setUserTheme(UserAssets.userThemeCSS())
        bridge.setUserFonts(UserAssets.userFontCSS())
        render(keepScroll: false)
    }

    func setOutline(_ items: [OutlineItem]) { outline = items }

    // MARK: - 標記：sidecar 讀寫

    /// 讀 sidecar，順便決定唯讀狀態與警示列。回傳要送給網頁端的內容。
    func loadSidecar(for url: URL) -> [String: Any] {
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

    /// 把這一欄交出去（搬到別的視窗、或被另一個視窗接走）：註記先寫完、
    /// 寫不進去的先問，最後清空。
    func release(then done: @escaping () -> Void) {
        prepareToCloseAsync { [self] in
            resolvePendingSave()
            unload()
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
            self.followRenamedDocument(to: newURL)
        }
        if let bridge { bridge.commitNote(completion: finish) } else { finish(nil) }
    }

    /// 改名後換到新路徑。子類別決定怎麼走（心得要經過 `WindowRouter` 保證一檔一窗）。
    func followRenamedDocument(to newURL: URL) {}

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
            if let window = self.paneWindow { alert.beginSheetModal(for: window, completionHandler: apply) }
            else { apply(alert.runModal()) }
        }
    }

    // MARK: - 網頁端送來的互動（docs/SPEC.md 13.10）

    /// 內文標題被點。
    func headingClicked(id: String, text: String, level: Int, chapter: Int?, isChapterTitle: Bool) {}

    /// 心得裡的引文被點。headingID 是引文所在小節的標題，前面沒有標題時是 nil。
    func quoteClicked(text: String, headingID: String?) {}

    /// 書目前的位置（章、閱讀位置）。只有書那欄會送。
    func positionChanged(_ body: [String: Any]) {}

    func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
