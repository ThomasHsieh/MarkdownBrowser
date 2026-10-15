import AppKit
import SwiftUI

@main
struct MarkdownBrowserApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var router = WindowRouter.shared

    var body: some Scene {
        // 多視窗。WindowGroup 不帶值，開窗時要讀哪個檔由 WindowRouter 交棒。
        WindowGroup(id: WindowRouter.windowID) {
            DocumentWindow()
        }
        .defaultSize(width: 1080, height: 800)
        .commands { menus }
    }

    /// 選單一律作用在前景視窗上。`router.active` 是唯一的來源 ——
    /// SwiftUI 的 focus 環境在 AppDelegate 與按鍵監聽那邊拿不到。
    @CommandsBuilder
    private var menus: some Commands {
        // 這是唯讀閱讀器，沒有「新增」這回事 —— 但有「開新視窗」。
        CommandGroup(replacing: .newItem) {
            Button("開新視窗") { router.newWindow() }
                .keyboardShortcut("n")

            Button("開啟…") { router.openPanel() }
                .keyboardShortcut("o")

            Menu("最近開啟") {
                ForEach(settings.recentDocuments, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        router.openInActiveWindow(url)
                    }
                }
                if !settings.recentDocuments.isEmpty {
                    Divider()
                    Button("清除選單") { settings.clearRecentDocuments() }
                }
            }
            .disabled(settings.recentDocuments.isEmpty)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("用 MarkEdit 開啟") { router.active?.openInMarkEdit() }
                .keyboardShortcut("e")
                .disabled(router.active?.documentURL == nil || router.active?.focusedDocument !== router.active)
            Button("在 Finder 中顯示標記檔") { router.active?.focusedDocument.revealSidecarInFinder() }
                .disabled(!(router.active?.focusedDocument.sidecarExists ?? false))
            Button("重新載入") { router.active?.reloadAll() }
                .keyboardShortcut("r")
                .disabled(!hasDocument)

            Divider()

            // 書名比對不到或配錯（例如想對照英文原版）時手動指定（docs/SPEC.md 13.2）
            Button("指定對應書籍…") { router.active?.chooseBookManually() }
                .disabled(router.active?.documentURL == nil)
            Button("清除指定") { router.active?.clearManualPair() }
                .disabled(!(router.active?.hasManualPair ?? false))
        }

        CommandGroup(replacing: .printItem) {
            Button("列印…") { router.active?.focusedBridge?.printDocument() }
                .keyboardShortcut("p")
                .disabled(!hasDocument)
        }

        CommandGroup(after: .textEditing) {
            Button("搜尋…") { router.active?.focusedBridge?.openFind() }
                .keyboardShortcut("f")
            Button("下一筆") { router.active?.focusedBridge?.findNext() }
                .keyboardShortcut("g")
            Button("上一筆") { router.active?.focusedBridge?.findPrev() }
                .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            // 實際由 AppDelegate 的按鍵監聽攔（同 ⌘F），這裡顯示快捷鍵、給滑鼠用。
            // 永遠可按：要在沒選取時變灰，網頁端就得每次選取改變都通知，不划算。
            Button("標記選取文字") { AppDelegate.highlightSelection() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!hasDocument)
        }

        CommandGroup(after: .toolbar) {
            Picker("外觀", selection: activeBinding(\.appearance, fallback: settings.appearance)) {
                ForEach(AppSettings.appearanceChoices, id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }

            Picker("字體", selection: activeBinding(\.fontFamily, fallback: settings.fontFamily)) {
                ForEach(Array(AppSettings.fontChoices.enumerated()), id: \.element.id) { index, choice in
                    Text(choice.name).tag(choice.id)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 3)")))
                }
            }

            Divider()

            Button("放大文字") { router.active?.bumpFontSize(1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("縮小文字") { router.active?.bumpFontSize(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("實際大小") { router.active?.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button(router.active?.sidebarVisible == false ? "顯示側欄" : "隱藏側欄") {
                router.active?.sidebarVisible.toggle()
            }
            .keyboardShortcut("\\", modifiers: .command)

            Picker("側欄", selection: activeBinding(\.sidebarMode, fallback: settings.sidebarMode)) {
                Text("大綱").tag(SidebarMode.outline)
                Text("標記").tag(SidebarMode.highlights)
            }

            Divider()

            Picker("書", selection: activeBinding(\.bookLayout, fallback: settings.bookLayout)) {
                ForEach(BookLayout.allCases, id: \.self) { Text($0.name).tag($0) }
            }

            Button(router.active?.isComparing == true ? "關閉對照書籍" : "對照書籍") { router.active?.toggleCompare() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!((router.active?.canCompare ?? false) || (router.active?.isComparing ?? false)))
        }
    }

    private var hasDocument: Bool { !(router.active?.isEmpty ?? true) }

    /// 選單的 Picker 要綁在前景視窗的狀態上。沒有前景視窗時退回
    /// AppSettings 記著的那一份（也就是下一個新視窗會用的值）。
    private func activeBinding<T>(_ keyPath: ReferenceWritableKeyPath<DocumentState, T>,
                                  fallback: T) -> Binding<T> {
        Binding(
            get: { router.active?[keyPath: keyPath] ?? fallback },
            set: { router.active?[keyPath: keyPath] = $0 }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installKeyMonitor()

        // Finder 的開檔請求會在 didFinishLaunching 之後才送到，
        // 所以晚一步再決定要不要還原上次讀的檔。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated { WindowRouter.shared.restoreLastDocumentIfIdle() }
        }
    }

    /// Finder 雙點擊、`open` 指令、拖到 Dock 圖示都走這裡。
    /// 一次給多個檔就開多個視窗，不再只讀第一個。
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { WindowRouter.shared.openFromFinder(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 結束前先把每個視窗打到一半的註記寫入，還有沒寫進去的標記就問。
    /// `Cmd Q` 不一定會讓視窗收到 willClose，所以不能只靠關窗那條路。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // 心得與書兩欄都要寫完
            let documents = WindowRouter.shared.documents.flatMap(\.panes).filter { $0.documentURL != nil }
            guard !documents.isEmpty else { return .terminateNow }
            var remaining = documents.count
            var replied = false
            let finish = {
                guard !replied else { return }
                replied = true
                documents.forEach { $0.resolvePendingSave() }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            for document in documents {
                document.prepareToCloseAsync {
                    remaining -= 1
                    if remaining == 0 { finish() }
                }
            }
            // 網頁端沒回應也不能卡住結束
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { finish() } }
            return .terminateLater
        }
    }

    @MainActor
    static func highlightSelection() {
        WindowRouter.shared.active?.focusedBridge?.highlightSelection { ok in
            if !ok { NSSound.beep() }
        }
    }

    /// Dock 圖示右鍵的選單。
    ///
    /// 這個選單不會自動抄 App 的選單列，要自己給 —— SwiftUI 的 `Commands`
    /// 只長在選單列上。目前只放「開新視窗」，跟 `⌘N` 同一條路。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "開新視窗", action: #selector(newWindowFromDock), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newWindowFromDock() {
        MainActor.assumeIsolated { WindowRouter.shared.newWindow() }
    }


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

            // ⌃Tab：窄視窗 tab 模式下切換書與心得（keyCode 48 = Tab）
            if flags.contains(.control), !flags.contains(.command), event.keyCode == 48 {
                return MainActor.assumeIsolated { () -> NSEvent? in
                    guard let active = WindowRouter.shared.active, active.isComparing, active.isTabbed else { return event }
                    active.selectedTab = active.selectedTab == .book ? .note : .book
                    return nil
                }
            }

            guard flags.contains(.command), !flags.contains(.control) else { return event }

            return MainActor.assumeIsolated { () -> NSEvent? in
                // 多視窗：送給前景視窗的 bridge，而不是某個共用的單例；對照模式下是焦點欄的。
                guard let bridge = WindowRouter.shared.active?.focusedBridge else { return event }
                switch event.keyCode {
                case 3:                                   // F
                    bridge.openFind()
                    return nil
                case 5:                                   // G
                    if flags.contains(.shift) { bridge.findPrev() } else { bridge.findNext() }
                    return nil
                case 4 where flags.contains(.shift):      // Shift-H；沒有 Shift 的 ⌘H 是系統的隱藏
                    AppDelegate.highlightSelection()
                    return nil
                default:
                    return event
                }
            }
        }
    }
}
