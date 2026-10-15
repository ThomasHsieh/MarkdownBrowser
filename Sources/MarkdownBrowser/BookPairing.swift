import Foundation

/// 書與心得的配對（docs/SPEC.md 13.2）。
///
/// 配對是開檔當下用書名算出來的，不是書庫 —— 沒有書目清單、不掃描整個磁碟。
/// 只有比對不到時手動指定的那幾筆存在 UserDefaults（`AppSettings.bookPairs`）。
@MainActor
enum BookPairing {

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]

    static func isEpub(_ url: URL) -> Bool { url.pathExtension.lowercased() == "epub" }

    static func isMarkdown(_ url: URL) -> Bool { markdownExtensions.contains(url.pathExtension.lowercased()) }

    // MARK: - 從心得找書

    static func book(forNote note: URL) -> URL? {
        let folder = note.deletingLastPathComponent()
        if let manual = AppSettings.shared.bookPairs[folder.path],
           FileManager.default.fileExists(atPath: manual) {
            return URL(fileURLWithPath: manual)
        }
        guard let library = libraryFolder(above: folder) else { return nil }

        // 心得 h1 的《》書名優先；資料夾名稱（書 A/）當後備
        var keys: [String] = []
        if let title = noteBookTitle(note) { keys.append(EpubBook.titleKey(title)) }
        if folder.path != library.path { keys.append(EpubBook.titleKey(folder.lastPathComponent)) }
        keys = keys.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }

        let books = epubs(in: library)
        // dc:title 對不到才退回比對檔名
        if let hit = books.first(where: { keys.contains(EpubBook.titleKey(title(of: $0))) }) { return hit }
        return books.first { keys.contains(EpubBook.titleKey($0.deletingPathExtension().lastPathComponent)) }
    }

    /// 心得 h1 裡的書名。h1 可能是「閱讀筆記：《書 B》進度」，所以有《》就只取裡面。
    static func noteBookTitle(_ note: URL) -> String? {
        guard let h1 = firstHeading(of: note) else { return nil }
        if let open = h1.firstIndex(of: "《"), let close = h1[open...].firstIndex(of: "》"), open < close {
            return String(h1[h1.index(after: open)..<close])
        }
        return h1
    }

    /// 從心得所在資料夾往上找，第一層含有 `.epub` 的資料夾就是書庫位置。
    /// 最多往上四層、不越過家目錄，避免一路掃到根目錄。
    static func libraryFolder(above folder: URL) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var current = folder.standardizedFileURL
        for _ in 0..<5 {
            if !epubs(in: current).isEmpty { return current }
            if current.path == home || current.path == "/" { return nil }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func epubs(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter(isEpub).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `dc:title` 的快取。每次開心得都要比對整個書庫的書名，打開十幾個 ZIP 讀 OPF 不划算。
    private static var titleCache: [String: (date: Date, title: String)] = [:]

    static func title(of epub: URL) -> String {
        let date = (try? epub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let hit = titleCache[epub.path], hit.date == date { return hit.title }
        let title = (try? EpubBook(url: epub))?.title ?? epub.deletingPathExtension().lastPathComponent
        titleCache[epub.path] = (date, title)
        return title
    }

    // MARK: - 從書找心得

    /// 回傳心得所在的資料夾（或單檔心得本身）。從 Finder 單獨開書時用。
    static func noteLocation(forBook book: URL, title: String) -> (folder: URL, single: URL?)? {
        let path = book.standardizedFileURL.path
        // 手動指定的對應也反查
        if let folder = AppSettings.shared.bookPairs.first(where: { $0.value == path })?.key {
            return (URL(fileURLWithPath: folder), nil)
        }

        let keys = Set([EpubBook.titleKey(title), EpubBook.titleKey(book.deletingPathExtension().lastPathComponent)]
            .filter { !$0.isEmpty })
        let root = book.deletingLastPathComponent()

        // 底下兩層內：資料夾名稱相符優先，其次是 h1 書名相符的單檔心得
        var folders: [URL] = [root]
        var singles: [URL] = []
        let level1 = subfolders(of: root)
        folders += level1
        for dir in level1 { folders += subfolders(of: dir) }

        for dir in folders where dir != root && keys.contains(EpubBook.titleKey(dir.lastPathComponent)) {
            if markdownFiles(in: dir).isEmpty == false { return (dir, nil) }
        }
        for dir in folders {
            for file in markdownFiles(in: dir) {
                if let t = noteBookTitle(file), keys.contains(EpubBook.titleKey(t)) { singles.append(file) }
            }
        }
        guard let first = singles.first else { return nil }
        // 同一個資料夾裡有好幾份都屬於這本書，就當資料夾處理（按章分檔但資料夾名稱不同）
        let dir = first.deletingLastPathComponent()
        if singles.filter({ $0.deletingLastPathComponent() == dir }).count > 1 { return (dir, nil) }
        return (dir, first)
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    static func markdownFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return ChapterSort.sorted(items.filter(isMarkdown))
    }

    // MARK: - 讀心得的開頭

    static func firstHeading(of file: URL) -> String? {
        guard let head = readHead(of: file) else { return nil }
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return ChapterMap.stripInline(String(t.dropFirst(2))) }
        }
        return nil
    }

    /// 只讀前 4 KB：找 h1 用不到整份檔。
    private static func readHead(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        // 切在 UTF-8 字元中間也沒關係，丟掉最後幾個位元組再解
        for drop in 0..<4 {
            if let s = String(data: data.dropLast(drop), encoding: .utf8) { return s }
        }
        return nil
    }
}

/// 書的章 ↔ 心得的檔（或單檔心得裡的標題）。docs/SPEC.md 13.6。
///
/// 章名比對為主：nav 的章名拿去比對心得開頭的 h1 與引言（「> 第 3 章　（章名）」）。
/// 開頭一條都對不到的檔（單檔心得）才比對它的各級標題。最後才退回章號。
struct ChapterMap {

    struct Target: Equatable {
        let file: URL
        /// 單檔心得裡那一章的標題文字；按章分檔時是 `nil`（捲到檔案開頭）
        let heading: String?
    }

    /// 與 `EpubBook.toc` 一一對應
    let targets: [Target?]

    static let empty = ChapterMap(targets: [])

    func chapters(in file: URL) -> [Int] {
        targets.indices.filter { targets[$0]?.file == file }
    }

    static func build(toc: [EpubBook.TocEntry], notes: [URL]) -> ChapterMap {
        let parsed = notes.map { NoteOutline(file: $0) }
        var targets = [Target?](repeating: nil, count: toc.count)
        var headerHit = Set<URL>()

        // 1. 開頭（h1 ＋ 引言）。同一個章名可能出現在好幾份的開頭（全書總結會順帶提到
        //    「作者的話、前言」），取章名佔那一行最多的那份 —— 專門講那一章的檔，
        //    引言那一行幾乎就是章名本身。兩個字的章名（「前言」「目錄」）太泛，
        //    只認 h1 結尾（「心得——前言」）。
        for (i, entry) in toc.enumerated() {
            let label = normalize(entry.label)
            guard label.count >= 2 else { continue }
            var best: (note: NoteOutline, score: Double)?
            for note in parsed {
                for (li, line) in note.header.enumerated() where line.contains(label) {
                    let atTitleEnd = li == 0 && line.hasSuffix(label)
                    guard label.count >= 3 || atTitleEnd else { continue }
                    let score = Double(label.count) / Double(max(line.count, 1)) + (atTitleEnd ? 0.5 : 0)
                    if score > (best?.score ?? 0) { best = (note, score) }
                }
            }
            if let best {
                targets[i] = Target(file: best.note.file, heading: nil)
                headerHit.insert(best.note.file)
            }
        }
        // 上層與下層對到同一份時留下層：「第一部（部名）」常寫在第一章心得的引言裡，
        // 留著它的話，還沒寫心得的第二章會往上找到第一部、跳去第一章的心得
        for i in toc.indices {
            guard let target = targets[i] else { continue }
            if descendants(of: i, in: toc).contains(where: { targets[$0]?.file == target.file }) { targets[i] = nil }
        }

        // 2. 開頭一條都沒對到的檔，比對各級標題（單檔心得）。
        //    上層已經對到的子項目（「3.1（小節名）」）不再比，交給上層 —— 否則會被
        //    心得裡另一章的同名標題搶走
        let singles = parsed.filter { !headerHit.contains($0.file) }
        for (i, entry) in toc.enumerated() where targets[i] == nil && !hasMappedAncestor(i, toc, targets) {
            let label = normalize(entry.label)
            let number = chapterNumber(entry.label)
            for note in singles {
                if let h = note.headings.first(where: { h in
                    let n = normalize(h)
                    if label.count >= 2, n.count >= 2, n.contains(label) || (n.count >= 4 && label.contains(n)) { return true }
                    // 翻譯版本不同，章名常對不上；同一個章號也算（「第 1 章」）
                    if let number, chapterNumber(h) == number { return true }
                    return false
                }) {
                    targets[i] = Target(file: note.file, heading: h)
                    break
                }
            }
        }

        // 3. 退回章號：nav 寫著第 N 章、心得檔名也是第 N 章
        for (i, entry) in toc.enumerated() where targets[i] == nil && !hasMappedAncestor(i, toc, targets) {
            guard let number = chapterNumber(entry.label) else { continue }
            if let note = parsed.first(where: { ChapterSort.chapterNumber(of: $0.file.lastPathComponent) == number }) {
                targets[i] = Target(file: note.file, heading: nil)
            }
        }
        return ChapterMap(targets: targets)
    }

    /// 目錄第 i 項底下的子項目：往後直到下一個同級或更上層的項目為止。
    private static func descendants(of i: Int, in toc: [EpubBook.TocEntry]) -> [Int] {
        var out: [Int] = []
        var j = i + 1
        while j < toc.count && toc[j].level > toc[i].level { out.append(j); j += 1 }
        return out
    }

    private static func hasMappedAncestor(_ i: Int, _ toc: [EpubBook.TocEntry], _ targets: [Target?]) -> Bool {
        var level = toc[i].level
        var j = i - 1
        while j >= 0 && level > 1 {
            if toc[j].level < level {
                if targets[j] != nil { return true }
                level = toc[j].level
            }
            j -= 1
        }
        return false
    }

    /// 比對用的正規化：去空白、去「第 X 章」、去標點符號，只留文字與數字。
    static func normalize(_ text: String) -> String {
        var s = text.lowercased().filter { !$0.isWhitespace }
        s = s.replacingOccurrences(of: "第[0-9０-９〇零一二三四五六七八九十百兩]+[章部篇節講課回卷]",
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(chapter|part|lesson)[0-9]+", with: "", options: .regularExpression)
        return String(s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(Character.init))
    }

    static func chapterNumber(_ text: String) -> Int? {
        let compact = text.filter { !$0.isWhitespace }
        guard let r = compact.range(of: "第[0-9０-９〇零一二三四五六七八九十百兩]+章", options: .regularExpression) else {
            if let r = compact.range(of: "(?i)chapter([0-9]+)", options: .regularExpression) {
                return Int(compact[r].filter(\.isNumber))
            }
            return nil
        }
        let body = String(compact[r].dropFirst().dropLast())
        let half = body.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? body
        return Int(half) ?? ChapterSort.chineseNumber(body)
    }

    /// 去掉行內 Markdown 記號，讓標題文字跟網頁端渲染後的 textContent 一樣。
    static func stripInline(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+)\*"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 一份心得的開頭與標題。
    private struct NoteOutline {
        let file: URL
        /// 正規化過的 h1 與緊接的引言行
        let header: [String]
        /// 原文（去掉行內記號），h1–h4
        let headings: [String]

        init(file: URL) {
            self.file = file
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var header: [String] = []
            var headings: [String] = []
            var inFence = false
            var inHeader = false
            var headerDone = false
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
                if inFence { continue }
                if let m = line.range(of: "^#{1,4}\\s+", options: .regularExpression) {
                    let h = ChapterMap.stripInline(String(line[m.upperBound...]))
                    headings.append(h)
                    if !headerDone && line.hasPrefix("# ") && !inHeader {
                        header.append(ChapterMap.normalize(h))
                        inHeader = true
                        continue
                    }
                }
                guard inHeader, !headerDone else { continue }
                if line.isEmpty { continue }
                if line.hasPrefix(">") {
                    header.append(ChapterMap.normalize(ChapterMap.stripInline(String(line.dropFirst()))))
                } else {
                    headerDone = true
                }
            }
            self.header = header
            self.headings = headings
        }
    }
}
