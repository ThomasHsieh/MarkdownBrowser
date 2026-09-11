import SwiftUI

struct ContentView: View {

    @ObservedObject var state: AppState

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
                Picker("主題", selection: Binding(get: { state.theme }, set: { state.theme = $0 })) {
                    ForEach(state.themes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("主題", systemImage: "paintpalette")
            }
            .help("切換主題　⌘1 ⌘2")

            Menu {
                Picker("字體", selection: Binding(get: { state.fontFamily }, set: { state.fontFamily = $0 })) {
                    ForEach(AppState.fontChoices, id: \.id) { choice in
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

    @ObservedObject var state: AppState

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
                            .onTapGesture { state.open(url) }
                    }
                }
            }

            if !state.outline.isEmpty {
                Section("大綱") {
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
            }
        }
        .listStyle(.sidebar)
    }
}
