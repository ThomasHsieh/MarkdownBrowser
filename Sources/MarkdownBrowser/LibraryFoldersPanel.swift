import AppKit
import SwiftUI

/// 「檔案 → 書庫資料夾…」：額外書庫的清單，可加、可移除（docs/SPEC.md 13.2）。
///
/// 用自己建的 NSWindow 而不是 SwiftUI 的 `Window` 場景：它不是文件視窗，不該被
/// `WindowRouter` 當成前景視窗，也不該被 SwiftUI 存起來做視窗還原。
/// 不用 NSPanel：panel 在 App 切到背景時會自動藏起來，utility 樣式又會浮在
/// 所有視窗上面，邊開 Finder 找資料夾邊看清單時很礙事。
@MainActor
enum LibraryFoldersPanel {

    private static var panel: NSWindow?

    static func show() {
        if panel == nil {
            let p = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            p.title = "書庫資料夾"
            p.isReleasedWhenClosed = false
            p.contentViewController = NSHostingController(rootView: LibraryFoldersView())
            p.center()
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    /// 選一個資料夾加進清單。回傳加入的資料夾，取消是 `nil`。
    @discardableResult
    static func chooseFolder() -> URL? {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "加入"
        open.message = "選一個放 EPUB 的資料夾，底下所有子資料夾都會一起找"
        guard open.runModal() == .OK, let url = open.url else { return nil }
        AppSettings.shared.addLibraryFolder(url)
        return url
    }
}

private struct LibraryFoldersView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("書名在心得附近找不到時，依序到這些資料夾找。只比對檔名，不會打開書，雲端硬碟上的書不會被下載。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(settings.libraryFolders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.lastPathComponent)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(folder)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Button("加入資料夾…") { LibraryFoldersPanel.chooseFolder() }
                Button("移除") {
                    if let selection { settings.removeLibraryFolder(selection) }
                    selection = nil
                }
                .disabled(selection == nil)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 240)
    }
}
