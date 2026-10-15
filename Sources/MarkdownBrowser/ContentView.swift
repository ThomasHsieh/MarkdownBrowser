import SwiftUI

struct ContentView: View {

    /// 這個視窗的狀態。字體、字級、外觀都是視窗各自的。
    @ObservedObject var state: DocumentState

    var body: some View {
        HSplitView {
            if state.sidebarVisible {
                Sidebar(state: state)
                    .frame(minWidth: 170, idealWidth: 240, maxWidth: 420)
            }
            ReadingArea(state: state, book: state.book)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(title)
        .toolbar { toolbarItems }
    }

    private var title: String {
        if let url = state.documentURL { return url.lastPathComponent }
        if let book = state.book.epub { return book.title }
        return "MarkdownBrowser"
    }

    /// 常用動作也放工具列。標題與圖示都給，使用者右鍵可以自己選要不要顯示文字。
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                state.sidebarVisible.toggle()
            } label: {
                Label("側欄", systemImage: "sidebar.left")
            }
            .help("顯示或隱藏側欄　⌘\\")

            Button {
                state.toggleCompare()
            } label: {
                Label("對照書籍", systemImage: state.isComparing ? "book.fill" : "book")
            }
            .help(state.needsPairingPrompt ? "沒有自動配對到書，按下去挑選或看原因　⇧⌘B"
                  : state.canCompare || state.isComparing ? "左書右心得對照　⇧⌘B" : "找不到對應的心得")
            .disabled(!(state.canCompare || state.isComparing))
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("外觀", selection: $state.appearance) {
                    ForEach(AppSettings.appearanceChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("外觀", systemImage: "circle.lefthalf.filled")
            }
            .help("淺色、深色或跟隨系統")

            Menu {
                Picker("字體", selection: $state.fontFamily) {
                    ForEach(AppSettings.fontChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("字體", systemImage: "character.textbox")
            }
            .help("楷體／黑體　⌘3 ⌘4")

            ControlGroup {
                Button { state.bumpFontSize(-1) } label: {
                    Label("縮小文字", systemImage: "textformat.size.smaller")
                }
                Button { state.bumpFontSize(1) } label: {
                    Label("放大文字", systemImage: "textformat.size.larger")
                }
            }
            .help("調整字級　⌘+ ⌘-")

            Button {
                state.focusedBridge?.openFind()
            } label: {
                Label("搜尋", systemImage: "magnifyingglass")
            }
            .help("在文件中搜尋　⌘F")

            Button {
                state.openInMarkEdit()
            } label: {
                Label("用 MarkEdit 開啟", systemImage: "square.and.pencil")
            }
            .help("用 MarkEdit 開啟　⌘E")
            .disabled(state.documentURL == nil || state.focusedDocument !== state)

            Button {
                state.focusedBridge?.printDocument()
            } label: {
                Label("列印", systemImage: "printer")
            }
            .help("列印或匯出 PDF　⌘P")
            .disabled(state.isEmpty)
        }
    }
}

struct Sidebar: View {

    @ObservedObject var state: DocumentState

    /// 展開中的「找不到位置」標記。它們沒有位置可以捲過去，點了改成原地展開全文。
    @State private var expandedOrphans: Set<String> = []

    var body: some View {
        List {
            if !state.siblings.isEmpty {
                Section("同資料夾") {
                    ForEach(state.siblings, id: \.self) { url in
                        let isCurrent = url == state.documentURL
                        Text(url.deletingPathExtension().lastPathComponent)
                            .lineLimit(2)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { WindowRouter.shared.open(url, in: state) }
                    }
                }
            }

            // 單獨開書：側欄下半是書的目錄（docs/SPEC.md 13.1）
            if state.documentURL == nil, state.book.epub != nil {
                Section("目錄") {
                    BookContents(state: state, book: state.book)
                }
            }

            // 下半部輪流顯示大綱與標記：兩者都是「這個檔案裡的位置清單」
            if state.documentURL != nil {
                Section {
                    switch state.sidebarMode {
                    case .outline: outline
                    case .highlights: highlightList
                    }
                } header: {
                    Picker("", selection: $state.sidebarMode) {
                        Text("大綱").tag(SidebarMode.outline)
                        Text("標記 \(highlightTotal)").tag(SidebarMode.highlights)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.documentURL) { _ in expandedOrphans = [] }
    }

    @ViewBuilder
    private var outline: some View {
        ForEach(state.outline) { item in
            let isActive = item.id == state.activeHeadingID
            Text(item.text)
                .lineLimit(2)
                .font(.system(size: item.level <= 2 ? 12 : 11))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .padding(.leading, CGFloat(max(0, item.level - 1)) * 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    state.bridge?.scrollToHeading(item.id)
                    state.syncBook(fromNoteHeading: item.id)
                }
                .modifier(LinkCursor(active: state.isComparing))
        }
    }

    /// 分頁上的數字：心得與書的標記總數
    private var highlightTotal: Int {
        let book = state.book.documentURL != nil && state.book.epub?.fixedLayout != true ? state.book.highlights.count : 0
        return state.highlights.count + book
    }

    /// 先列心得、再列書的標記（docs/SPEC.md 13.8）。讀書寫心得時最常回頭看的就是書裡畫的重點，
    /// 只列心得的話，書裡畫了再多，分頁上也寫「標記 0」，看起來像沒存到。
    @ViewBuilder
    private var highlightList: some View {
        let showBook = state.book.documentURL != nil && state.book.epub?.fixedLayout != true
        if state.highlights.isEmpty && (!showBook || state.book.highlights.isEmpty) {
            // 唯讀時（標記檔讀不出來、資料夾不能寫）講原因，別叫人去畫線
            Text(state.highlightsReadOnly ?? "這一章還沒有標記。選一段文字就能畫線。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            if showBook {
                sourceHeader("心得", count: state.highlights.count)
            }
            highlightGroups(of: state, prefix: "n")
            if showBook && !state.book.highlights.isEmpty {
                sourceHeader("書", count: state.book.highlights.count)
                    .padding(.top, 8)
                highlightGroups(of: state.book, prefix: "b")
            }
        }
    }

    private func sourceHeader(_ title: String, count: Int) -> some View {
        Text("\(title)　\(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// 一欄的標記：依所在標題分組、依原文順序；找不到位置的永遠排最後。
    /// 點一列由那一欄自己捲（翻）過去並閃一下。
    @ViewBuilder
    private func highlightGroups(of pane: PaneDocument, prefix: String) -> some View {
        let placed = pane.highlights.filter { !$0.orphan }
        let orphans = pane.highlights.filter(\.orphan)
        ForEach(groups(of: placed, prefix: prefix), id: \.key) { group in
            Text(group.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 4)
            ForEach(group.items) { item in
                row(item, in: pane, expanded: false)
                    .onTapGesture { pane.bridge?.revealHighlight(item.id) }
            }
        }
        if !orphans.isEmpty {
            Label("找不到位置（\(orphans.count)）", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 6)
            ForEach(orphans) { item in
                let key = prefix + item.id
                let open = expandedOrphans.contains(key)
                row(item, in: pane, expanded: open)
                    .onTapGesture {
                        if open { expandedOrphans.remove(key) } else { expandedOrphans.insert(key) }
                    }
            }
        }
    }

    private struct Group { let key: String; let heading: String?; let title: String; let items: [HighlightItem] }

    private func groups(of items: [HighlightItem], prefix: String) -> [Group] {
        var out: [Group] = []
        for item in items {
            if let last = out.last, last.heading == item.heading {
                out[out.count - 1] = Group(key: last.key, heading: last.heading, title: last.title,
                                           items: last.items + [item])
            } else {
                // ForEach 的 id 加序號：理論上同一個標題不會被隔開出現兩次，但 slug 撞名時保險
                out.append(Group(key: "\(prefix)\(item.heading ?? "")#\(out.count)", heading: item.heading,
                                 title: item.headingText ?? "（開頭）", items: [item]))
            }
        }
        return out
    }

    private func row(_ item: HighlightItem, in pane: PaneDocument, expanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if item.style == "underline" {
                Rectangle().fill(Color.primary).frame(width: 9, height: 1.5).padding(.top, 8)
            } else {
                Circle().fill(item.color).frame(width: 8, height: 8).padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 1) {
                (Text(item.text) + (item.note.isEmpty ? Text("") :
                    Text(" ●").font(.system(size: 6)).foregroundColor(item.style == "underline" ? .primary : item.color)))
                    .font(.system(size: 12))
                    .lineLimit(expanded ? nil : 2)
                if !item.note.isEmpty {
                    Text(expanded ? item.note : (item.note.components(separatedBy: "\n").first ?? ""))
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("拷貝原文") { pane.copyToPasteboard(item.text) }
            Button("拷貝註記") { pane.copyToPasteboard(item.note) }
                .disabled(item.note.isEmpty)
            Divider()
            Button(item.note.isEmpty ? "刪除" : "刪除（含註記）", role: .destructive) {
                pane.bridge?.deleteHighlight(item.id)
            }
            .disabled(pane.highlightsReadOnly != nil)
        }
    }
}

/// 點了會帶動另一欄的列，游標變手指（docs/SPEC.md 13.6），跟內文的標題、引文一致。
/// 不用 pointerStyle：側欄的 List 底下是 NSTableView，它會自己把游標設回箭頭，pointerStyle
/// 實測沒作用。所以滑鼠每動一下就設一次；push／pop 也不用，列在游標底下消失時會卡住手指
struct LinkCursor: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active: if active { NSCursor.pointingHand.set() }
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}
