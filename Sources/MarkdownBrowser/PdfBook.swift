import CoreGraphics
import Foundation

/// 書那欄的資源來源：`mbres://book/…` 從這裡拿檔案。EPUB 從 ZIP 裡讀，PDF 只有它自己一個檔。
protocol BookResources: AnyObject {
    func data(at path: String) -> Data?
}

extension EpubBook: BookResources {}

/// 書那欄的 PDF（docs/SPEC.md 13.13）。排版、文字、書籤都交給網頁端的 pdf.js，
/// Swift 這邊只要書名（配對用）與檔案本身。
final class PdfBook: BookResources {

    /// 網頁端用 `mbres://book/<這個路徑>` 讀 PDF。固定一個名字：檔名可能有任何字元，
    /// 而這裡只有一個檔，沒有路徑要分辨
    static let resourcePath = "document.pdf"

    let url: URL
    /// Title 中繼資料；空的或沒有就用檔名
    let title: String

    init(url: URL) throws {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw PdfError.unreadable
        }
        if document.isEncrypted && !document.isUnlocked {
            throw PdfError.encrypted
        }
        self.url = url
        let fallback = url.deletingPathExtension().lastPathComponent
        self.title = Self.metadataTitle(of: document) ?? fallback
    }

    func data(at path: String) -> Data? {
        guard path == Self.resourcePath else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func metadataTitle(of document: CGPDFDocument) -> String? {
        guard let info = document.info else { return nil }
        var raw: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Title", &raw), let raw,
              let text = CGPDFStringCopyTextString(raw) as String? else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    enum PdfError: LocalizedError {
        case unreadable, encrypted
        var errorDescription: String? {
            switch self {
            case .unreadable: return "無法開啟這個 PDF"
            case .encrypted: return "有密碼的 PDF 不支援"
            }
        }
    }
}
