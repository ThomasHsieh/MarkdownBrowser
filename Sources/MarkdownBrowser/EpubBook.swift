import Foundation
import ZIPFoundation

/// 一本 EPUB：`container.xml` → OPF（書名、版面、spine）→ 目錄（nav 或 `toc.ncx`）。
///
/// 只讀不寫，也不解壓到暫存資料夾 —— 每個檔案要用時才從 ZIP 串流讀出來
/// （docs/SPEC.md 13.5）。ZIPFoundation 的 `Archive` 不是執行緒安全的，
/// 這整個 App 都在主執行緒，所以沒有另外加鎖。
final class EpubBook {

    struct TocEntry {
        let label: String
        /// ZIP 裡的路徑（已經相對 OPF 解開、去掉百分比編碼）
        let path: String
        let fragment: String?
        let level: Int
    }

    struct SpineItem {
        let path: String
        let linear: Bool
        /// `page-spread-left` / `page-spread-right`，固定版面排跨頁用
        let pageSpread: String?
    }

    enum OpenError: LocalizedError {
        case notEpub
        case drm

        var errorDescription: String? {
            switch self {
            case .notEpub: return "無法讀取這個 EPUB：找不到 OPF 或內容清單"
            case .drm: return "這本 EPUB 有 DRM 保護，無法開啟"
            }
        }
    }

    let url: URL
    let title: String
    let spine: [SpineItem]
    let toc: [TocEntry]
    let fixedLayout: Bool
    /// 固定版面是否允許跨頁。`rendition:spread` 沒寫等於 `auto`，交給閱讀器決定，這裡當作允許。
    let spread: Bool
    let rightToLeft: Bool
    /// OPF 宣告的固定版面尺寸，個別頁面沒寫 viewport 時用
    let defaultViewport: CGSize?

    private let archive: Archive

    init(url: URL) throws {
        self.url = url
        archive = try Archive(url: url, accessMode: .read)

        guard let container = Self.xml(archive, "META-INF/container.xml"),
              let opfPath = Self.strings(container, "//*[local-name()='rootfile']/@full-path").first,
              let opf = Self.xml(archive, opfPath) else { throw OpenError.notEpub }

        if Self.isEncrypted(archive) { throw OpenError.drm }

        let base = (opfPath as NSString).deletingLastPathComponent

        title = Self.strings(opf, "//*[local-name()='metadata']/*[local-name()='title']").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? url.deletingPathExtension().lastPathComponent

        // 清單：id → (路徑, properties)
        var manifest: [String: (path: String, properties: String, type: String)] = [:]
        for item in Self.elements(opf, "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = (Self.resolve(href, from: base).path,
                            item.attribute(forName: "properties")?.stringValue ?? "",
                            item.attribute(forName: "media-type")?.stringValue ?? "")
        }

        let layout = Self.strings(opf, "//*[local-name()='meta'][@property='rendition:layout']").first
        let spreadValue = Self.strings(opf, "//*[local-name()='meta'][@property='rendition:spread']").first
        spread = (spreadValue?.trimmingCharacters(in: .whitespaces) ?? "auto") != "none"
        defaultViewport = Self.strings(opf, "//*[local-name()='meta'][@property='rendition:viewport']").first
            .flatMap(Self.parseViewport)

        let spineNode = Self.elements(opf, "//*[local-name()='spine']").first
        rightToLeft = spineNode?.attribute(forName: "page-progression-direction")?.stringValue == "rtl"

        // linear="no" 的（彈出注釋之類）排到最後：連結還找得到，但不打斷閱讀順序
        var linear: [SpineItem] = [], extra: [SpineItem] = []
        var allPrePaginated = true
        for ref in Self.elements(opf, "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let idref = ref.attribute(forName: "idref")?.stringValue,
                  let item = manifest[idref] else { continue }
            let props = ref.attribute(forName: "properties")?.stringValue ?? ""
            let spreadProp = props.split(separator: " ").first { $0.hasPrefix("page-spread-") }.map(String.init)
            let isLinear = ref.attribute(forName: "linear")?.stringValue != "no"
            if !props.contains("rendition:layout-pre-paginated") { allPrePaginated = false }
            let entry = SpineItem(path: item.path, linear: isLinear, pageSpread: spreadProp)
            if isLinear { linear.append(entry) } else { extra.append(entry) }
        }
        spine = linear + extra
        fixedLayout = layout?.trimmingCharacters(in: .whitespaces) == "pre-paginated"
            || (allPrePaginated && !spine.isEmpty)
        guard !spine.isEmpty else { throw OpenError.notEpub }

        // 目錄：EPUB 3 的 nav 優先，沒有才用 EPUB 2 的 toc.ncx
        var entries: [TocEntry] = []
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let doc = Self.xml(archive, nav.path) {
            entries = Self.parseNav(doc, base: (nav.path as NSString).deletingLastPathComponent)
        }
        if entries.isEmpty {
            let ncx = spineNode?.attribute(forName: "toc")?.stringValue.flatMap { manifest[$0] }
                ?? manifest.values.first { $0.type == "application/x-dtbncx+xml" }
            if let ncx, let doc = Self.xml(archive, ncx.path) {
                entries = Self.parseNCX(doc, base: (ncx.path as NSString).deletingLastPathComponent)
            }
        }
        toc = entries
    }

    // MARK: - 讀檔

    func data(at path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var out = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { out.append($0) }
        } catch { return nil }
        return out
    }

    /// ZIP 裡所有某種副檔名的檔。書的 CSS 不一定都列在 OPF 清單裡，直接掃 ZIP。
    func paths(withExtension ext: String) -> [String] {
        archive.compactMap { entry in
            entry.type == .file && entry.path.lowercased().hasSuffix("." + ext) ? entry.path : nil
        }
    }

    func text(at path: String) -> String? {
        guard let data = data(at: path) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    /// 固定版面每一頁的尺寸，從頁面的 `<meta name="viewport">` 讀。沒寫就用 OPF 的，再沒有就猜直式。
    func viewport(of path: String) -> CGSize {
        if let text = text(at: path),
           let range = text.range(of: #"<meta[^>]*name\s*=\s*["']viewport["'][^>]*>"#, options: .regularExpression) {
            let tag = String(text[range])
            if let content = tag.range(of: #"content\s*=\s*["'][^"']*["']"#, options: .regularExpression),
               let size = Self.parseViewport(String(tag[content])) {
                return size
            }
        }
        return defaultViewport ?? CGSize(width: 1000, height: 1400)
    }

    // MARK: - 書名配對

    /// 短書名：切掉第一個「：」「:」「_」之後的部分，也去掉結尾的括號註記（「（修訂版）」）。
    /// 心得 h1 的書名時有時無副標，取短書名才對得起來（docs/SPEC.md 13.2）。
    static func shortTitle(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = s.firstIndex(where: { $0 == "：" || $0 == ":" || $0 == "_" }) {
            s = String(s[..<cut])
        }
        if let paren = s.range(of: #"[（(][^（()）]*[）)]\s*$"#, options: .regularExpression) {
            s.removeSubrange(paren)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 比對用的鍵：短書名去空白、轉小寫。
    static func titleKey(_ title: String) -> String {
        shortTitle(title).lowercased().filter { !$0.isWhitespace }
    }

    // MARK: - XML

    private static func xml(_ archive: Archive, _ path: String) -> XMLDocument? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        do { _ = try archive.extract(entry, skipCRC32: true) { data.append($0) } } catch { return nil }
        // 有些書的 XHTML 帶 HTML 實體（&nbsp;），嚴格的 XML 解析會失敗，退回寬鬆模式
        return (try? XMLDocument(data: data, options: []))
            ?? (try? XMLDocument(data: data, options: [.documentTidyXML]))
    }

    private static func elements(_ doc: XMLNode, _ xpath: String) -> [XMLElement] {
        ((try? doc.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }
    }

    private static func strings(_ doc: XMLNode, _ xpath: String) -> [String] {
        ((try? doc.nodes(forXPath: xpath)) ?? []).compactMap { $0.stringValue }
    }

    /// 相對路徑 → ZIP 裡的路徑與錨點。ZIP 裡的路徑沒有百分比編碼，href 有。
    static func resolve(_ href: String, from base: String) -> (path: String, fragment: String?) {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let raw = String(parts.first ?? "")
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        let decoded = raw.removingPercentEncoding ?? raw
        var stack = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        if decoded.isEmpty { return (stack.joined(separator: "/"), fragment) }
        for piece in decoded.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(piece))
            }
        }
        return (stack.joined(separator: "/"), fragment)
    }

    private static func parseViewport(_ text: String) -> CGSize? {
        func number(_ key: String) -> Double? {
            guard let r = text.range(of: key + #"\s*=\s*[0-9.]+"#, options: .regularExpression) else { return nil }
            return Double(text[r].split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
        }
        guard let w = number("width"), let h = number("height"), w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 只擋真正的 DRM。字型混淆（IDPF 與 Adobe 的兩種演算法）只是保護嵌入字型，
    /// 內文照樣讀得到 —— 很多正常的書都有。
    private static func isEncrypted(_ archive: Archive) -> Bool {
        if archive["META-INF/rights.xml"] != nil { return true }
        guard let doc = xml(archive, "META-INF/encryption.xml") else { return false }
        let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        let methods = strings(doc, "//*[local-name()='EncryptionMethod']/@Algorithm")
        return methods.contains { !fontObfuscation.contains($0) }
    }

    // MARK: - 目錄

    private static func parseNav(_ doc: XMLDocument, base: String) -> [TocEntry] {
        // epub:type="toc" 的那個 nav；沒標的話取第一個
        let navs = elements(doc, "//*[local-name()='nav']")
        let tocNav = navs.first { nav in
            (nav.attributes ?? []).contains { $0.localName == "type" && ($0.stringValue ?? "").split(separator: " ").contains("toc") }
        } ?? navs.first
        guard let tocNav else { return [] }

        var out: [TocEntry] = []
        func walk(_ list: XMLElement, level: Int) {
            for li in list.children ?? [] {
                guard let li = li as? XMLElement, li.localName == "li" else { continue }
                let link = li.children?.compactMap { $0 as? XMLElement }.first { $0.localName == "a" || $0.localName == "span" }
                if let link, link.localName == "a", let href = link.attribute(forName: "href")?.stringValue {
                    let label = (link.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    let target = resolve(href, from: base)
                    if !label.isEmpty { out.append(TocEntry(label: label, path: target.path, fragment: target.fragment, level: level)) }
                }
                for child in li.children ?? [] {
                    if let sub = child as? XMLElement, sub.localName == "ol" || sub.localName == "ul" { walk(sub, level: level + 1) }
                }
            }
        }
        for child in tocNav.children ?? [] {
            if let list = child as? XMLElement, list.localName == "ol" || list.localName == "ul" { walk(list, level: 1) }
        }
        return out
    }

    private static func parseNCX(_ doc: XMLDocument, base: String) -> [TocEntry] {
        var out: [TocEntry] = []
        func walk(_ parent: XMLElement, level: Int) {
            for child in parent.children ?? [] {
                guard let point = child as? XMLElement, point.localName == "navPoint" else { continue }
                let label = strings(point, "./*[local-name()='navLabel']/*[local-name()='text']").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let src = strings(point, "./*[local-name()='content']/@src").first, !label.isEmpty {
                    let target = resolve(src, from: base)
                    out.append(TocEntry(label: label, path: target.path, fragment: target.fragment, level: level))
                }
                walk(point, level: level + 1)
            }
        }
        if let map = elements(doc, "//*[local-name()='navMap']").first { walk(map, level: 1) }
        return out
    }
}
