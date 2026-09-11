import Foundation

/// 側欄檔案排序。
///
/// 字典序下 `第一章 / 第三章 / 第二章` 就是這個順序 —— 兩個現有的心得
/// 資料夾都亂掉。所以從檔名抽出章號來排，中文數字與阿拉伯數字都要認。
/// 抽不出章號的（`附錄與後記`）排到最後，彼此之間按檔名。
enum ChapterSort {

    private static let digits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "壹": 1, "二": 2, "貳": 2, "兩": 2, "三": 3, "參": 3,
        "四": 4, "肆": 4, "五": 5, "伍": 5, "六": 6, "陸": 6, "七": 7, "柒": 7,
        "八": 8, "捌": 8, "九": 9, "玖": 9,
    ]

    /// 中文數字轉整數，支援到「九百九十九」。看不懂就回 nil。
    static func chineseNumber(_ text: String) -> Int? {
        if text.isEmpty { return nil }
        var total = 0
        var section = 0
        var sawDigit = false

        for ch in text {
            if let d = digits[ch] {
                section = section * 10 + d
                sawDigit = true
            } else if ch == "十" || ch == "拾" {
                section = (section == 0 ? 1 : section) * 10
                sawDigit = true
            } else if ch == "百" || ch == "佰" {
                total += (section == 0 ? 1 : section) * 100
                section = 0
                sawDigit = true
            } else {
                return nil
            }
        }
        guard sawDigit else { return nil }
        return total + section
    }

    /// 從檔名抽出「第X章／第X節／第X課／Chapter N」的序號。
    static func chapterNumber(of filename: String) -> Int? {
        let name = (filename as NSString).deletingPathExtension

        if let range = name.range(of: "第[0-9０-９〇零一壹二貳兩三參四肆五伍六陸七柒八捌九玖十拾百佰]+[章節課回篇講]",
                                  options: .regularExpression) {
            let body = String(name[range].dropFirst().dropLast())
            let normalised = body.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? body
            if let n = Int(normalised) { return n }
            return chineseNumber(body)
        }

        if let range = name.range(of: "(?i)\\b(chapter|lesson|part)\\s*([0-9]+)",
                                  options: .regularExpression) {
            let digitsOnly = name[range].filter(\.isNumber)
            return Int(digitsOnly)
        }

        return nil
    }

    /// 章號在前、抽不出章號的殿後；同組內按檔名（用 localizedStandard，數字才排得對）。
    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { a, b in
            let na = chapterNumber(of: a.lastPathComponent)
            let nb = chapterNumber(of: b.lastPathComponent)
            switch (na, nb) {
            case let (x?, y?):
                if x != y { return x < y }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}
