import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 對照模式下的兩欄。
enum PaneSide: String {
    case book
    case note
}

/// 書那欄的顯示方式（docs/SPEC.md 13.12）。只有書那欄有，心得一律捲動。
enum BookLayout: String, CaseIterable {
    case scroll
    case single
    case double

    var name: String {
        switch self {
        case .scroll: return "捲動"
        case .single: return "單頁"
        case .double: return "雙頁"
        }
    }
}

/// 一個視窗的全部狀態：讀哪份心得、側欄內容、這個視窗的字體與外觀，
/// 以及對照模式下左邊那本書（`book`）。
///
/// 原本是 `AppState.shared` 單例，多視窗之後改成一個視窗一份 —— 單例的版本
/// 只要 Finder 再開一個檔就會蓋掉正在讀的那一份。跨視窗共用的東西
/// （最近開啟、新視窗的起始設定）在 `AppSettings`。
///
/// 心得本身的文件、標記、sidecar 邏輯在父類別 `PaneDocument`，書那欄（`BookPane`）
/// 用的是同一份。
@MainActor
final class DocumentState: PaneDocument {

    // MARK: 文件

    @Published private(set) var siblings: [URL] = []

    // MARK: 外觀
    //
    // 每個視窗各自一份，起始值取自 AppSettings，改動時也寫回去當下一個視窗的起始值。
    // 兩欄共用：書那欄跟著視窗走（docs/SPEC.md 13.3）。

    /// 外觀：`auto` 跟隨系統，或強制 `light` / `dark`。
    /// 與字體正交 —— 外觀只決定明暗那一組顏色。
    @Published var appearance: String {
        didSet {
            settings.appearance = appearance
            pushAppearance()
        }
    }

    /// 中文字體：`kai`（霞鶩文楷）或 `gothic`（更紗黑體）。
    /// 與外觀正交 —— 這個只管用哪套字。
    @Published var fontFamily: String {
        didSet {
            settings.fontFamily = fontFamily
            panes.forEach { $0.bridge?.setFontFamily(fontFamily) }
        }
    }

    /// 兩欄共用同一個字級，兩邊的字看起來才一樣大。
    @Published var fontSize: Double {
        didSet {
            settings.fontSize = fontSize
            panes.forEach { $0.bridge?.setFontSize(fontSize) }
        }
    }

    @Published var sidebarVisible: Bool {
        didSet { settings.sidebarVisible = sidebarVisible }
    }

    @Published var sidebarMode: SidebarMode {
        didSet { settings.sidebarMode = sidebarMode }
    }

    // MARK: 對照（docs/SPEC.md 第 13 節）

    /// 左邊那本書。永遠有這個物件，沒開書時它的 `documentURL` 是 nil。
    let book: BookPane

    /// 對照開關。開著時心得配對到書就自動切成雙欄；新視窗沿用最後一次的值。
    @Published var compareEnabled: Bool {
        didSet { settings.compareEnabled = compareEnabled }
    }

    /// 書那欄的顯示方式。每個視窗各自，新視窗沿用最後一次的選擇。
    @Published var bookLayout: BookLayout {
        didSet {
            settings.bookLayout = bookLayout
            book.bridge?.setBookLayout(bookLayout.rawValue)
        }
    }

    /// 書那欄佔內容區的比例。
    @Published var splitRatio: Double {
        didSet { settings.splitRatio = splitRatio }
    }

    /// 最後點過的那一欄。`⌘F`、`⌘P`、標記都作用在這一欄。
    @Published var focusedPane: PaneSide = .note

    /// 窄視窗改成 tab 時顯示哪一欄。
    @Published var selectedTab: PaneSide = .note {
        didSet {
            guard selectedTab != oldValue else { return }
            focusedPane = selectedTab
            // 背景捲好的那一欄，切過去時才閃目標標題（13.6 節）
            pane(selectedTab).bridge?.revealPendingSync()
        }
    }

    /// 由版面回報：現在是不是窄到改成 tab。同步時要知道另一欄看不看得到。
    var isTabbed = false {
        didSet { if isTabbed != oldValue { pushLinked() } }
    }

    /// 使用者主動打開的是哪一邊。關掉對照時留下這一邊。
    private(set) var primarySide: PaneSide = .note

    /// 心得配對到的書（不論對照開關），工具列按鈕要知道能不能按。
    @Published private(set) var pairedBookURL: URL?

    /// 書配對到的心得資料夾（單獨開書時），同上。
    @Published private(set) var pairedNoteLocation: (folder: URL, single: URL?)?

    /// 書的章 ↔ 心得檔
    @Published private(set) var chapterMap = ChapterMap.empty

    static let splitThreshold: CGFloat = 1040

    // MARK: 內部

    /// 由 `WindowRouter` 在視窗出現時掛上。用來把視窗帶到前景，
    /// 以及把強制的淺色／深色設到視窗上。
    private(set) weak var window: NSWindow?

    private let settings = AppSettings.shared
    private var bookObserver: AnyCancellable?

    override var windowState: DocumentState? { self }
    override var paneWindow: NSWindow? { window }

    var panes: [PaneDocument] { [self, book] }

    func pane(_ side: PaneSide) -> PaneDocument { side == .book ? book : self }

    override init() {
        let settings = AppSettings.shared
        appearance = settings.appearance
        fontFamily = settings.fontFamily
        fontSize = settings.fontSize
        sidebarVisible = settings.sidebarVisible
        sidebarMode = settings.sidebarMode
        compareEnabled = settings.compareEnabled
        splitRatio = settings.splitRatio
        bookLayout = settings.bookLayout
        book = BookPane()
        super.init()
        book.host = self
        // 書那欄的變化也要讓這個視窗的畫面（工具列、版面、側欄）重算
        bookObserver = book.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        // 對照開關沒有單一的寫入點（兩欄各自開檔、關檔都會改變它），所以盯著變化事件；
        // objectWillChange 在改之前發，等下一輪才讀得到新值
        linkObserver = objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.pushLinked() }
        }
    }

    private var linkObserver: AnyCancellable?
    private var sentLinked: [ObjectIdentifier: Bool] = [:]

    /// 兩欄各自要知道「點了會不會帶動另一欄」：會的話標題與引文的游標變手指（docs/SPEC.md 13.6）
    private func pushLinked() {
        // 心得那欄：對照中才帶得動書
        send(isComparing, to: self)
        // 書那欄：對照中，或只開書但對照開關開著（點標題會帶出那章的心得）
        send(isComparing || (documentURL == nil && compareEnabled && book.documentURL != nil), to: book)

        // 兩欄並排時按鍵綁目標不綁焦點：左右與空白翻書，其他捲心得。
        // tab 模式下另一欄看不見，不轉（docs/SPEC.md 13.5）
        let sideBySide = isComparing && !isTabbed
        if let bridge, bridge.isReady, sentForward != sideBySide {
            sentForward = sideBySide
            bridge.setForwardPageKeys(sideBySide)
        }
        // 書那欄只在翻頁模式轉，那由網頁端判斷
        if let b = book.bridge, b.isReady, sentForwardBook != sideBySide {
            sentForwardBook = sideBySide
            b.setForwardScrollKeys(sideBySide)
        }

        // Tab 切到另一欄：對照中才攔（並排切焦點、tab 模式切顯示哪一欄），
        // 只開一欄時交給網頁在連結之間跳
        for pane in panes {
            guard let b = pane.bridge, b.isReady, sentPaneSwitch[ObjectIdentifier(pane)] != isComparing else { continue }
            sentPaneSwitch[ObjectIdentifier(pane)] = isComparing
            b.setPaneSwitch(isComparing)
        }

        // 焦點欄外框：並排時一律顯示，上下鍵、搜尋、列印、標記都看焦點
        for pane in panes {
            let on = sideBySide && (focusedPane == .book) == (pane === book)
            guard let b = pane.bridge, b.isReady, sentFrame[ObjectIdentifier(pane)] != on else { continue }
            sentFrame[ObjectIdentifier(pane)] = on
            b.setFocusFrame(on)
        }
    }

    private var sentForward: Bool?
    private var sentForwardBook: Bool?
    private var sentFrame: [ObjectIdentifier: Bool] = [:]
    private var sentPaneSwitch: [ObjectIdentifier: Bool] = [:]

    /// Tab 切到另一欄：並排時切焦點，tab 模式切顯示哪一欄（跟 ⌃Tab 一樣）。
    /// 只改 `focusedPane` 不夠：按鍵送到哪個 WKWebView 看的是 first responder，
    /// 不交出去的話外框移到書，按 ↓ 收到的還是心得
    func switchFocusedPane() {
        guard isComparing else { return }
        let next: PaneSide = focusedPane == .book ? .note : .book
        if isTabbed { selectedTab = next } else { focusedPane = next }
        pane(next).bridge?.takeFocus()
    }

    /// 心得那欄轉過來的翻頁鍵。焦點留在心得，只把這一下交給書。
    func forwardPageKey(_ key: String, shift: Bool) {
        guard isComparing, !isTabbed else { return }
        book.bridge?.pageKey(key, shift: shift)
    }

    /// 書那欄（翻頁模式）轉過來的捲動鍵。焦點留在書，只把這一下交給心得。
    func forwardScrollKey(_ key: String) {
        guard isComparing, !isTabbed else { return }
        bridge?.scrollKey(key)
    }

    private func send(_ on: Bool, to pane: PaneDocument) {
        guard let bridge = pane.bridge, bridge.isReady, sentLinked[ObjectIdentifier(pane)] != on else { return }
        sentLinked[ObjectIdentifier(pane)] = on
        bridge.setLinked(on)
    }

    /// 某一欄的網頁端（重新）載入完成：之前送的狀態不算數
    func paneDidLoad(_ pane: PaneDocument) {
        sentLinked[ObjectIdentifier(pane)] = nil
        sentFrame[ObjectIdentifier(pane)] = nil
        sentPaneSwitch[ObjectIdentifier(pane)] = nil
        if pane === self { sentForward = nil } else { sentForwardBook = nil }
        pushLinked()
        deliverPendingFocus()
    }

    /// 開檔後鍵盤焦點要落在內文，方向鍵才能直接捲。新視窗的 first responder 預設是
    /// 側欄，不交出去的話要先點一下內文才有反應。新視窗的網頁還沒放進視窗、還沒
    /// ready 時交不出去，先記著，等 `paneDidLoad` / `attach` 再交
    private var pendingFocus: PaneSide?

    private func focusAfterOpen(_ side: PaneSide) {
        pendingFocus = side
        deliverPendingFocus()
    }

    private func deliverPendingFocus() {
        guard let side = pendingFocus, let b = pane(side).bridge, b.isReady else { return }
        // 晚一個 runloop 再交：同一輪 SwiftUI 更新裡交出去，可能被它指定的起始焦點蓋掉
        //（保險，沒實測過不延後的版本）
        DispatchQueue.main.async { [self] in
            guard pendingFocus == side, pane(side).bridge?.takeFocus() == true else { return }
            pendingFocus = nil
            if isTabbed { selectedTab = side } else { focusedPane = side }
        }
    }

    // MARK: - 視窗

    /// 視窗出現後才拿得到 `NSWindow`。
    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        pushAppearance()
        deliverPendingFocus()
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp?.activate()
    }

    /// 兩欄都沒有東西。
    var isEmpty: Bool { documentURL == nil && book.documentURL == nil }

    func isShowing(_ path: String) -> Bool {
        documentURL?.path == path || book.documentURL?.path == path
    }

    /// 焦點欄的 bridge。焦點欄沒開東西就退回有開的那一欄。
    var focusedBridge: WebBridge? {
        if focusedPane == .book, book.documentURL != nil, let b = book.bridge { return b }
        if documentURL != nil, let b = bridge { return b }
        return book.bridge ?? bridge
    }

    var focusedDocument: PaneDocument {
        focusedPane == .book && book.documentURL != nil ? book : self
    }

    // MARK: - 開檔

    /// 一律經過 `WindowRouter.open(_:in:)` 進來，那裡保證一檔一窗。
    /// 這是使用者指定的開檔（選單、Finder、側欄），開的那一邊成為主角。
    func open(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        let side: PaneSide = BookPairing.isBook(resolved) ? .book : .note
        if side == .book { openBookAsPrimary(resolved) } else { openNote(resolved, primary: true) }
        focusAfterOpen(side)
    }

    func openNote(_ url: URL, primary: Bool, then done: (() -> Void)? = nil) {
        if primary { primarySide = .note }
        loadDocument(url) { [self] in
            refreshPairing()
            done?()
        }
    }

    override func didOpen(_ url: URL) {
        settings.noteOpened(url, primary: true)
        bridge?.setDocumentDirectory(url.deletingLastPathComponent())
        refreshSiblings()
    }

    override func folderDidChange() {
        refreshSiblings()
        rebuildChapterMap()
    }

    override func didUnload() {
        siblings = []
        pairedBookURL = nil
    }

    override func renderContent(_ url: URL, keepScroll: Bool, highlights: [String: Any]?) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        bridge?.render(markdown: text, keepScroll: keepScroll, highlights: highlights)
        return true
    }

    override func pushInitialState() {
        if let url = documentURL { bridge?.setDocumentDirectory(url.deletingLastPathComponent()) }
        super.pushInitialState()
    }

    override func followRenamedDocument(to newURL: URL) {
        // 一檔一窗：新檔名若已經開在別的視窗，就交給那個視窗，這裡不重複開。
        // 不帶到前景 —— 改名多半是 AI 在背景做的，不該搶走焦點
        guard WindowRouter.shared.window(reading: newURL) == nil else { return }
        openNote(newURL, primary: false)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .epub, .pdf]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = (documentURL ?? book.documentURL)?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { WindowRouter.shared.open(url, in: self) }
    }

    /// 重新載入：兩欄都重讀。
    func reloadAll() {
        render(keepScroll: true)
        book.render(keepScroll: true)
    }

    // MARK: - 側欄

    private func refreshSiblings() {
        guard let url = documentURL else { siblings = []; return }
        siblings = BookPairing.markdownFiles(in: url.deletingLastPathComponent())
    }

    // MARK: - 配對與對照開關

    /// 能不能按「對照書籍」：有心得就能按（沒配對到書時按下去說明原因或讓人挑，
    /// docs/SPEC.md 13.2），只開了書則要書配對到心得。
    var canCompare: Bool {
        if documentURL != nil { return true }
        if book.documentURL != nil { return pairedNoteLocation != nil }
        return false
    }

    /// 按「對照書籍」不會直接打開書，而是先問使用者（挑候選或說明找不到）。
    var needsPairingPrompt: Bool { documentURL != nil && pairedBookURL == nil && !isComparing }

    /// 兩欄都在顯示。
    var isComparing: Bool { documentURL != nil && book.documentURL != nil }

    /// 心得換了之後重新決定左邊那本書。開關關著時不自動開，但仍算出配對結果給按鈕用。
    private func refreshPairing() {
        guard let note = documentURL else { return }
        pairedBookURL = BookPairing.match(forNote: note).book
        if compareEnabled, let paired = pairedBookURL {
            let opening = book.documentURL?.path != paired.path
            let saved = AppSettings.shared.bookPosition(for: paired)?["chapter"] as? Int
            showBook(paired) { [self] in
                // 書剛打開：上次讀到的地方就在這一章就回到那裡，否則（包括第一次打開）
                // 翻到心得這一章 —— 你打開第 5 章的心得，要看的是書的第 5 章
                guard opening else { return }
                rebuildChapterMap()
                let savedFile = saved.flatMap(mappedChapter).flatMap { chapterMap.targets[$0]?.file }
                if savedFile != note { syncBookToCurrentNote() }
            }
        } else if book.documentURL != nil, primarySide == .note {
            // 換到另一本書的心得（或沒有書的心得）：舊書收起來
            if book.documentURL != pairedBookURL || !compareEnabled { closeBook() }
        }
        rebuildChapterMap()
    }

    /// 把書放進左欄。書已經開在別的視窗就搬過來（docs/SPEC.md 13.7）。
    func showBook(_ url: URL, then done: (() -> Void)? = nil) {
        let resolved = url.resolvingSymlinksInPath()
        if book.documentURL?.path == resolved.path { done?(); return }
        WindowRouter.shared.takeBook(resolved, into: self) { [self] in
            book.loadDocument(resolved) {
                done?()
            }
        }
    }

    func closeBook() {
        guard book.documentURL != nil else { return }
        book.release { [self] in
            focusedPane = .note
            selectedTab = .note
            if documentURL == nil { pairedNoteLocation = nil }
        }
    }

    /// 書打開了（`BookPane` 通知）：算章節對應、單獨開書時找心得。
    func bookDidOpen() {
        guard let bookURL = book.documentURL else { return }
        if documentURL == nil {
            pairedNoteLocation = BookPairing.noteLocation(forBook: bookURL, title: book.title ?? "")
        }
        rebuildChapterMap()
    }

    /// PDF 的書籤是開檔之後網頁端才送來的，章節對應要重算
    func bookTocChanged() {
        rebuildChapterMap()
    }

    func bookDidUnload() {
        chapterMap = .empty
        pairedNoteLocation = nil
    }

    /// 選單、Finder 打開的是 EPUB 或 PDF：書是主角。
    private func openBookAsPrimary(_ url: URL) {
        primarySide = .book
        // 打開的就是目前心得配對的那本書：心得留著
        if documentURL != nil, pairedBookURL?.path == url.path {
            showBook(url)
            return
        }
        let proceed = { [self] in
            showBook(url) { [self] in
                settings.noteOpened(url, primary: true)
                if compareEnabled { openPairedNote() }
            }
        }
        if documentURL != nil { releaseNote(then: proceed) } else { proceed() }
    }

    /// 從書找心得：開上次在那個資料夾讀的檔；沒有紀錄就開書目前所在章對應的那份；
    /// 再沒有就開第一份（docs/SPEC.md 13.2）。
    private func openPairedNote() {
        guard documentURL == nil, let location = pairedNoteLocation else { return }
        let target: URL?
        if let single = location.single {
            target = single
        } else if let last = settings.lastNote(in: location.folder) {
            target = last
        } else if let chapter = book.currentChapter.flatMap(mappedChapter),
                  let mapped = chapterMap.targets[chapter]?.file {
            target = mapped
        } else {
            target = BookPairing.markdownFiles(in: location.folder).first
        }
        guard let target else { return }
        claimNote(target) { _ in }
    }

    /// 心得換成 `url`。開在別的視窗就搬過來、空掉的視窗關掉（docs/SPEC.md 13.7）。
    /// 回呼的參數是有沒有換成功。
    private func claimNote(_ url: URL, then done: @escaping (Bool) -> Void) {
        if documentURL?.path == url.path { done(true); return }
        WindowRouter.shared.takeNote(url, into: self) { [self] ok in
            guard ok else { done(false); return }
            openNote(url, primary: false) { done(true) }
        }
    }

    /// 心得交出去（被別的視窗接走、或打開別本書）。
    func releaseNote(then done: @escaping () -> Void) {
        guard documentURL != nil else { done(); return }
        release { [self] in
            focusedPane = .book
            selectedTab = .book
            done()
        }
    }

    func toggleCompare() {
        if needsPairingPrompt { resolvePairing(); return }
        guard canCompare || isComparing else { return }
        compareEnabled.toggle()
        if compareEnabled {
            if documentURL != nil, let paired = pairedBookURL { showBook(paired) }
            else if book.documentURL != nil { openPairedNote() }
        } else if isComparing {
            if primarySide == .book { releaseNote {} } else { closeBook() }
        }
    }

    /// 心得資料夾裡屬於同一本書的檔：h1 書名跟目前這份一樣的。
    /// 單檔心得常跟別本書的心得放在同一個資料夾，不能整個資料夾都拿來比。
    private func rebuildChapterMap() {
        guard book.epub != nil || book.pdf != nil else { chapterMap = .empty; return }
        let folder: URL
        var notes: [URL]
        if let note = documentURL {
            folder = note.deletingLastPathComponent()
            let key = BookPairing.noteBookTitle(note).map(EpubBook.titleKey)
            notes = BookPairing.markdownFiles(in: folder).filter {
                BookPairing.noteBookTitle($0).map(EpubBook.titleKey) == key
            }
            if notes.isEmpty { notes = [note] }
        } else if let location = pairedNoteLocation {
            notes = location.single.map { [$0] } ?? BookPairing.markdownFiles(in: location.folder)
        } else {
            chapterMap = .empty
            return
        }
        chapterMap = ChapterMap.build(toc: book.toc, notes: notes)
    }

    // MARK: - 手動指定對應書籍

    func chooseBookManually() {
        guard let note = documentURL else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "選擇「\(note.deletingLastPathComponent().lastPathComponent)」對應的書"
        panel.directoryURL = (pairedBookURL ?? note).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setBookPair(folder: note.deletingLastPathComponent(), book: url)
        compareEnabled = true
        refreshPairing()
    }

    /// 沒有自動配對到書：有候選就讓使用者挑，找不到就說明找過哪裡。
    /// 開心得時不跳，等使用者按「對照書籍」才問 —— 只想看心得時不該被打斷。
    private func resolvePairing() {
        guard let note = documentURL else { return }
        switch BookPairing.match(forNote: note) {
        case .found:
            compareEnabled = true
            refreshPairing()
        case .candidates(let books, let title, let prefix):
            pickBook(from: books, title: title, prefix: prefix, for: note)
        case .notFound(let title, let searched):
            explainNoBook(title: title, searched: searched)
        }
    }

    private func pickBook(from books: [URL], title: String, prefix: Bool, for note: URL) {
        let alert = NSAlert()
        // 比對用的是短書名，標題寫完整書名會讓人以為副標也比對過
        let short = EpubBook.shortTitle(title)
        alert.messageText = prefix ? "沒有書名完全是《\(short)》的書" : "《\(short)》有 \(books.count) 本"
        alert.informativeText = prefix
            ? "以下是書名開頭相符的書。選一本對照，之後這個資料夾的心得都用這本。"
            : "選一本對照，之後這個資料夾的心得都用這本。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 26), pullsDown: false)
        for book in books {
            popup.addItem(withTitle: book.deletingPathExtension().lastPathComponent)
            popup.lastItem?.toolTip = (book.path as NSString).abbreviatingWithTildeInPath
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "對照")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "指定其他書…")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            settings.setBookPair(folder: note.deletingLastPathComponent(), book: books[popup.indexOfSelectedItem])
            compareEnabled = true
            refreshPairing()
        case .alertThirdButtonReturn:
            chooseBookManually()
        default:
            break
        }
    }

    private func explainNoBook(title: String?, searched: [URL]) {
        let alert = NSAlert()
        if let title {
            alert.messageText = "找不到《\(title)》"
            let places = searched.isEmpty
                ? "心得往上四層都沒有含 EPUB 的資料夾，也還沒有加入書庫資料夾。"
                : "找過：\n" + searched.map { "• " + ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            alert.informativeText = "比對的書名是「\(EpubBook.shortTitle(title))」。\n\n" + places
        } else {
            alert.messageText = "這份心得取不到書名"
            alert.informativeText = "書名取自心得第一個 # 標題裡的《》，沒有《》就取整個標題。"
        }
        alert.addButton(withTitle: "指定對應書籍…")
        alert.addButton(withTitle: "加入書庫資料夾…")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            chooseBookManually()
        case .alertSecondButtonReturn:
            // 加入之後立刻重新比對；還是找不到就再說明一次，使用者自己按取消
            if LibraryFoldersPanel.chooseFolder() != nil { resolvePairing() }
        default:
            break
        }
    }

    var hasManualPair: Bool {
        guard let note = documentURL else { return false }
        return settings.bookPairs[note.deletingLastPathComponent().path] != nil
    }

    func clearManualPair() {
        guard let note = documentURL else { return }
        settings.setBookPair(folder: note.deletingLastPathComponent(), book: nil)
        refreshPairing()
    }

    // MARK: - 同步（docs/SPEC.md 13.6）

    /// 心得的標題被點（內文或側欄）：書捲到對應位置。
    func syncBook(fromNoteHeading id: String) {
        guard isComparing, let item = outline.first(where: { $0.id == id }),
              let (chapters, chapterTitle) = bookChapters(under: id) else { return }
        book.bridge?.syncTo(["chapters": chapters, "text": item.text, "quiet": item.level == 1 || chapterTitle,
                             "background": isTabbed && selectedTab != .book])
    }

    /// 心得的引文多半是書的原句：去書裡找那一段（docs/SPEC.md 13.6）
    func syncBook(fromQuote text: String, under headingID: String?) {
        // 對不到章也照樣找：書那邊找不到這一章就搜全書
        guard isComparing, documentURL != nil else { return }
        let chapters = bookChapters(under: headingID, silently: true)?.chapters ?? []
        book.bridge?.syncTo(["chapters": chapters, "quote": text,
                             "background": isTabbed && selectedTab != .book])
    }

    /// 心得某個位置（以它所在小節的標題代表）對到書的哪幾章，以及那個標題是不是章名本身。
    /// 對不到就提示（silently 時不提示）並回 nil。
    private func bookChapters(under id: String?, silently: Bool = false) -> (chapters: [Int], chapterTitle: Bool)? {
        guard let note = documentURL else { return nil }
        let mapped = chapterMap.chapters(in: note)
        guard !mapped.isEmpty else {
            if !silently { book.bridge?.toast("這一章在書裡找不到對應的章節") }
            return nil
        }
        // 單檔心得：往回找最近一個「是某一章章名」的標題
        let headed = mapped.filter { chapterMap.targets[$0]?.heading != nil }
        guard !headed.isEmpty else { return (mapped, false) }
        let index = id.flatMap { id in outline.firstIndex(where: { $0.id == id }) }
        for h in (index.map { outline[...$0] } ?? []).reversed() {
            let key = ChapterMap.normalize(h.text)
            if let c = headed.first(where: { chapterMap.targets[$0]?.heading.map(ChapterMap.normalize) == key }) {
                return ([c], h.id == id)
            }
        }
        if !silently { book.bridge?.toast("這一節之前沒有對應的章節") }
        return nil
    }

    /// 書翻到目前這份心得的那一章（章首）。
    private func syncBookToCurrentNote() {
        guard let note = documentURL else { return }
        let chapters = chapterMap.chapters(in: note)
        guard let first = chapters.first else { return }
        book.queueSync(["chapters": [first], "text": NSNull(), "quiet": true, "background": true])
    }

    /// 書的標題被點：心得換到那一章、捲到對應的標題。
    /// 目錄的子項目（「1.1 投資組合存續年數」）多半對不到心得，往上找有對應的上層章。
    private func mappedChapter(_ chapter: Int) -> Int? {
        let toc = book.toc
        guard chapter >= 0, chapter < toc.count, chapter < chapterMap.targets.count else { return nil }
        if chapterMap.targets[chapter] != nil { return chapter }
        var level = toc[chapter].level
        var i = chapter - 1
        while i >= 0 && level > 1 {
            if toc[i].level < level {
                if chapterMap.targets[i] != nil { return i }
                level = toc[i].level
            }
            i -= 1
        }
        return nil
    }

    func syncNote(fromBookChapter chapter: Int, text: String?, quiet: Bool) {
        guard let mapped = mappedChapter(chapter), let target = chapterMap.targets[mapped] else {
            if text != nil { book.bridge?.toast("這一章還沒有心得") }
            return
        }
        // 只有書、沒有心得：對照開關關著就不換
        if documentURL == nil && !compareEnabled { return }
        let request: [String: Any] = [
            "scope": target.heading ?? NSNull(),
            "text": text ?? NSNull(),
            "quiet": quiet || text == nil,
            "background": isTabbed && selectedTab != .note,
        ]
        if documentURL?.path == target.file.path {
            bridge?.syncTo(request)
            return
        }
        // 換檔：渲染完再同步
        claimNote(target.file) { [self] ok in
            if ok { queueSync(request) }
            else { book.bridge?.toast("那章的心得開在其他視窗") }
        }
    }

    /// 固定版面翻頁跨過章界：心得自動換到那一章（docs/SPEC.md 13.9）。
    func bookChapterTurned(to chapter: Int) {
        guard isComparing, let mapped = mappedChapter(chapter), let target = chapterMap.targets[mapped] else { return }
        if documentURL?.path == target.file.path && target.heading == nil { return }
        syncNote(fromBookChapter: mapped, text: nil, quiet: true)
    }

    // MARK: - 關窗

    override func prepareToClose() {
        super.prepareToClose()
        book.prepareToClose()
    }

    // MARK: - 字級

    func bumpFontSize(_ delta: Double) {
        fontSize = min(40, max(10, (fontSize + delta).rounded()))
    }

    func resetFontSize() { fontSize = AppSettings.defaultFontSize }

    // MARK: - 外觀

    /// `auto` 要問系統現在是哪一種，其餘直接用。
    /// 系統的明暗問 `NSApp` 而不是視窗：視窗的外觀是我們自己透過 `preferredColorScheme`
    /// 決定的，讀回來只會拿到自己設的值。
    var resolvedAppearance: String {
        guard appearance == "auto" else { return appearance }
        return systemIsDark ? "dark" : "light"
    }

    /// 系統目前的明暗。`auto` 的視窗靠它決定 `colorScheme`，系統切換時由
    /// `AppSettings` 聽到通知後呼叫 `systemAppearanceChanged()` 更新。
    @Published private var systemIsDark = DocumentState.readSystemIsDark()

    private static func readSystemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func systemAppearanceChanged() {
        systemIsDark = Self.readSystemIsDark()
        pushAppearance()
    }

    /// 視窗外框（側欄、工具列、標題列）的明暗交給 SwiftUI 的 `preferredColorScheme`，
    /// 掛在 `DocumentWindow` 上，每個視窗各自一份。
    ///
    /// 不要自己設 `NSWindow.appearance`：`WindowGroup` 的視窗由 SwiftUI 管，它每次
    /// 更新環境都會把 `appearance` 寫回它認定的值（沒有 preferredColorScheme 就是 nil），
    /// 同時把自己算出的明暗寫進託管的每個 AppKit view。兩邊搶同一個屬性，來回切幾次
    /// 標題列、側欄、內文就各自卡在不同的明暗，關掉側欄重開也救不回來。
    ///
    /// `auto` 也不交 nil，而是交系統目前的明暗：從 `.light` 改回 nil 時，SwiftUI
    /// 不會收回已經寫進側欄的淺色，側欄就卡在淺色（實測淺色 → 自動必中）。
    var colorScheme: ColorScheme {
        resolvedAppearance == "dark" ? .dark : .light
    }


    func pushAppearance() {
        let mode = resolvedAppearance
        panes.forEach { $0.bridge?.setAppearance(mode) }
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

    // MARK: - 網頁端的互動

    override func headingClicked(id: String, text: String, level: Int, chapter: Int?, isChapterTitle: Bool) {
        syncBook(fromNoteHeading: id)
    }

    override func quoteClicked(text: String, headingID: String?) {
        syncBook(fromQuote: text, under: headingID)
    }
}

/// Swift 對網頁端說話的介面，由 WebPane 的 Coordinator 實作。一欄一份。
@MainActor
protocol WebBridge: AnyObject {
    var isReady: Bool { get }

    func setAppearance(_ mode: String)
    func setFontFamily(_ name: String)
    func setFontSize(_ px: Double)
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

    // 書與同步（docs/SPEC.md 13.10）
    func setBook(_ book: BookResources?)
    func renderBook(_ payload: [String: Any], keepScroll: Bool, highlights: [String: Any]?)
    func renderBookError(_ text: String)
    func scrollToChapter(_ index: Int)
    func setBookLayout(_ mode: String)
    func syncTo(_ request: [String: Any])
    func setLinked(_ on: Bool)
    func setForwardPageKeys(_ on: Bool)
    func pageKey(_ key: String, shift: Bool)
    func setForwardScrollKeys(_ on: Bool)
    func scrollKey(_ key: String)
    func setFocusFrame(_ on: Bool)
    func setPaneSwitch(_ on: Bool)
    /// 交不出去（網頁還沒放進視窗）時回傳 false
    @discardableResult func takeFocus() -> Bool
    func revealPendingSync()
    func toast(_ text: String)
}
