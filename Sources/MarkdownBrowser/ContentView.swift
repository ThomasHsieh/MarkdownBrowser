import SwiftUI

struct ContentView: View {

    /// 這個視窗的狀態。主題、字體、字級都是視窗各自的。
    @ObservedObject var state: DocumentState

    /// 只用來拿主題清單（自訂主題的檔案集合是全 App 共用的）。
    @ObservedObject var settings: AppSettings

    var body: some View {
        HSplitView {
            if state.sidebarVisible {
                Sidebar(state: state)
                    .frame(minWidth: 170, idealWidth: 240, maxWidth: 420)
            }
            WebPane(state: state)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(state.documentURL?.lastPathComponent ?? "MarkdownBrowser")
        .toolbar { toolbarItems }
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
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("主題", selection: $state.theme) {
                    ForEach(settings.themes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Picker("外觀", selection: $state.appearance) {
                    ForEach(AppSettings.appearanceChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("主題與外觀", systemImage: "paintpalette")
            }
            .help("切換主題與明暗　⌘1 ⌘2")

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
                state.bridge?.openFind()
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
            .disabled(state.documentURL == nil)

            Button {
                state.bridge?.printDocument()
            } label: {
                Label("列印", systemImage: "printer")
            }
            .help("列印或匯出 PDF　⌘P")
            .disabled(state.documentURL == nil)
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
                        Text("標記 \(state.highlights.count)").tag(SidebarMode.highlights)
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
                .onTapGesture { state.bridge?.scrollToHeading(item.id) }
        }
    }

    /// 依所在標題分組、依原文順序；找不到位置的永遠排最後。
    @ViewBuilder
    private var highlightList: some View {
        let placed = state.highlights.filter { !$0.orphan }
        let orphans = state.highlights.filter(\.orphan)
        if state.highlights.isEmpty {
            // 唯讀時（標記檔讀不出來、資料夾不能寫）講原因，別叫人去畫線
            Text(state.highlightsReadOnly ?? "這一章還沒有標記。選一段文字就能畫線。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        ForEach(groups(of: placed), id: \.key) { group in
            Text(group.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 4)
            ForEach(group.items) { item in
                row(item, expanded: false)
                    .onTapGesture { state.bridge?.revealHighlight(item.id) }
            }
        }
        if !orphans.isEmpty {
            Label("找不到位置（\(orphans.count)）", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 6)
            ForEach(orphans) { item in
                let open = expandedOrphans.contains(item.id)
                row(item, expanded: open)
                    .onTapGesture {
                        if open { expandedOrphans.remove(item.id) } else { expandedOrphans.insert(item.id) }
                    }
            }
        }
    }

    private struct Group { let key: String; let heading: String?; let title: String; let items: [HighlightItem] }

    private func groups(of items: [HighlightItem]) -> [Group] {
        var out: [Group] = []
        for item in items {
            if let last = out.last, last.heading == item.heading {
                out[out.count - 1] = Group(key: last.key, heading: last.heading, title: last.title,
                                           items: last.items + [item])
            } else {
                // ForEach 的 id 加序號：理論上同一個標題不會被隔開出現兩次，但 slug 撞名時保險
                out.append(Group(key: "\(item.heading ?? "")#\(out.count)", heading: item.heading,
                                 title: item.headingText ?? "（開頭）", items: [item]))
            }
        }
        return out
    }

    private func row(_ item: HighlightItem, expanded: Bool) -> some View {
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
            Button("拷貝原文") { state.copyToPasteboard(item.text) }
            Button("拷貝註記") { state.copyToPasteboard(item.note) }
                .disabled(item.note.isEmpty)
            Divider()
            Button(item.note.isEmpty ? "刪除" : "刪除（含註記）", role: .destructive) {
                state.bridge?.deleteHighlight(item.id)
            }
            .disabled(state.highlightsReadOnly != nil)
        }
    }
}
