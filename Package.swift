// swift-tools-version: 6.0
import PackageDescription

// 網頁資源與字型不走 SPM 的 resources —— 那會生出一個 .bundle，
// 而我們是用 Makefile 手工組 .app，直接把檔案放進 Contents/Resources 更單純。
let package = Package(
    name: "MarkdownBrowser",
    platforms: [.macOS(.v14)],
    // EPUB 是 ZIP。直接從 ZIP 串流讀單一檔案，不先解壓到暫存資料夾 ——
    // 15 MB 的書整本解壓有延遲，暫存資料夾還要處理清理（docs/SPEC.md 13.5）。
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.19")),
    ],
    targets: [
        .executableTarget(
            name: "MarkdownBrowser",
            dependencies: ["ZIPFoundation"],
            path: "Sources/MarkdownBrowser",
            // 這是個單視窗、全部跑在主執行緒的 App，Swift 6 的嚴格併發檢查
            // 只會製造大量 @Sendable 樣板而換不到安全性。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
