import AppKit
import SwiftUI
import WebKit

struct WebPane: NSViewRepresentable {

    /// 這一欄的文件：心得（`DocumentState`）或書（`BookPane`）。
    @ObservedObject var state: PaneDocument

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.schemeHandler,
                                   forURLScheme: ResourceSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "mb")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = NSColor(red: 0x1C / 255.0, green: 0x1C / 255.0,
                                                   blue: 0x1C / 255.0, alpha: 1)
        webView.allowsMagnification = false

        // 開發時可以右鍵「檢查元件」。Release 版也留著，這是自用工具。
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        context.coordinator.webView = webView
        state.bridge = context.coordinator

        webView.load(URLRequest(url: ResourceSchemeHandler.indexURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: -

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WebBridge {

        let schemeHandler = ResourceSchemeHandler()
        weak var webView: WKWebView?

        private let state: PaneDocument
        private var ready = false

        var isReady: Bool { ready }

        init(state: PaneDocument) {
            self.state = state
        }

        // MARK: JS → Swift

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            handle(type: type, body: body)
        }

        private func handle(type: String, body: [String: Any]) {
            switch type {
            case "ready":
                ready = true
                state.pushInitialState()

            case "outline":
                let raw = body["outline"] as? [[String: Any]] ?? []
                state.setOutline(raw.compactMap { item in
                    guard let id = item["id"] as? String,
                          let level = item["level"] as? Int,
                          let text = item["text"] as? String else { return nil }
                    return OutlineItem(id: id, level: level, text: text, chapter: item["chapter"] as? Int)
                })

            case "activeHeading":
                state.activeHeadingID = body["id"] as? String

            case "openExternal":
                if let s = body["url"] as? String, let url = URL(string: s) {
                    state.openExternal(url)
                }

            case "highlights":
                let raw = body["items"] as? [[String: Any]] ?? []
                state.setHighlights(doc: body["doc"] as? String ?? "", items: raw.compactMap(HighlightItem.init))

            case "saveHighlights":
                // json 是 null 代表標記全刪光了，要刪檔
                guard let doc = body["doc"] as? String else { return }
                state.saveHighlights(doc: doc, json: body["json"] as? String)

            case "copy":
                // 不用 navigator.clipboard：網頁從自訂的 mbres:// 載入，WebKit 不一定當它是安全來源
                if let text = body["text"] as? String { state.copyToPasteboard(text) }

            case "bannerAction":
                if let id = body["id"] as? String { state.handleBannerAction(id) }

            case "headingClicked":
                guard let id = body["id"] as? String, let text = body["text"] as? String else { return }
                state.headingClicked(id: id, text: text, level: body["level"] as? Int ?? 1,
                                     chapter: body["chapter"] as? Int,
                                     isChapterTitle: body["chapterTitle"] as? Bool ?? false)

            case "quoteClicked":
                guard let text = body["text"] as? String else { return }
                state.quoteClicked(text: text, headingID: body["heading"] as? String)

            case "bookPosition":
                state.positionChanged(body)

            case "focus":
                // 最後點過的那一欄是焦點欄（docs/SPEC.md 13.3）
                state.windowState?.focusedPane = state is BookPane ? .book : .note

            default:
                break
            }
        }

        // MARK: Swift → JS

        private func eval(_ js: String) {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// 把 Swift 字串安全地變成 JS 字面值。心得檔裡有反引號、`${`、
        /// 全形標點與換行，字串拼接一定要走 JSON 編碼。
        private func literal(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(json.dropFirst().dropLast())
        }

        /// 任意 JSON 值變成 JS 字面值。
        private func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return text
        }

        /// 標記跟內文在同一次呼叫裡送進去，畫面上不會先閃一下沒畫線的版本。
        /// `highlights` 為 nil 是重載同一份文件：網頁端沿用記憶體裡的標記。
        func render(markdown: String, keepScroll: Bool, highlights: [String: Any]?) {
            guard ready else { return }
            let extra = highlights.map { ", highlights: \(json($0))" } ?? ""
            eval("MB.render(\(literal(markdown)), {keepScroll: \(keepScroll)\(extra)})")
        }

        func setHighlights(_ payload: [String: Any]) {
            guard ready else { return }
            eval("MB.setHighlights(\(json(payload)))")
        }

        func setHighlightBanner(_ text: String?, actions: [(String, String)]) {
            guard ready else { return }
            let list = actions.map { ["id": $0.0, "label": $0.1] }
            eval("MB.setHighlightBanner(\(text.map(literal) ?? "null"), \(json(list)))")
        }

        func revealHighlight(_ id: String) { eval("MB.revealHighlight(\(literal(id)))") }
        func deleteHighlight(_ id: String) { eval("MB.deleteHighlight(\(literal(id)))") }

        func highlightSelection(completion: @escaping (Bool) -> Void) {
            guard ready, let webView else { completion(false); return }
            webView.evaluateJavaScript("MB.highlightSelection()") { result, _ in
                completion(result as? Bool ?? false)
            }
        }

        /// 回傳寫入的 sidecar 內容。關窗、改名時網頁端可能來不及把訊息送到，
        /// Swift 拿這個回傳值自己寫。
        func commitNote(completion: @escaping (String?) -> Void) {
            guard ready, let webView else { completion(nil); return }
            webView.evaluateJavaScript("MB.commitNote()") { result, _ in
                completion(result as? String)
            }
        }

        func probeHighlights(_ candidates: [[String: String]],
                             completion: @escaping ([(name: String, matched: Int, total: Int)]) -> Void) {
            // 網頁端還沒準備好就不回呼：開檔時會先走一次這裡，等 ready 之後的那次渲染才真的問
            guard ready, let webView else { return }
            webView.evaluateJavaScript("MB.probeHighlights(\(json(candidates)))") { result, _ in
                let rows = result as? [[String: Any]] ?? []
                completion(rows.compactMap { row in
                    guard let name = row["name"] as? String,
                          let matched = row["matched"] as? Int,
                          let total = row["total"] as? Int else { return nil }
                    return (name, matched, total)
                })
            }
        }

        func setTheme(_ name: String) { eval("MB.setTheme(\(literal(name)))") }
        func setFontFamily(_ name: String) { eval("MB.setFontFamily(\(literal(name)))") }
        func setAppearance(_ mode: String) { eval("MB.setAppearance(\(literal(mode)))") }
        func setFontSize(_ px: Double) { eval("MB.setFontSize(\(px))") }
        func setUserTheme(_ css: String) { eval("MB.setUserTheme(\(literal(css)))") }
        func setUserFonts(_ css: String) { eval("MB.setUserFonts(\(literal(css)))") }
        func scrollToHeading(_ id: String) { eval("MB.scrollToHeading(\(literal(id)))") }
        func openFind() { eval("MB.openFind()") }
        func findNext() { eval("MB.findNext()") }
        func findPrev() { eval("MB.findPrev()") }

        func setDocumentDirectory(_ url: URL) {
            schemeHandler.documentDirectory = url
        }

        // MARK: 書與同步

        func setBook(_ book: EpubBook?) {
            schemeHandler.book = book
        }

        func renderBook(_ payload: [String: Any], keepScroll: Bool, highlights: [String: Any]?) {
            guard ready else { return }
            let extra = highlights.map { ", highlights: \(json($0))" } ?? ""
            eval("MB.renderBook(\(json(payload)), {keepScroll: \(keepScroll)\(extra)})")
        }

        func renderBookError(_ text: String) {
            guard ready else { return }
            eval("MB.renderBookError(\(literal(text)))")
        }

        func scrollToChapter(_ index: Int) { eval("MB.scrollToChapter(\(index))") }
        func setBookLayout(_ mode: String) { eval("MB.setBookLayout(\(literal(mode)))") }
        func syncTo(_ request: [String: Any]) { eval("MB.syncTo(\(json(request)))") }
        func revealPendingSync() { eval("MB.revealPendingSync()") }
        func toast(_ text: String) { eval("MB.toast(\(literal(text)))") }

        func printDocument() {
            guard let webView else { return }
            let info = NSPrintInfo.shared
            info.topMargin = 36
            info.bottomMargin = 36
            info.leftMargin = 32
            info.rightMargin = 32
            info.horizontalPagination = .fit
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false

            let op = webView.printOperation(with: info)
            op.showsPrintPanel = true
            op.showsProgressPanel = true
            op.view?.frame = webView.bounds
            op.run()
        }
    }
}
