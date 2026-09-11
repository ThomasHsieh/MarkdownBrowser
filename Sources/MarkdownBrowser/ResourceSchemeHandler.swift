import Foundation
import UniformTypeIdentifiers
import WebKit

/// 自訂 URL scheme `mbres://`，取代 `file://`。
///
/// 用 `loadFileURL(_:allowingReadAccessTo:)` 只能開放一個目錄樹，
/// 但我們同時要讀三個不相干的地方：App 自己的網頁資源、目前文件所在資料夾
/// （相對路徑圖片）、以及 `~/.config/markdownbrowser/fonts`。自己供應反而乾淨。
///
///   mbres://app/…       → Contents/Resources/web/…
///   mbres://doc/…       → 目前文件所在資料夾
///   mbres://userfont/…  → ~/.config/markdownbrowser/fonts
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "mbres"
    static let indexURL = URL(string: "mbres://app/index.html")!

    /// 由 AppState 在開檔時更新。
    var documentDirectory: URL?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let relative = url.path.removingPercentEncoding ?? url.path
        guard let root = root(for: host), let file = resolve(relative, under: root) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: file)
            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(for: file),
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    // MARK: -

    private func root(for host: String) -> URL? {
        switch host {
        case "app":
            return Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
        case "doc":
            return documentDirectory
        case "userfont":
            return UserAssets.fontsDirectory
        default:
            return nil
        }
    }

    /// 擋住 `../` 逃出根目錄。
    private func resolve(_ relative: String, under root: URL) -> URL? {
        let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        guard !trimmed.isEmpty else { return nil }
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let base = root.standardizedFileURL
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "ttc": return "font/collection"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }
}
