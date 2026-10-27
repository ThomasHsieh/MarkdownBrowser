import Foundation

/// 書與心得的配對（docs/SPEC.md 13.2）。
///
/// 配對是開檔當下用書名算出來的，不是書庫 —— 沒有書目清單、不掃描整個磁碟。
/// 只有比對不到時手動指定的那幾筆存在 UserDefaults（`AppSettings.bookPairs`）。
@MainActor
enum BookPairing {

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]

    static func isEpub(_ url: URL) -> Bool { url.pathExtension.lowercased() == "epub" }
    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
    /// 開在書那欄的檔
    static func isBook(_ url: URL) -> Bool { isEpub(url) || isPDF(url) }

    static func isMarkdown(_ url: URL) -> Bool { markdownExtensions.contains(url.pathExtension.lowercased()) }

    // MARK: - 從心得找書

    /// 從心得找書的結果。只有 `found` 會自動打開；其他兩種等使用者按「對照書籍」才處理。
    enum Match {
        case found(URL)
        /// 額外書庫裡有好幾本，或只有開頭相符（`prefix`）：要使用者挑
        case candidates([URL], title: String, prefix: Bool)
        /// `title` 是比對用的書名，取不到是 `nil`；`searched` 是找過的書庫
        case notFound(title: String?, searched: [URL])

        var book: URL? {
            if case .found(let url) = self { return url }
            return nil
        }
    }

    static func match(forNote note: URL) -> Match {
        let folder = note.deletingLastPathComponent()
        if let manual = AppSettings.shared.bookPairs[folder.path],
           FileManager.default.fileExists(atPath: manual) {
            return .found(URL(fileURLWithPath: manual))
        }
        let libraries = libraryFolders(above: folder)
        let libraryPaths = Set(libraries.map(\.path))

        // 心得 h1 的《》書名優先；資料夾名稱（書 A/）當後備
        let noteTitle = noteBookTitle(note)
        let titleKey = noteTitle.map(EpubBook.titleKey) ?? ""
        let folderKey = EpubBook.titleKey(folder.lastPathComponent)
        let extras = AppSettings.shared.libraryFolders.filter { !libraryPaths.contains($0.path) }
        let searched = libraries + extras
        guard !titleKey.isEmpty || !folderKey.isEmpty else { return .notFound(title: nil, searched: searched) }
        let title = noteTitle ?? folder.lastPathComponent

        // 往上找書庫：含 .epub 或 .pdf 的每一層都試，這層對不到就繼續往上 ——
        // 心得資料夾裡常有附件 PDF，停在那層會擋住上面真正的書庫（docs/SPEC.md 13.2 第 3 步）
        for library in libraries {
            // 資料夾名稱只在心得資料夾不是書庫本身時才算（書庫那層的名稱不是書名）
            let keys = [titleKey, library.path == folder.path ? "" : folderKey].filter { !$0.isEmpty }
            if let hit = match(keys: keys, in: library) { return .found(hit) }
        }
        let keys = [titleKey, folderKey].filter { !$0.isEmpty }

        // 額外書庫：只比檔名，不打開書（雲端硬碟上的佔位檔會被整批下載）
        let all = extras.flatMap { LibraryIndex.books(under: $0) }
        let exact = all.filter { keys.contains(fileKey($0)) }
        // 同一本書 EPUB 與 PDF 都有時 EPUB 優先（docs/SPEC.md 13.13）
        let preferred = exact.contains(where: isEpub) ? exact.filter(isEpub) : exact
        if preferred.count == 1 {
            AppSettings.shared.setAutoBookPair(folder: folder, book: preferred[0])
            return .found(preferred[0])
        }
        if !exact.isEmpty { return .candidates(exact, title: title, prefix: false) }
        // 檔名常把副標用兩個空白隔開，切不出短書名。開頭相符會多對到不相干的書，只當候選
        let prefixed = all.filter { file in keys.contains { $0.count >= 2 && fileKey(file).hasPrefix($0) } }
        if !prefixed.isEmpty { return .candidates(prefixed, title: title, prefix: true) }
        return .notFound(title: title, searched: searched)
    }

    /// 書庫那一層：EPUB 先比 `dc:title`、再比檔名；都對不到才看 PDF（同一層 EPUB 優先），
    /// PDF 的 Title 中繼資料或檔名任一相符就算（docs/SPEC.md 13.13）
    private static func match(keys: [String], in library: URL) -> URL? {
        guard !keys.isEmpty else { return nil }
        let files = books(in: library)
        let epubs = files.filter(isEpub)
        if let hit = epubs.first(where: { keys.contains(EpubBook.titleKey(self.title(of: $0))) }) { return hit }
        if let hit = epubs.first(where: { keys.contains(fileKey($0)) }) { return hit }
        return files.filter(isPDF).first { pdf in
            keys.contains(fileKey(pdf)) || keys.contains(EpubBook.titleKey(self.title(of: pdf)))
        }
    }

    static func fileKey(_ book: URL) -> String {
        EpubBook.titleKey(book.deletingPathExtension().lastPathComponent)
    }

    /// 心得 h1 裡的書名。h1 可能是「閱讀筆記：《書 B》進度」，所以有《》就只取裡面。
    static func noteBookTitle(_ note: URL) -> String? {
        guard let h1 = firstHeading(of: note) else { return nil }
        if let open = h1.firstIndex(of: "《"), let close = h1[open...].firstIndex(of: "》"), open < close {
            return String(h1[h1.index(after: open)..<close])
        }
        return h1
    }

    /// 從心得所在資料夾往上找，含有 `.epub` 或 `.pdf` 的每一層都是書庫候選，由近到遠。
    /// 最多往上四層、不越過家目錄，避免一路掃到根目錄。
    static func libraryFolders(above folder: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var current = folder.standardizedFileURL
        var found: [URL] = []
        for _ in 0..<5 {
            if !books(in: current).isEmpty { found.append(current) }
            if current.path == home || current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return found
    }

    private static func books(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter(isBook).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 書名（EPUB 的 `dc:title`、PDF 的 Title 中繼資料，都沒有就是檔名）的快取。
    /// 每次開心得都要比對整個書庫的書名，打開十幾個 ZIP 讀 OPF 不划算。
    private static var titleCache: [String: (date: Date, title: String)] = [:]

    static func title(of book: URL) -> String {
        let date = (try? book.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let hit = titleCache[book.path], hit.date == date { return hit.title }
        let parsed = isPDF(book) ? (try? PdfBook(url: book))?.title : (try? EpubBook(url: book))?.title
        let title = parsed ?? book.deletingPathExtension().lastPathComponent
        titleCache[book.path] = (date, title)
        return title
    }

    // MARK: - 從書找心得

    /// 回傳心得所在的資料夾（或單檔心得本身）。從 Finder 單獨開書時用。
    static func noteLocation(forBook book: URL, title: String) -> (folder: URL, single: URL?)? {
        let path = book.standardizedFileURL.path
        // 手動指定與自動配對紀錄也反查：額外書庫的書跟心得通常不在同一棵資料夾樹裡
        if let folder = AppSettings.shared.bookPairs.first(where: { $0.value == path })?.key
            ?? AppSettings.shared.liveAutoBookPairs().first(where: { $0.value == path })?.key {
            return (URL(fileURLWithPath: folder), nil)
        }

        let keys = Set([EpubBook.titleKey(title), fileKey(book)]
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

/// 額外書庫的檔名清單（docs/SPEC.md 13.2）。
///
/// 整個子樹遞迴、只列檔名。App 執行期間快取，記住每個子資料夾的修改時間 ——
/// 資料夾的修改時間只反映直屬那一層，只看最上層會漏掉 `已完讀/` 裡新增的書。
@MainActor
enum LibraryIndex {

    private struct Entry {
        var folderDates: [String: Date]
        var books: [URL]
    }

    private static var cache: [String: Entry] = [:]

    /// 子樹裡所有的 EPUB 與 PDF
    static func books(under root: URL) -> [URL] {
        if let hit = cache[root.path], isFresh(hit) { return hit.books }
        let entry = scan(root)
        cache[root.path] = entry
        return entry.books
    }

    private static func isFresh(_ entry: Entry) -> Bool {
        entry.folderDates.allSatisfy { path, date in
            modificationDate(of: URL(fileURLWithPath: path)) == date
        }
    }

    private static func scan(_ root: URL) -> Entry {
        var dates: [String: Date] = [:]
        var books: [URL] = []
        guard let rootDate = modificationDate(of: root) else { return Entry(folderDates: [:], books: []) }
        dates[root.path] = rootDate
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return Entry(folderDates: dates, books: []) }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if BookPairing.isBook(url) {
                books.append(url)
                // 解開的 EPUB 也是資料夾，裡面不用再走
                if values?.isDirectory == true { walker.skipDescendants() }
            } else if values?.isDirectory == true {
                dates[url.path] = values?.contentModificationDate ?? .distantPast
            }
        }
        books.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Entry(folderDates: dates, books: books)
    }

    private static func modificationDate(of folder: URL) -> Date? {
        (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// 書的章 ↔ 心得的檔（或單檔心得裡的標題）。docs/SPEC.md 13.6。
///
/// 章名比對為主：nav 的章名拿去比對心得開頭的 h1 與引言（「> 第 3 章　（章名）」）。
/// 開頭一條都對不到的檔（單檔心得）才比對它的各級標題。再來退回章號，最後才看重疊比例。
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
            let label = normalize(tocLabel(entry.label))
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
            let label = normalize(tocLabel(entry.label))
            let number = tocChapterNumber(entry.label)
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
            guard let number = tocChapterNumber(entry.label) else { continue }
            if let note = parsed.first(where: { ChapterSort.chapterNumber(of: $0.file.lastPathComponent) == number }) {
                targets[i] = Target(file: note.file, heading: nil)
            }
        }

        // 4. 最後才看重疊比例：目錄「推薦序　（篇名）／（作者）」、心得「推薦序一：（篇名）（作者）」
        //    多一個序號就不是包含關係。這種心得的檔頭常已對到別的項目（前言），第 2 步不會看它的標題，
        //    所以這裡所有心得的標題都比。門檻要高：至少 8 個字、佔章名八成，短章名不適用
        for (i, entry) in toc.enumerated() where targets[i] == nil && !hasMappedAncestor(i, toc, targets) {
            let label = normalize(tocLabel(entry.label))
            guard label.count >= 8 else { continue }
            var best: (target: Target, ratio: Double)?
            for note in parsed {
                for h in note.headings {
                    let ratio = Double(longestCommon(label, normalize(h))) / Double(label.count)
                    if ratio >= 0.8, ratio > (best?.ratio ?? 0) { best = (Target(file: note.file, heading: h), ratio) }
                }
            }
            if let best { targets[i] = best.target }
        }
        return ChapterMap(targets: targets)
    }

    /// 兩個字串最長的共同子字串有幾個字
    private static func longestCommon(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var row = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                row[j] = prev[j - 1] + 1
                best = max(best, row[j])
            }
            prev = row
        }
        return best
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

    /// 目錄的章名可能只用數字開頭當章號（「２　（章名）」「10　（章名）」），沒有「第…章」。
    /// 只用在目錄上：心得標題的「3 個原則」不是章號。數字後面要緊接空白，「3.1 （小節名）」不算
    private static let leadingNumber = "^\\s*[0-9０-９]+\\s+"

    static func tocLabel(_ label: String) -> String {
        guard let r = label.range(of: leadingNumber, options: .regularExpression), r.upperBound < label.endIndex else { return label }
        return String(label[r.upperBound...])
    }

    static func tocChapterNumber(_ label: String) -> Int? {
        if let n = chapterNumber(label) { return n }
        guard let r = label.range(of: leadingNumber, options: .regularExpression) else { return nil }
        let digits = label[r].filter { !$0.isWhitespace }
        return Int(digits.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? digits)
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
