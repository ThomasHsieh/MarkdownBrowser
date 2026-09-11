import Foundation

struct ThemeInfo: Identifiable, Hashable {
    let id: String          // data-theme 的值
    let name: String        // 選單上顯示的名字
    let builtIn: Bool
    let url: URL?           // 自訂主題的檔案位置
}

/// `~/.config/markdownbrowser/` 底下的自訂主題與字型。
///
/// `themes/*.css` 每個檔就是一套主題，檔名（去副檔名）即 `data-theme` 的值；
/// `fonts/*.ttf|otf` 自動註冊成 `@font-face`，family 名就是檔名。
/// 內建兩套主題用完全相同的格式，可以直接複製出來改。
enum UserAssets {

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/markdownbrowser", isDirectory: true)
    }

    static var themesDirectory: URL { configDirectory.appendingPathComponent("themes", isDirectory: true) }
    static var fontsDirectory: URL { configDirectory.appendingPathComponent("fonts", isDirectory: true) }

    static let builtInThemes: [ThemeInfo] = [
        ThemeInfo(id: "reading", name: "閱讀", builtIn: true, url: nil),
        ThemeInfo(id: "terminal", name: "終端機", builtIn: true, url: nil),
    ]

    static func ensureDirectories() {
        for dir in [themesDirectory, fontsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func userThemes() -> [ThemeInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: themesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "css" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                return ThemeInfo(id: stem, name: stem, builtIn: false, url: url)
            }
    }

    /// 全部自訂主題的 CSS 串在一起，整包塞進 `<style id="user-theme">`。
    /// 一次注入全部而不是只注入目前這套，切換主題才不用重新讀檔。
    static func userThemeCSS() -> String {
        userThemes().compactMap { info in
            guard let url = info.url, let css = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "/* ==== \(info.name) ==== */\n\(css)"
        }.joined(separator: "\n\n")
    }

    /// 自訂字型的 `@font-face`。檔案本身由 `mbres://userfont/` 這個 scheme 供應。
    static func userFontCSS() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["ttf", "otf", "ttc", "woff", "woff2"].contains($0.pathExtension.lowercased()) }
            .map { url -> String in
                let family = url.deletingPathExtension().lastPathComponent
                let encoded = url.lastPathComponent
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.lastPathComponent
                let format: String
                switch url.pathExtension.lowercased() {
                case "otf": format = "opentype"
                case "woff": format = "woff"
                case "woff2": format = "woff2"
                default: format = "truetype"
                }
                return """
                @font-face {
                  font-family: "\(family)";
                  src: url("mbres://userfont/\(encoded)") format("\(format)");
                  font-weight: 100 900;
                  font-style: normal;
                }
                """
            }
            .joined(separator: "\n")
    }

    /// 把內建主題複製一份到自訂主題資料夾，當作改造的起點。
    static func exportBuiltInThemes() throws -> URL {
        ensureDirectories()
        guard let webRoot = Bundle.main.resourceURL?.appendingPathComponent("web/themes", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for theme in builtInThemes {
            let src = webRoot.appendingPathComponent("\(theme.id).css")
            let dst = themesDirectory.appendingPathComponent("我的\(theme.name).css")
            guard FileManager.default.fileExists(atPath: src.path),
                  !FileManager.default.fileExists(atPath: dst.path) else { continue }
            var css = try String(contentsOf: src, encoding: .utf8)
            // 選擇器要跟著新檔名走，否則複製出來的主題不會生效。
            css = css.replacingOccurrences(of: "[data-theme=\"\(theme.id)\"]",
                                           with: "[data-theme=\"我的\(theme.name)\"]")
            try css.write(to: dst, atomically: true, encoding: .utf8)
        }
        return themesDirectory
    }
}
