import AppKit
import SwiftUI

@main
struct MarkdownBrowserApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        Window("MarkdownBrowser", id: "main") {
            ContentView(state: state)
        }
        .defaultSize(width: 1080, height: 800)
        .commands { menus }
    }

    @CommandsBuilder
    private var menus: some Commands {
        // 這是唯讀閱讀器，沒有「新增」這回事。
        CommandGroup(replacing: .newItem) {
            Button("開啟…") { state.openPanel() }
                .keyboardShortcut("o")

            Menu("最近開啟") {
                ForEach(state.recentDocuments, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { state.open(url) }
                }
                if !state.recentDocuments.isEmpty {
                    Divider()
                    Button("清除選單") { state.clearRecentDocuments() }
                }
            }
            .disabled(state.recentDocuments.isEmpty)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("用 MarkEdit 開啟") { state.openInMarkEdit() }
                .keyboardShortcut("e")
                .disabled(state.documentURL == nil)
            Button("重新載入") { state.render(keepScroll: true) }
                .keyboardShortcut("r")
                .disabled(state.documentURL == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("列印…") { state.bridge?.printDocument() }
                .keyboardShortcut("p")
                .disabled(state.documentURL == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("搜尋…") { state.bridge?.openFind() }
                .keyboardShortcut("f")
            Button("下一筆") { state.bridge?.findNext() }
                .keyboardShortcut("g")
            Button("上一筆") { state.bridge?.findPrev() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Picker("主題", selection: Binding(get: { state.theme }, set: { state.theme = $0 })) {
                ForEach(Array(state.themes.enumerated()), id: \.element.id) { index, theme in
                    if index < 2 {
                        Text(theme.name).tag(theme.id)
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    } else {
                        Text(theme.name).tag(theme.id)
                    }
                }
            }

            Divider()

            Button("放大文字") { state.bumpFontSize(1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("縮小文字") { state.bumpFontSize(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("實際大小") { state.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button(state.sidebarVisible ? "隱藏側欄" : "顯示側欄") {
                state.sidebarVisible.toggle()
            }
            .keyboardShortcut("\\", modifiers: .command)

            Divider()

            Button("開啟設定資料夾") { state.openConfigDirectory() }
            Button("複製內建主題以供修改") { state.exportBuiltInThemes() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installKeyMonitor()

        // Finder 的開檔請求會在 didFinishLaunching 之後才送到，
        // 所以晚一步再決定要不要還原上次讀的檔。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated { AppState.shared.restoreLastDocument() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        MainActor.assumeIsolated { AppState.shared.open(first) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘F 與 ⌘G 自己攔，不靠選單項目的快捷鍵。
    ///
    /// 選單項目其實叫得動搜尋列，但從選單觸發時 menu tracking 結束後焦點會回到
    /// 網頁本體，搜尋輸入框的 `focus()` 當場被吃掉 —— 搜尋列開著卻打不了字。
    /// 自己攔就沒有 menu tracking，焦點留得住。
    ///
    /// 比對 `keyCode` 而不是 `charactersIgnoringModifiers`：注音輸入法在用時
    /// F 鍵拿到的字元是「ㄑ」，比字元會漏。keyCode 3 = F、5 = G，與排列無關。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.control) else { return event }

            return MainActor.assumeIsolated { () -> NSEvent? in
                guard let bridge = AppState.shared.bridge else { return event }
                switch event.keyCode {
                case 3:                                   // F
                    bridge.openFind()
                    return nil
                case 5:                                   // G
                    if flags.contains(.shift) { bridge.findPrev() } else { bridge.findNext() }
                    return nil
                default:
                    return event
                }
            }
        }
    }
}
