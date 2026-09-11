# MarkdownBrowser 規格

原生 macOS Markdown 閱讀器。目標是把 Claude Code 在 cmux／ghostty 裡的中文閱讀體驗，
搬到一個能雙點擊開啟、能列印、能自訂樣式的 App 裡。

版本：v1
日期：2026-09-11

---

## 1. 為什麼要有這個 App

陪讀電子書的流程會產出大量繁體中文心得 Markdown（`~/books/心得/`，
一本書一個資料夾、一章一個檔，13–27 KB）。這些檔案在終端機裡讀起來很好，
但匯入 Notion 或用 MarkEdit Preview 看都失真，關鍵失真點是**粗體**：

終端機的做法是 `ghostty/config` 裡這一組設定 ——

```
font-family = "SF Mono"
font-family = "LXGW WenKai Mono TC"
font-family-bold = "SF Mono"
font-family-bold = "LXGW WenKai Mono TC Light"
font-synthetic-style = no-bold
bold-color = #DD9853
```

也就是：**中文粗體不加粗，只換成橘色**。中文字加粗會糊成一團，
所以重點訊號完全交給顏色。一般 Markdown viewer 把 `**粗體**` 渲染成
`font-weight: bold`，中文就糊了，而且沒有顏色差，整頁看起來一片平。

v1 要重現的就是這件事，外加一套排版比終端機更好的閱讀主題。

## 2. 不做什麼

- 不做編輯。這是唯讀的閱讀器，要改內容用 `Cmd+E` 丟給 MarkEdit。
- 不做書庫管理。沒有資料庫、沒有索引、沒有標籤。
- 不做 Mermaid、不做 KaTeX。各自要背一個幾百 KB 的 JS 引擎，而現有心得檔一個都沒用到。
- v1 不做淺色模式。兩套主題都是深色。

## 3. 架構

```
SwiftUI（視窗、選單、Finder 關聯、檔案監聽、側欄）
        │  postMessage / evaluateJavaScript
        ▼
WKWebView（內容區）
        │
        ├── markdown-it 14.x（內嵌，vendored，不走網路）
        ├── base.css ＋ themes/{terminal,reading}.css
        └── 內嵌 LXGW WenKai TC / LXGW WenKai Mono TC
```

Swift 端只做「殼」——開檔、監聽、選單、側欄資料。所有排版都在 CSS 裡，
所以「兩套主題」只是換一個 `<html data-theme>` 屬性。

- 專案：`~/workspace/MarkdownBrowser`
- Bundle ID：`com.thomashsieh.markdownbrowser`
- 最低系統：macOS 14
- 建置：`Package.swift` ＋ `Makefile`，不用 `.xcodeproj`（pbxproj 難以手改與 review）

## 4. 主題

### 4.1 共通不變量

**粗體永不加粗。** `strong` 一律 `font-weight: normal`，改上 accent 色。
`-webkit-font-smoothing` 與 `font-synthetic-weight: none` 都要明確關掉合成粗體，
否則 WebKit 會替沒有 Bold 字面的字型合成假粗。

從截圖取樣得到的實際顏色：

| 用途 | 值 | 來源 |
|---|---|---|
| 背景 | `#1C1C1C` | 截圖取樣 |
| 內文 | `#CECECE` | 截圖取樣 |
| 重點（粗體） | `#DD9853` | `ghostty/config` 的 `bold-color` 宣告值 |
| 引言左側直線 | `#757575` | 截圖取樣 |
| 框線 | `#CECECE`（終端機）／`#3A3A3A`（閱讀） | 終端機的 box-drawing 就是內文色 |

### 4.2 終端機主題（`terminal`）

盡量貼近截圖。

- 中文 `LXGW WenKai Mono TC`，英數 `SF Mono`
- 標題與內文**同字級**，標題上 accent 色（終端機沒有字級可用，只能靠顏色分層）
- 表格：等寬字，框線用 CSS `1px` 細線而不是 box-drawing 字元。
  真對齊要自己算雙寬字元寬度、自己折行、自己補空白，是整個專案裡最貴的一塊，
  而畫面差別只在框線粗細
- 行內程式碼與內文同色，只換等寬字面

### 4.3 閱讀主題（`reading`，預設）

排版重做，但視覺語言不變。

- 中文、英數全部用 `LXGW WenKai TC`（比例版，自帶拉丁字），開 `tabular-nums`
  讓表格裡的金額縱向對齊
- 標題靠**字級**與米白色分層，不上橘色 —— 全篇只有粗體是橘的，
  重點詞才保有唯一性
- 行內程式碼仍走 `SF Mono`
- 行高 1.9

### 4.4 行寬

**隨視窗滿版**，只留固定左右內距（`3rem`），不設 `max-width`。
`Cmd +` / `Cmd -` 調字級，`Cmd 0` 重設。

## 5. 功能

| 功能 | 快捷鍵 | 說明 |
|---|---|---|
| 開檔 | `Cmd O` | 也支援 Finder 雙點擊與拖放 |
| 切主題 | `Cmd 1` / `Cmd 2` | 終端機／閱讀，記住上次選的 |
| 調字級 | `Cmd +` `Cmd -` `Cmd 0` | 存進 UserDefaults |
| 側欄 | `Cmd \` | 可收合 |
| 搜尋 | `Cmd F` | 全部命中高亮、顯示第 n／共 m、Enter 下一筆、Shift-Enter 上一筆 |
| 用 MarkEdit 開啟 | `Cmd E` | `NSWorkspace.open(_:withApplicationAt:)` |
| 列印／PDF | `Cmd P` | 白底黑字，粗體轉深赭 `#8A4B12` |
| 重新載入 | `Cmd R` | 手動；平常靠自動重載 |

### 5.1 側欄

兩段式，上下同時顯示：

- **上半：同資料夾的 `.md`**。排序解析檔名裡的「第X章」，
  中文數字（一二三四五六七八九十）與阿拉伯數字都認；
  抽不出章號的（`附錄與後記`）排到最後，彼此之間按檔名。
  這是必要的 —— 字典序下 `第一章 / 第三章 / 第二章` 就是這個順序，
  兩個現有資料夾都亂掉。
- **下半：本文大綱**。`h1`–`h4`，點擊捲到該標題，捲動時高亮目前位置。

### 5.2 自動重載

用 `DispatchSource.makeFileSystemObjectSource` 監聽 `.write`／`.rename`／`.delete`，
去抖 150 ms。編輯器多半是「寫暫存檔再 rename」，所以 `rename`／`delete` 之後
要重新開 fd 重新掛監聽，否則只會收到一次事件。

重載後捲軸回原位：記下重載前**視窗頂端往下第一個標題的 id 與其偏移量**，
重載後找同 id 的標題捲回去。比純像素位置穩 —— AI 在你上方插入一段，
像素位置就整個位移了。

### 5.3 自訂主題與字型

```
~/.config/markdownbrowser/
  themes/*.css     每個檔就是一套主題，自動出現在「主題」選單
  fonts/*.ttf      自動註冊成 @font-face，family 名 = 檔名（去副檔名）
```

內建兩套主題用**完全相同的格式**，可以直接複製出來改。
選單裡提供「開啟設定資料夾」與「把內建主題複製一份出來」。

自訂主題檔在 App 啟動時掃描一次，並持續監聽該資料夾 —— 改了 CSS 立刻生效。

## 6. Markdown 語法

markdown-it 預設 CommonMark ＋ 打開 GFM 需要的：`tables`、`strikethrough`、
`linkify`。`html: false`（心得檔沒有原生 HTML，關掉比較安全）。

圖片支援本機相對路徑。WKWebView 用 `loadFileURL(_:allowingReadAccessTo:)`，
`readAccessURL` 指向**檔案所在資料夾**，相對路徑圖片才讀得到。

外部連結（`http`/`https`）用 `NSWorkspace` 丟給預設瀏覽器，不在 App 內導航。

## 7. 字型

內嵌進 `.app`，只需要 Regular 字面（粗體靠顏色，不靠字重）：

- `LXGWWenKaiTC-Regular.ttf`（比例版，13 MB）
- `LXGWWenKaiMonoTC-Regular.ttf`（等寬版，13 MB）

**不進版控。** `make` 時依序找：

1. `~/books/fonts/`
2. `~/Library/Fonts/`
3. 都沒有 → 從 LXGW 官方 GitHub release 下載到 `.cache/fonts/`

比例版 `LXGWWenKaiTC-*` 目前沒裝在系統，只在 `books/fonts/` 裡；等寬版兩處都有。

## 8. Finder 關聯

`Info.plist` 的 `CFBundleDocumentTypes` 宣告 `net.daringfireball.markdown`、
`public.markdown` 與副檔名 `md`/`markdown`/`mdown`/`mkd`，
`LSHandlerRank` 設 `Owner`，角色 `Viewer`。

`.md` 目前由 MarkEdit 持有。LaunchServices 不准 App 自己搶預設程式，
安裝後要在 Finder 對任一 `.md` 按「取得資訊 → 打開方式 → 全部更改」一次。

開檔走 `NSApplicationDelegate.application(_:open:)`，一次開多個檔時只讀第一個
（v1 沒有分頁）。

## 9. 建置與安裝

```bash
make          # 取字型 → swift build -c release → 組 .app → codesign --sign -
make install  # 複製到 ~/Applications 並 lsregister
make run      # 建置後直接開
make clean
```

`.app` 由 Makefile 手工組出來：

```
MarkdownBrowser.app/Contents/
  Info.plist
  MacOS/MarkdownBrowser
  Resources/web/{index.html,app.js,base.css,themes/,vendor/}
  Resources/fonts/*.ttf
```

ad-hoc 簽章（`codesign --sign -`），第一次開可能要去
「系統設定 → 隱私權與安全性」放行。

## 10. 版控

private GitHub repo。`.gitignore` 排掉 `.build/`、`.cache/`、`*.app`、`Resources/fonts/*.ttf`。
Commit 訊息用中文祈使句，比照 書庫 repo的習慣。
