import AppKit
import SwiftUI

/// 內容區：只有心得、只有書、或左書右心得（docs/SPEC.md 13.3）。
///
/// 兩個 `WebPane` 永遠留在同一個位置上，切雙欄、切 tab、拖分隔線都只改大小與透明度，
/// 不改視圖結構 —— 結構一變 SwiftUI 就會重建 WKWebView，捲動位置、搜尋、
/// 打到一半的註記全部消失。
struct ReadingArea: View {

    @ObservedObject var state: DocumentState
    @ObservedObject var book: BookPane

    private let dividerWidth: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let showBook = book.documentURL != nil
            let showNote = state.documentURL != nil || !showBook
            let both = showBook && showNote
            let tabbed = both && geo.size.width < DocumentState.splitThreshold

            VStack(spacing: 0) {
                if tabbed {
                    Picker("", selection: $state.selectedTab) {
                        Text("書").tag(PaneSide.book)
                        Text("心得").tag(PaneSide.note)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .help("切換書與心得　⌃Tab")
                }

                GeometryReader { inner in
                    let w = inner.size.width, h = inner.size.height
                    let bookW: CGFloat = both ? (tabbed ? w : (w * state.splitRatio).rounded()) : (showBook ? w : 0)
                    let noteX: CGFloat = both && !tabbed ? bookW + dividerWidth : 0
                    let noteW: CGFloat = both ? (tabbed ? w : w - bookW - dividerWidth) : (showNote ? w : 0)
                    let bookVisible = showBook && (!tabbed || state.selectedTab == .book)
                    let noteVisible = showNote && (!tabbed || state.selectedTab == .note)

                    ZStack(alignment: .topLeading) {
                        if showBook {
                            BookColumn(state: state, book: book)
                                .frame(width: max(bookW, 1), height: h)
                                .opacity(bookVisible ? 1 : 0)
                                .allowsHitTesting(bookVisible)
                        }

                        WebPane(state: state)
                            .frame(width: max(noteW, 1), height: h)
                            .offset(x: noteX)
                            .opacity(noteVisible ? 1 : 0)
                            .allowsHitTesting(noteVisible)

                        if both && !tabbed {
                            SplitHandle(ratio: $state.splitRatio, totalWidth: w, lineWidth: dividerWidth)
                                .frame(width: 9, height: h)
                                .offset(x: bookW - 4)
                        }
                    }
                    .frame(width: w, height: h, alignment: .topLeading)
                }
            }
            .task(id: tabbed) {
                state.isTabbed = tabbed
                // 窄到改成 tab 時，顯示剛才在操作的那一欄
                if tabbed { state.selectedTab = state.focusedPane }
            }
        }
    }
}

/// 分隔線。可拖，比例存成每個視窗的設定（新視窗沿用上次）。
private struct SplitHandle: View {

    @Binding var ratio: Double
    let totalWidth: CGFloat
    let lineWidth: CGFloat

    @State private var startRatio: Double?

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: lineWidth)
        }
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = startRatio ?? ratio
                    if startRatio == nil { startRatio = ratio }
                    guard totalWidth > 0 else { return }
                    let next = start + Double(value.translation.width / totalWidth)
                    ratio = min(0.8, max(0.2, next))
                }
                .onEnded { _ in startRatio = nil }
        )
    }
}

/// 書那一欄：頂端的章節下拉選單 ＋ 書的網頁。
private struct BookColumn: View {

    @ObservedObject var state: DocumentState
    @ObservedObject var book: BookPane

    var body: some View {
        VStack(spacing: 0) {
            // PDF 沒有書籤就不放下拉選單（docs/SPEC.md 13.13）
            if book.epub != nil || (book.pdf != nil && !book.pdfToc.isEmpty) {
                HStack(spacing: 8) {
                    BookChapterMenu(state: state, book: book)
                        .frame(height: 26)
                    // 捲動｜單頁｜雙頁（docs/SPEC.md 13.12）。固定版面的書「捲動」當作單頁。
                    // PDF 目前只有捲動模式
                    if book.epub != nil {
                        Picker("", selection: $state.bookLayout) {
                            ForEach(BookLayout.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .help("書的顯示方式：捲動、單頁、雙頁")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                Divider()
            }
            WebPane(state: book)
        }
    }
}

// MARK: - 書的目錄

/// 下拉選單與側欄共用的目錄列：全書的章，目前所在章展開它底下的小節（docs/SPEC.md 13.4）。
struct BookTocRow: Identifiable {
    enum Kind { case chapter(Int), heading(OutlineItem) }
    let id: String
    let kind: Kind
    let label: String
    let indent: Int
    /// 有對應心得的章
    let mapped: Bool
    let current: Bool
}

@MainActor
func bookTocRows(book: BookPane, map: ChapterMap) -> [BookTocRow] {
    let toc = book.toc
    var rows: [BookTocRow] = []
    let current = book.currentChapter
    for (i, entry) in toc.enumerated() {
        let mapped = i < map.targets.count && map.targets[i] != nil
        rows.append(BookTocRow(id: "c\(i)", kind: .chapter(i), label: entry.label,
                               indent: entry.level - 1, mapped: mapped, current: i == current))
        guard i == current else { continue }
        // 這一章的小節：章名本身（第一個標題）不重複列
        let headings = book.outline.filter { $0.chapter == i }.dropFirst()
        for item in headings {
            rows.append(BookTocRow(id: "h\(item.id)", kind: .heading(item), label: item.text,
                                   indent: entry.level + max(0, item.level - 2), mapped: mapped, current: false))
        }
    }
    return rows
}

/// 書那欄頂端的下拉選單。用 AppKit 的 NSMenu 做：要縮排、要把沒有心得的章變灰
/// 但仍然可以點（只捲書），SwiftUI 的 Menu 都做不到。
private struct BookChapterMenu: NSViewRepresentable {

    @ObservedObject var state: DocumentState
    @ObservedObject var book: BookPane

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        button.contentTintColor = .secondaryLabelColor
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.book = book
        coordinator.rows = bookTocRows(book: book, map: state.chapterMap)
        let toc = book.toc
        let current = book.currentChapter.flatMap { i in toc.indices.contains(i) ? toc[i].label : nil }
        button.title = current ?? book.title ?? ""
        button.toolTip = "跳到某一章；有圓點的章有對應的心得"
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var book: BookPane?
        var rows: [BookTocRow] = []

        @objc func show(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            // 一章都沒對到（單獨開書、沒有心得）就不分灰與圓點：全部變灰只會看不清楚，分不出什麼
            let anyMapped = rows.contains { $0.mapped }
            for (index, row) in rows.enumerated() {
                let item = NSMenuItem(title: row.label, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.indentationLevel = min(row.indent, 15)
                item.state = row.current ? .on : .off
                let isHeading: Bool
                if case .heading = row.kind { isHeading = true } else { isHeading = false }
                let title = NSMutableAttributedString()
                if !isHeading && anyMapped {
                    // 有心得的章標一個圓點；沒有的變灰，但仍可點（只捲書）
                    title.append(NSAttributedString(string: row.mapped ? "● " : "　",
                                                    attributes: [.foregroundColor: NSColor.systemOrange,
                                                                 .font: NSFont.systemFont(ofSize: 9)]))
                }
                title.append(NSAttributedString(string: row.label, attributes: [
                    // tertiary 在深色選單上淡到讀不出來，用 secondary
                    .foregroundColor: row.mapped || isHeading || !anyMapped ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: isHeading ? 12 : 13),
                ]))
                item.attributedTitle = title
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pick(_ item: NSMenuItem) {
            guard let book, item.tag < rows.count else { return }
            switch rows[item.tag].kind {
            case .chapter(let i): book.selectChapter(i)
            case .heading(let h): book.selectHeading(h)
            }
        }
    }
}

/// 單獨開書時側欄下半的目錄。
struct BookContents: View {

    @ObservedObject var state: DocumentState
    @ObservedObject var book: BookPane

    var body: some View {
        if book.pdf != nil && book.pdfTocLoaded && book.pdfToc.isEmpty {
            Text("沒有目錄")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        ForEach(bookTocRows(book: book, map: state.chapterMap)) { row in
            let isHeading: Bool = { if case .heading = row.kind { return true } else { return false } }()
            Text(row.label)
                .lineLimit(2)
                .font(.system(size: isHeading ? 11 : 12))
                .foregroundStyle(row.current ? Color.accentColor : (isHeading ? Color.secondary : Color.primary))
                .padding(.leading, CGFloat(row.indent) * 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    switch row.kind {
                    case .chapter(let i): book.selectChapter(i)
                    case .heading(let h): book.selectHeading(h)
                    }
                }
                // 只開書時，對照開關開著才會帶出心得
                .modifier(LinkCursor(active: state.compareEnabled))
        }
    }
}
