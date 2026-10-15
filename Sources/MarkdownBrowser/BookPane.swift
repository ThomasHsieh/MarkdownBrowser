import AppKit
import Foundation

/// 書那一欄（docs/SPEC.md 第 13 節）。
///
/// 標記、sidecar、檔案監聽全部沿用 `PaneDocument`，跟心得那欄同一套規則 ——
/// sidecar 就是 EPUB 旁邊的 `<EPUB 檔名>_highlights.json`。這裡只多了「怎麼把一本
/// EPUB 送給網頁端」與閱讀位置。
@MainActor
final class BookPane: PaneDocument {

    /// 宿主視窗。書那欄沒有自己的主題、字體，都跟著視窗走。
    weak var host: DocumentState?

    @Published private(set) var epub: EpubBook?
    @Published private(set) var loadError: String?

    /// 目前所在章（`EpubBook.toc` 的索引），網頁端捲動時回報。
    @Published private(set) var currentChapter: Int?

    override var windowState: DocumentState? { host }

    // MARK: - 開檔

    override func didOpen(_ url: URL) {
        parse(url)
        currentChapter = (AppSettings.shared.bookPosition(for: url)?["chapter"] as? Int)
        host?.bookDidOpen()
    }

    override func didUnload() {
        epub = nil
        loadError = nil
        currentChapter = nil
        bridge?.setBook(nil)
        host?.bookDidUnload()
    }

    override func folderDidChange() {}

    private func parse(_ url: URL) {
        do {
            epub = try EpubBook(url: url)
            loadError = nil
        } catch {
            epub = nil
            loadError = error.localizedDescription
        }
    }

    override func renderContent(_ url: URL, keepScroll: Bool, highlights: [String: Any]?) -> Bool {
        guard let bridge else { return false }
        // 重載：翻譯 repo 重新打包了 EPUB，整本重新解析
        if keepScroll { parse(url); host?.bookDidOpen() }
        guard let epub else {
            bridge.renderBookError(loadError ?? "無法開啟這個 EPUB")
            return false
        }
        bridge.setBook(epub)
        bridge.renderBook(payload(for: epub, url: url), keepScroll: keepScroll, highlights: highlights)
        return true
    }

    override func followRenamedDocument(to newURL: URL) {
        if let old = documentURL, let position = AppSettings.shared.bookPosition(for: old) {
            AppSettings.shared.setBookPosition(position, for: newURL)
        }
        guard WindowRouter.shared.window(reading: newURL) == nil else { return }
        loadDocument(newURL)
    }

    /// 送給網頁端的整本書。可重排的書把每個 spine 檔的原文與所有 CSS 一次送過去，
    /// 網頁端串成一條；固定版面只送每頁的路徑與尺寸，頁面本身用 `mbres://book/` 載入。
    private func payload(for epub: EpubBook, url: URL) -> [String: Any] {
        var payload: [String: Any] = [
            "title": epub.title,
            "fixed": epub.fixedLayout,
            "rtl": epub.rightToLeft,
            "spread": epub.spread,
            "toc": epub.toc.map { entry -> [String: Any] in
                ["label": entry.label, "path": entry.path, "fragment": entry.fragment ?? NSNull(), "level": entry.level]
            },
            "position": AppSettings.shared.bookPosition(for: url) ?? NSNull(),
        ]
        if epub.fixedLayout {
            payload["pages"] = epub.spine.map { item -> [String: Any] in
                let size = epub.viewport(of: item.path)
                return ["path": item.path, "width": size.width, "height": size.height,
                        "spread": item.pageSpread ?? NSNull()]
            }
        } else {
            payload["spine"] = epub.spine.compactMap { item -> [String: Any]? in
                guard let text = epub.text(at: item.path) else { return nil }
                return ["path": item.path, "xhtml": text]
            }
            var css: [String: String] = [:]
            for path in epub.paths(withExtension: "css") { css[path] = epub.text(at: path) }
            payload["css"] = css
        }
        return payload
    }

    // MARK: - 網頁端的互動

    override func headingClicked(id: String, text: String, level: Int, chapter: Int?, isChapterTitle: Bool) {
        guard let chapter else { return }
        host?.syncNote(fromBookChapter: chapter, text: text, quiet: isChapterTitle)
    }

    /// 捲動或翻頁後回報。記下閱讀位置；固定版面翻頁跨章時讓心得跟著換。
    override func positionChanged(_ body: [String: Any]) {
        guard let url = documentURL else { return }
        let chapter = body["chapter"] as? Int
        let previous = currentChapter
        if chapter != currentChapter { currentChapter = chapter }
        if var position = body["position"] as? [String: Any], !position.isEmpty {
            // UserDefaults 存不了 NSNull，沒有章就不寫這個鍵
            position = position.filter { !($0.value is NSNull) }
            if let chapter { position["chapter"] = chapter }
            AppSettings.shared.setBookPosition(position, for: url)
        }
        if epub?.fixedLayout == true, body["turned"] as? Bool == true, let chapter, chapter != previous {
            host?.bookChapterTurned(to: chapter)
        }
    }

    /// 書的下拉選單選了某一章：書捲過去，心得跟著換到那一章。
    func selectChapter(_ index: Int) {
        bridge?.scrollToChapter(index)
        host?.syncNote(fromBookChapter: index, text: nil, quiet: true)
    }

    /// 下拉選單選了某個小節：等同點了那個標題。
    func selectHeading(_ item: OutlineItem) {
        bridge?.scrollToHeading(item.id)
        if let chapter = item.chapter {
            host?.syncNote(fromBookChapter: chapter, text: item.text, quiet: false)
        }
    }
}
