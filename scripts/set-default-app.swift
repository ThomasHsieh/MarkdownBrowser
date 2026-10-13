#!/usr/bin/env swift
// 把 Markdown 相關的檔案型別預設開啟程式設成 MarkdownBrowser。
//
//   swift scripts/set-default-app.swift            設定
//   swift scripts/set-default-app.swift --status   只看目前是誰
//
// App 自己在 Info.plist 裡宣告 LSHandlerRank=Owner 並不會搶到預設 ——
// 那只是「我有能力開」。真正的預設是使用者層級的設定，要明確呼叫
// NSWorkspace.setDefaultApplication 才會改，等同 Finder 的「全部更改」。

import AppKit
import UniformTypeIdentifiers

let bundleID = "com.thomashsieh.markdownbrowser"

// 不含 public.markdown：它在系統上是個沒有上層類型的空殼（不屬於 public.data），
// 沒有任何副檔名對應到它，NSWorkspace 與 LaunchServices 都拒絕替它設預設程式
// （"The file couldn’t be opened" ／ -50）—— 留著只會讓這支腳本每次都以錯誤結束。
let typeIDs = [
    "net.daringfireball.markdown",   // 通用的 Markdown UTI，.md 與 .markdown 掛在這個底下
    "com.thomashsieh.markdownbrowser.markdown-variant",   // .mdown／.mkd／.mdwn，Info.plist 自己宣告的
    "net.ia.markdown",
]

/// 優先用安裝好的那份。用 bundle ID 查會查到開發目錄裡的建置產物，
/// 而那個會被 make clean 砍掉 —— 預設程式指向一個消失的路徑就回到原點了。
func appURL() -> URL? {
    let installed = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MarkdownBrowser.app"),
        URL(fileURLWithPath: "/Applications/MarkdownBrowser.app"),
    ]
    for url in installed where FileManager.default.fileExists(atPath: url.path) { return url }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
}

func currentHandler(for type: UTType) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return "（無）" }
    return Bundle(url: url)?.bundleIdentifier ?? url.lastPathComponent
}

let types = typeIDs.compactMap { UTType($0) }

guard let app = appURL() else {
    FileHandle.standardError.write("找不到 \(bundleID)。先跑 make install。\n".data(using: .utf8)!)
    exit(1)
}

if CommandLine.arguments.contains("--status") {
    for t in types { print("  \(t.identifier)  →  \(currentHandler(for: t))") }
    exit(0)
}

print("App：\(app.path)")

let group = DispatchGroup()
var failures: [String] = []

for type in types {
    group.enter()
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
        if let error {
            failures.append("\(type.identifier)：\(error.localizedDescription)")
        } else {
            print("  ✓ \(type.identifier)")
        }
        group.leave()
    }
}

// setDefaultApplication 的 completion 是在主佇列上跑的，所以不能用 group.wait()
// 擋住主執行緒 —— 會直接死鎖。改成跑 runloop 等它。
var done = false
group.notify(queue: .main) { done = true }
while !done && RunLoop.main.run(mode: .default, before: .distantFuture) {}

if failures.isEmpty {
    print("\n完成。Finder 雙點擊 .md 現在會開 MarkdownBrowser。")
} else {
    FileHandle.standardError.write(("\n有幾項沒設成功：\n" + failures.map { "  ✗ \($0)" }.joined(separator: "\n") + "\n").data(using: .utf8)!)
    exit(1)
}
