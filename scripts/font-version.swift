// 讀出字型檔裡記載的版本號（name table 的 version），只印數字部分：
//   "Version 1.530; October 13, 2026" → 1.530
//   "Version 1.0.42; ttfautohint …"   → 1.0.42
//   "2.1"                              → 2.1
// fetch-fonts.sh 用它確認找到的檔真的是鎖定的那一版 —— 霞鶩文楷、更紗的檔名不帶版本，
// 只比檔名的話 $FONTS_DIR 或系統裡放的是哪版就用哪版（docs/SPEC.md 第 7 節）。
// 讀不出來就印空行、結束碼 1。
import CoreText
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("用法: font-version <字型檔>\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
      let first = descriptors.first else { print(""); exit(1) }
let font = CTFontCreateWithFontDescriptor(first, 12, nil)
let raw = (CTFontCopyName(font, kCTFontVersionNameKey) as String?) ?? ""
guard let range = raw.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { print(""); exit(1) }
print(raw[range])
