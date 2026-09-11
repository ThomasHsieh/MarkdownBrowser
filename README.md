# MarkdownBrowser

原生 macOS Markdown 閱讀器，把 Claude Code 在 cmux／ghostty 裡的中文閱讀體驗
搬進一個能雙點擊開啟的 App。

核心是一件事：**粗體不加粗，只換成橘色。** 中文字加粗會糊成一團，
所以重點訊號交給顏色 —— 這正是 `ghostty/config` 裡 `bold-color = #DD9853`
配上 `font-synthetic-style = no-bold` 在做的事，一般 Markdown viewer 做不到。

## 建置

```bash
make          # 取字型 → 編譯 → 組 .app → ad-hoc 簽章
make install  # 裝到 ~/Applications 並向 LaunchServices 註冊
make run      # 建置後直接開
```

字型不進版控，`make` 時依序找 `~/books/fonts/` → `~/Library/Fonts/`
→ 官方 release 下載。共四個 Regular 字面：霞鶩文楷（楷體）與更紗黑體（黑體）
各有比例版與等寬版。Sarasa 官方只提供 7z，那條路需要 `brew install p7zip`。

裝好之後，`.md` 的預設開啟程式要自己改一次：LaunchServices 不准 App 自己搶，
在 Finder 對任一 `.md` 按「取得資訊 → 打開方式 → 全部更改」。
ad-hoc 簽章的 App 第一次開可能要去「系統設定 → 隱私權與安全性」放行。

## 快捷鍵

| | |
|---|---|
| `⌘O` | 開檔 |
| `⌘1` / `⌘2` | 閱讀主題／終端機主題 |
| `⌘3` / `⌘4` | 楷體／黑體 |
| `⌘+` `⌘-` `⌘0` | 字級 |
| `⌘\` | 收合側欄 |
| `⌘F` / `⌘G` / `⇧⌘G` | 搜尋、下一筆、上一筆 |
| `⌘E` | 用 MarkEdit 開啟 |
| `⌘P` | 列印／匯出 PDF |
| `⌘R` | 手動重新載入 |

常用動作同時放在工具列。檔案選單有「最近開啟」，保留最近 10 個檔。

檔案在外部被改動時會自動重載並保留捲動位置 —— 陪讀時可以左邊讀、右邊讓 AI 繼續寫。

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
```

Swift 端只做殼，所有排版都在 CSS 裡，所以換主題只是換一個 `data-theme` 屬性。

## 授權

字型 LXGW WenKai TC 與 Sarasa Gothic（皆 SIL OFL 1.1）、
Markdown 解析 markdown-it（MIT）。
