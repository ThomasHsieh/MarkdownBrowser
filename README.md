# MarkdownBrowser

原生 macOS Markdown 閱讀器，把 Claude Code 在 cmux／ghostty 裡的中文閱讀體驗
搬進一個能雙點擊開啟的 App。

核心是一件事：**粗體不加粗，只換成橘色。** 中文字加粗會糊成一團，
所以重點訊號交給顏色 —— 這正是 `ghostty/config` 裡 `bold-color = #DD9853`
配上 `font-synthetic-style = no-bold` 在做的事，一般 Markdown viewer 做不到。

## 安裝

1. 到[最新的 Release](https://github.com/ThomasHsieh/MarkdownBrowser/releases/latest)
   下載 `MarkdownBrowser-<版本>.zip`
2. 解壓縮，把 `MarkdownBrowser.app` 拖進「應用程式」或 `~/Applications`
3. 第一次打開會被系統擋下，因為 App 只有 ad-hoc 簽章、沒有經過 Apple 公證。
   被擋之後到「系統設定 → 隱私權與安全性」，在下方找到 MarkdownBrowser 那一行，
   按「強制打開」並確認。之後就能正常開啟

只在 macOS 26 測試過。要讓 Finder 雙點擊 `.md` 就用這個 App 開，對任一 `.md` 按
「取得資訊 → 打開方式」選 MarkdownBrowser，再按「全部更改」。

## 建置

需要 Xcode 26 或更新版本（使用 `actool` 編譯原生 Icon Composer 圖示資產）。

```bash
make              # 取字型 → 編譯 → 組 .app → ad-hoc 簽章
make install      # 裝到 ~/Applications 並向 LaunchServices 註冊
make set-default  # 把 .md 的預設開啟程式設成這個 App
make status       # 查 .md 目前的預設開啟程式是誰
make run          # 建置後直接開
make icons        # 由 AppIcon-v4.png 重建透明書本圖層與 ICNS（通常不需執行）
```

字型不進版控，`make` 時依序找環境變數 `FONTS_DIR` 指的資料夾（有設才找）→ `~/Library/Fonts/`
→ 官方 release 下載。共六個 Regular 字面：霞鶩文楷（楷體）與更紗黑體（黑體）各有比例版與等寬版，
另有源雲明體（明體）與 jf open 粉圓（圓體），這兩套的程式碼借更紗等寬。每套都鎖定版本，
發版前跑 `make fonts-update` 檢查新版。

`make set-default` 會把 `.md` 的預設開啟程式指過來（等同 Finder 的
「取得資訊 → 打開方式 → 全部更改」）。ad-hoc 簽章的 App 第一次開
可能要去「系統設定 → 隱私權與安全性」放行。

## 快捷鍵

| | |
|---|---|
| `⌘N` | 開新視窗 |
| `⌘O` | 開檔（換掉目前視窗的內容） |
| `⌘3` / `⌘4` | 楷體／黑體 |
| `⌘+` `⌘-` `⌘0` | 字級 |
| `⌘\` | 收合側欄 |
| `⌘F` / `⌘G` / `⇧⌘G` | 搜尋、下一筆、上一筆 |
| `⌘E` | 用 MarkEdit 開啟 |
| `⌘P` | 列印／匯出 PDF |
| `⌘R` | 手動重新載入 |
| `⇧⌘H` | 把選取的文字標成綠色 |
| `⇧⌘B` | 開關左書右心得的對照 |
| `⌃Tab` | 視窗太窄改成分頁時，切換書與心得 |

**深色／淺色沒有快捷鍵**，在兩個地方切換：選單「顯示方式 → 外觀」，
或工具列的**外觀**按鈕（半黑半白的圓）。三種選擇是自動（跟隨系統）／淺色／深色。

工具列由左到右是：側欄開關、對照書籍、外觀、字體、字級加減、搜尋、
用 MarkEdit 開啟、列印。檔案選單有「最近開啟」，保留最近 10 個檔。

檔案在外部被改動時會自動重載並保留捲動位置 —— 陪讀時可以左邊讀、右邊讓 AI 繼續寫。

## 多視窗

`⌘N` 開新視窗，Dock 圖示按右鍵也有「開新視窗」（App 要在執行中才看得到，
沒在跑的時候 macOS 只給「選項」那一組）。**Finder 雙點擊不會動到已經開著的視窗** —— 已經有視窗在讀那個檔
就把它帶到前景，有還沒開檔的空白視窗就用那一個，否則開新的。一次選多個檔按
Enter 就開多個視窗。

字體、字級、外觀都是**每個視窗各自的**，可以左邊楷體、右邊黑體並排比對；
新視窗沿用最後一次的選擇。側欄開合也是各視窗獨立。「最近開啟」是全 App 共用。

`⌘O` 與「最近開啟」是換掉**目前視窗**的內容，要另開一個就先 `⌘N`。
**同一個檔只會開在一個視窗裡**：選的檔已經開在別的視窗，就直接跳過去。

## 標記與註記

選取文字，上方會浮出工具列：**綠、藍、紫、粉**四種底色加一種底線，點一下就畫線，
`⇧⌘H` 直接套綠色。點已經畫好的標記可以改色、刪除或寫註記。選取範圍蓋到既有標記時，
「刪除」只擦掉選到的部分。粗體仍然不加粗，標記只動底色或底線。

註記是純文字，**沒有存檔鍵**：停手半秒就寫入。有註記的標記尾端有一顆小圓點，
滑鼠停一下會浮出全文。

標記存在心得檔旁邊的 `<原檔名>_highlights.json`，可以跟著 git 走；只有你畫線、
改色、寫註記時才會寫檔，打開來看不會留下任何變動。錨點存的是引文而不是位置，
AI 在上方插入段落也對得上；原句被改寫掉的標記會列在側欄的「找不到位置」，不會消失。

側欄下半可以在「大綱｜標記」之間切換。列印與 PDF 不會印出標記。
細節見 [`docs/SPEC.md`](docs/SPEC.md) 第 12 節。

## EPUB 對照閱讀

打開心得時，App 會用書名找到對應的 EPUB（往上找到第一個有 `.epub` 的資料夾），
在同一個視窗左邊顯示書、右邊顯示心得。**點任一邊的標題，另一邊就捲到對應的章與小節**；
心得自己下的小節標題書裡沒有時，會用標題裡的關鍵詞去那一章的內文找。
點心得裡的引文，書就翻到那句原文。
書的下拉選單列出全書的章，有心得的章標一個圓點。書不在心得附近（例如放在雲端硬碟）時，用「檔案 → 書庫資料夾…」加入書所在的資料夾；書名對不到時用「檔案 → 指定對應書籍…」。

書套用同一套樣式與字體，書裡的粗體也只換色不加粗。章節標題只靠 CSS 放大的書，
會依書的目錄升格成真的標題。書也能畫標記，存在 EPUB 旁邊的
`<EPUB 檔名>_highlights.json`。

書那欄可以切「捲動｜單頁｜雙頁」。翻頁模式四邊留白、一次翻一整頁、文字不重複，
底部有本章頁碼與全書百分比；方向鍵、空白鍵、觸控板、滾輪、點左右留白都能翻頁。

EPUB 只註冊成「可開啟」，不會搶走 Books 的預設。細節見 [`docs/SPEC.md`](docs/SPEC.md) 第 13 節。

## 樣式

只有一套樣式，沒有主題可選：深色底、比例字（霞鶩文楷或更紗黑體）、行高 1.9，
**標題與粗體同一個橘**，表格滿版、框線跟內文同色。原本有「閱讀」與「終端機」兩個主題，
逐項比較後合併成現在這套，取捨見 [`docs/SPEC.md`](docs/SPEC.md) 4.2 節。
淺色模式保留，橘色壓深到在暖白紙上仍通過 WCAG AA。

## 結構

規格見 [`docs/SPEC.md`](docs/SPEC.md)。

```
Sources/MarkdownBrowser/   SwiftUI 外殼：視窗、選單、檔案監聽、側欄
Resources/web/             WKWebView 內容：markdown-it、base.css（唯一的樣式）、highlights.js（標記）、book.js（EPUB）
Resources/Info.plist       Finder 關聯與 UTI 宣告
Resources/icons/           原生 AppIcon.icon、多尺寸 ICNS、母圖與設計說明
```

Swift 端的狀態按範圍切：`PaneDocument` 是一欄一份（讀哪個檔、標記），心得那欄是
`DocumentState`、書那欄是 `BookPane`；`DocumentState` 同時是一個視窗一份（字體、外觀、對照開關），
`AppSettings` 是跨視窗共用的（新視窗的起始設定、最近開啟），
`WindowRouter` 管哪些視窗開著、哪一個在前景、下一個檔案該開到哪裡。

Swift 端只做殼，所有排版都在 CSS 裡，切字體、切明暗只是換 `<html>` 上一個屬性。

## 文件裡的書名

規格、註解與 commit 訊息裡拿來驗證的實際書籍，公開版一律換成「書 A」「書 B」這類代稱，
書中的章名、小節標題與私人路徑也換成通用寫法（例如 `~/books`）。
代稱與真實內容的對照只放在作者本機的 `CLAUDE.local.md`，已列入 `.gitignore`，不進版控。

## 授權

字型 LXGW WenKai TC、Sarasa Gothic、源雲明體 GenWanMin2、jf open 粉圓（皆 SIL OFL 1.1）、
Markdown 解析 markdown-it（MIT）、EPUB 讀取 ZIPFoundation（MIT）、PDF 顯示 pdf.js（Apache-2.0）。
字型的授權條文在 `Resources/fonts/`，ZIPFoundation 的在 `Resources/licenses/`，pdf.js 的在
`Resources/web/vendor/pdfjs/`，組 `.app` 時都會一起複製進去。
