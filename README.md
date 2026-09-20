# MarkdownBrowser

原生 macOS Markdown 閱讀器，把 Claude Code 在 cmux／ghostty 裡的中文閱讀體驗
搬進一個能雙點擊開啟的 App。

核心是一件事：**粗體不加粗，只換成橘色。** 中文字加粗會糊成一團，
所以重點訊號交給顏色 —— 這正是 `ghostty/config` 裡 `bold-color = #DD9853`
配上 `font-synthetic-style = no-bold` 在做的事，一般 Markdown viewer 做不到。

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

字型不進版控，`make` 時依序找 `~/books/fonts/` → `~/Library/Fonts/`
→ 官方 release 下載。共四個 Regular 字面：霞鶩文楷（楷體）與更紗黑體（黑體）
各有比例版與等寬版。Sarasa 官方只提供 7z，那條路需要 `brew install p7zip`。

`make set-default` 會把 `.md` 的預設開啟程式指過來（等同 Finder 的
「取得資訊 → 打開方式 → 全部更改」）。ad-hoc 簽章的 App 第一次開
可能要去「系統設定 → 隱私權與安全性」放行。

## 快捷鍵

| | |
|---|---|
| `⌘N` | 開新視窗 |
| `⌘O` | 開檔（換掉目前視窗的內容） |
| `⌘1` / `⌘2` | 閱讀主題／終端機主題 |
| `⌘3` / `⌘4` | 楷體／黑體 |
| `⌘+` `⌘-` `⌘0` | 字級 |
| `⌘\` | 收合側欄 |
| `⌘F` / `⌘G` / `⇧⌘G` | 搜尋、下一筆、上一筆 |
| `⌘E` | 用 MarkEdit 開啟 |
| `⌘P` | 列印／匯出 PDF |
| `⌘R` | 手動重新載入 |

**深色／淺色沒有快捷鍵**，在兩個地方切換：選單「顯示方式 → 外觀」，
或工具列最左邊那顆**調色盤**按鈕 —— 主題在上、外觀在下，中間用分隔線隔開。
三種選擇是自動（跟隨系統）／淺色／深色。

工具列由左到右是：側欄開關、調色盤（主題與外觀）、字體、字級加減、搜尋、
用 MarkEdit 開啟、列印。檔案選單有「最近開啟」，保留最近 10 個檔。

檔案在外部被改動時會自動重載並保留捲動位置 —— 陪讀時可以左邊讀、右邊讓 AI 繼續寫。

## 多視窗

`⌘N` 開新視窗，Dock 圖示按右鍵也有「開新視窗」（App 要在執行中才看得到，
沒在跑的時候 macOS 只給「選項」那一組）。**Finder 雙點擊不會動到已經開著的視窗** —— 已經有視窗在讀那個檔
就把它帶到前景，有還沒開檔的空白視窗就用那一個，否則開新的。一次選多個檔按
Enter 就開多個視窗。

主題、字體、字級、外觀都是**每個視窗各自的**，可以左邊閱讀主題、右邊終端機主題
並排比對；新視窗沿用最後一次的選擇。側欄開合也是各視窗獨立。「最近開啟」與
自訂主題資料夾是全 App 共用。

`⌘O` 與「最近開啟」是換掉**目前視窗**的內容，要另開一個就先 `⌘N`。

## 自訂主題與字型

```
~/.config/markdownbrowser/
  themes/*.css     每個檔就是一套主題，自動出現在「主題」選單，改了立刻生效
  fonts/*.ttf      自動註冊成 @font-face，family 名就是檔名
```

內建兩套主題用完全相同的格式。「顯示方式 → 複製內建主題以供修改」會把它們
複製一份到上面的資料夾當起點。

## 結構

規格見 [`docs/SPEC.md`](docs/SPEC.md)。

```
Sources/MarkdownBrowser/   SwiftUI 外殼：視窗、選單、檔案監聽、側欄
Resources/web/             WKWebView 內容：markdown-it、base.css、兩套主題
Resources/Info.plist       Finder 關聯與 UTI 宣告
Resources/icons/           原生 AppIcon.icon、多尺寸 ICNS、母圖與設計說明
```

Swift 端的狀態分三份：`DocumentState` 是一個視窗一份（讀哪個檔、主題、字體），
`AppSettings` 是跨視窗共用的（新視窗的起始設定、最近開啟、自訂主題目錄），
`WindowRouter` 管哪些視窗開著、哪一個在前景、下一個檔案該開到哪裡。

Swift 端只做殼，所有排版都在 CSS 裡，所以換主題只是換一個 `data-theme` 屬性。

## 授權

字型 LXGW WenKai TC 與 Sarasa Gothic（皆 SIL OFL 1.1）、
Markdown 解析 markdown-it（MIT）。
