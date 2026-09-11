// swift-tools-version: 6.0
import PackageDescription

// 網頁資源與字型不走 SPM 的 resources —— 那會生出一個 .bundle，
// 而我們是用 Makefile 手工組 .app，直接把檔案放進 Contents/Resources 更單純。
let package = Package(
    name: "MarkdownBrowser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MarkdownBrowser",
            path: "Sources/MarkdownBrowser",
            // 這是個單視窗、全部跑在主執行緒的 App，Swift 6 的嚴格併發檢查
            // 只會製造大量 @Sendable 樣板而換不到安全性。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
