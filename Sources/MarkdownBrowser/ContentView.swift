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
