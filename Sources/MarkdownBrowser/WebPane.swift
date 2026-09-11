import AppKit
import SwiftUI
import WebKit

struct WebPane: NSViewRepresentable {

    @ObservedObject var state: AppState

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

        private let state: AppState
        private var ready = false

        init(state: AppState) {
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
                    return OutlineItem(id: id, level: level, text: text)
                })

            case "activeHeading":
                state.activeHeadingID = body["id"] as? String

            case "openExternal":
                if let s = body["url"] as? String, let url = URL(string: s) {
                    state.openExternal(url)
                }

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

        func render(markdown: String, keepScroll: Bool) {
            guard ready else { return }
            eval("MB.render(\(literal(markdown)), {keepScroll: \(keepScroll)})")
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
