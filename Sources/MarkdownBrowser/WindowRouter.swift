import AppKit
import Combine
import SwiftUI

/// 哪些視窗開著、哪一個在前景，以及「下一個檔案該開到哪裡」。
///
/// 多視窗之後，選單與 ⌘F 的按鍵監聽都需要知道現在作用中的是哪一個視窗，
/// 而 AppDelegate 與 `NSEvent` 監聽都在 SwiftUI 的 focus 環境之外拿不到，
/// 所以改用 `NSWindow` 的 key 通知自己記一份，來源唯一。
@MainActor
final class WindowRouter: ObservableObject {

    static let shared = WindowRouter()

    static let windowID = "document"

    /// 目前開著的視窗，依註冊順序。
    @Published private(set) var documents: [DocumentState] = []

    /// 前景視窗。選單項目的啟用狀態與動作對象都看它。
    @Published private(set) var active: DocumentState? {
        didSet { observeActive() }
    }

    /// SwiftUI 的開窗動作。App 結構之外（AppDelegate、按鍵監聽）拿不到
    /// `@Environment`，所以第一個視窗出現時把它存下來。
    var openWindow: OpenWindowAction?

    /// Finder 在第一個視窗出現之前就送來的檔。存著，等 `openWindow` 就緒再處理。
    private var pending: [URL] = []

    /// 剛開的視窗要讀哪個檔，由新視窗自己來取（`nil` 代表空白視窗）。
    ///
    /// `WindowGroup` 刻意不帶值 —— 帶值的版本會讓 SwiftUI 把「視窗在讀哪個檔」
    /// 存起來做視窗還原，而視窗內換檔要寫回那個值，寫回去又會被當成
    /// 「請開一個新視窗」，於是視窗數每次啟動都往上加。改成自己交棒。
    private var handoffs: [URL?] = []

    /// 內容被拆走、本體卻還留在畫面上的視窗（見 `closeOrphanWindows`）。
    private var orphanCandidates: [NSWindow] = []

    private var activeObserver: AnyCancellable?
    private var sweepGeneration = 0
    private var windowObservers: [UUID: [NSObjectProtocol]] = [:]
    private var didRestoreLastDocument = false

    private init() {}

    // MARK: - 註冊

    /// 視窗出現時呼叫。可重複呼叫 —— `WindowAccessor` 與 `onAppear` 誰先到不一定。
    func register(_ document: DocumentState) {
        if !documents.contains(where: { $0 === document }) {
            documents.append(document)
        }
        if active == nil { active = document }

        // 晚一個 runloop 再處理待開的檔 —— register 可能是在視窗掛上 SwiftUI
        // 的過程中被呼叫的，當場去開檔會撞進 SwiftUI 的更新週期裡。
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WindowRouter.shared.flushPending() }
        }
    }

    /// 掛上視窗本體。前景追蹤與關窗清理都靠這裡的通知。
    func attach(_ document: DocumentState, to window: NSWindow) {
        register(document)
        guard document.window !== window else { return }
        document.attach(window: window)

        windowObservers[document.id]?.forEach { NotificationCenter.default.removeObserver($0) }
        let center = NotificationCenter.default
        windowObservers[document.id] = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { WindowRouter.shared.active = document }
            },
            // 失焦就把打到一半的註記寫入：切去 cmux 叫 Claude 改檔時，字先落地，
            // 也堵住「另一個視窗拿舊清單寫回去」的競態
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { document.bridge?.commitNote { _ in } }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    document.prepareToClose()
                    WindowRouter.shared.unregister(document)
                }
            },
        ]
    }

    private func unregister(_ document: DocumentState) {
        windowObservers[document.id]?.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers[document.id] = nil
        documents.removeAll { $0 === document }
        if active === document { active = documents.last }

        if let window = document.window {
            orphanCandidates.append(window)
            scheduleOrphanSweep()
        }
    }

    /// `active` 自己的變化（開了檔、捲到哪個標題）也要讓選單重新計算啟用狀態。
    private func observeActive() {
        activeObserver = active?.objectWillChange.sink { _ in
            MainActor.assumeIsolated { WindowRouter.shared.objectWillChange.send() }
        }
    }

    // MARK: - 選單與側欄的開檔：用前景視窗

    /// 選單的「開啟…」「最近開啟」與側欄點擊都換掉前景視窗的內容 ——
    /// 那是使用者當下指定的動作。Finder 的開檔走 `openFromFinder`，政策不同。
    func openInActiveWindow(_ url: URL) {
        if let active {
            open(url, in: active)
        } else if let existing = window(reading: url) {
            existing.bringToFront()
        } else {
            openNewWindow(with: url)
        }
    }

    /// 在指定的視窗開檔，但**一檔一窗**：那個檔已經開在別的視窗，就把那個視窗
    /// 帶到前景，這個視窗不動。每個視窗的網頁端各自是標記資料的唯一真相，
    /// 同一個檔開兩份就會兩邊各寫各的、互相覆蓋（docs/SPEC.md 11.2）。
    func open(_ url: URL, in document: DocumentState) {
        if let existing = window(reading: url) {
            existing.bringToFront()
            return
        }
        document.open(url)
        document.bringToFront()
    }

    private func window(reading url: URL) -> DocumentState? {
        let path = url.resolvingSymlinksInPath().path
        return documents.first { $0.documentURL?.path == path }
    }

    func openPanel() {
        if let active { active.openPanel() } else { newWindow() }
    }

    func newWindow() {
        openNewWindow(with: nil)
    }

    /// 開一個新視窗。`url` 為 `nil` 就是空白視窗。
    ///
    /// 一個視窗都還沒有的時候不自己開窗，先存起來等。帶著檔案啟動時，
    /// AppKit 會叫 SwiftUI 收掉它預設開的那個視窗（啟動是為了開文件，
    /// 不是為了開空白視窗），而 Finder 的開檔請求剛好落在那個空檔裡 ——
    /// 這時搶著開窗，就會跟 SwiftUI 接著補上的那個視窗撞成兩個。
    private func openNewWindow(with url: URL?) {
        guard let openWindow, !documents.isEmpty else {
            if let url { pending.append(url) }
            return
        }
        // 先排進佇列再開窗，新視窗的 onAppear 會照順序取走 ——
        // 一次開多個檔時，每個視窗才會拿到自己那一個。
        handoffs.append(url)
        openWindow(id: Self.windowID)
    }

    /// 新視窗問：我要讀哪個檔？
    func takeHandoff() -> URL? {
        handoffs.isEmpty ? nil : handoffs.removeFirst()
    }

    // MARK: - Finder 的開檔：不動已經在讀的視窗

    /// Finder 雙點擊、`open` 指令、拖到 Dock 圖示都走這裡。
    ///
    /// **絕不覆蓋已經開著檔的視窗** —— 那正是單視窗版本的問題。
    /// 依序試：已經在讀這個檔的視窗帶到前景 → 還沒開檔的空白視窗載入它
    /// → 都沒有才開新視窗。
    func openFromFinder(_ urls: [URL]) {
        let resolved = urls.map { $0.resolvingSymlinksInPath() }
        for url in resolved { openFromFinder(url) }
        scheduleVerification(of: resolved, attempt: 1)
    }

    /// 確認檔案真的開在某個活著的視窗裡，沒有就重來。
    ///
    /// 開檔時 SwiftUI 會生一個視窗又馬上丟掉（見 `closeOrphanWindows`）。
    /// 那個視窗有機會在消失之前先被當成「還沒開檔的空白視窗」接下檔案，
    /// 或是先取走交棒佇列裡的檔 —— 兩種都會讓檔案跟著它一起消失。
    /// 誰先誰後只差幾毫秒（實測 2 ms），賭不起，所以晚一點回頭確認。
    private func scheduleVerification(of urls: [URL], attempt: Int) {
        guard attempt <= 3, !urls.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                let router = WindowRouter.shared
                let missing = urls.filter { url in
                    !router.documents.contains { $0.documentURL?.path == url.path }
                }
                guard !missing.isEmpty else { return }
                for url in missing { router.openFromFinder(url) }
                router.scheduleVerification(of: missing, attempt: attempt + 1)
            }
        }
    }

    private func openFromFinder(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()

        if let existing = documents.first(where: { $0.documentURL?.path == resolved.path }) {
            existing.bringToFront()
            return
        }

        if let empty = documents.first(where: { $0.documentURL == nil }) {
            empty.open(resolved)
            empty.bringToFront()
            return
        }

        openNewWindow(with: resolved)
    }

    /// 第一個視窗出現之前送來的檔，等 `openWindow` 就緒後補開。
    private func flushPending() {
        guard openWindow != nil, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        openFromFinder(urls)
    }

    // MARK: - 孤兒視窗

    /// 延遲收掉孤兒視窗。
    ///
    /// 要等，不能在關窗通知裡直接關 —— 那一刻視窗正在關，而且 SwiftUI
    /// 可能只是把內容搬到新視窗上，得讓它先跑完。
    private func scheduleOrphanSweep() {
        sweepGeneration += 1
        let generation = sweepGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.sweepGeneration else { return }
                self.closeOrphanWindows()
            }
        }
    }

    /// 收掉內容被拆走、本體卻留在畫面上的空殼視窗。
    ///
    /// 只要 App 收到開檔請求，SwiftUI 就會生一個視窗又馬上丟掉（帶著檔案啟動、
    /// 以及執行中被 Finder 要求開檔都會）。被丟掉的那個只是內容被拆走，視窗本體
    /// 還在畫面上，就疊在真正的視窗底下。
    ///
    /// 只關「本來有 DocumentState、現在沒有」的視窗，不掃全部 —— App 自己的
    /// 開檔對話框、關於視窗也都沒有 DocumentState，掃全部會把它們一起關掉。
    private func closeOrphanWindows() {
        let candidates = orphanCandidates
        orphanCandidates = []
        for window in candidates where window.isVisible {
            guard !documents.contains(where: { $0.window === window }) else { continue }
            window.close()
        }
    }

    // MARK: - 啟動還原

    /// 啟動時若沒有 Finder 指定的檔，把上次讀的那一份還原到空白視窗裡。
    ///
    /// Finder 的開檔請求會在 `applicationDidFinishLaunching` 之後才送到，
    /// 所以這件事要晚一步再決定。
    func restoreLastDocumentIfIdle() {
        guard !didRestoreLastDocument else { return }
        didRestoreLastDocument = true
        guard pending.isEmpty else { return }
        guard let document = documents.first, documents.allSatisfy({ $0.documentURL == nil }) else { return }
        guard let url = AppSettings.shared.lastDocumentURL else { return }
        document.open(url)
    }
}
