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

## 3. 架構

```
SwiftUI（視窗、選單、Finder 關聯、檔案監聽、側欄）
        │  postMessage / evaluateJavaScript
        ▼
WKWebView（內容區，一個視窗一份）
        │
        ├── markdown-it 14.x（內嵌，vendored，不走網路）
        ├── base.css ＋ themes/{terminal,reading}.css
        └── 內嵌 LXGW WenKai TC / LXGW WenKai Mono TC
```

Swift 端只做「殼」——開檔、監聽、選單、側欄資料。所有排版都在 CSS 裡，
所以「兩套主題」只是換一個 `<html data-theme>` 屬性。

Swift 端的狀態分三份（多視窗的緣故，見第 11 節）：

| | 範圍 | 內容 |
|---|---|---|
| `DocumentState` | 一個視窗一份 | 讀哪個檔、側欄、主題、字體、字級、外觀 |
| `AppSettings` | 全 App | 新視窗的起始設定、最近開啟、自訂主題目錄 |
| `WindowRouter` | 全 App | 哪些視窗開著、哪一個在前景、下一個檔案開到哪裡 |

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
| 標題（閱讀主題） | `#A2D2FC` | MarkEdit 編輯區標題色，截圖取樣 |
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
- 標題靠**字級**分層，顏色一律 `#A2D2FC` 淺藍（取樣自 MarkEdit 編輯區的標題色），
  不上橘色 —— 全篇只有粗體是橘的，重點詞才保有唯一性。藍與橘色相離得夠遠，
  標題與重點詞不會互相混淆
- 行內程式碼仍走 `SF Mono`
- 行高 1.9

### 4.4 外觀：深色／淺色（與主題正交）

第三個獨立的軸。主題決定版面、字體決定用哪套中文字、外觀決定明暗那一組顏色。
選單在「顯示方式 → 外觀」，比照 Safari：**自動**（跟隨系統）／**淺色**／**深色**。

**淺色不是把深色反過來。** `#DD9853` 是為深色底調的橘，放到暖白紙上對比只有
**2.28:1**，遠低於內文需要的 4.5:1。所以淺色維持同一個色相、往下壓到通過
WCAG AA 為止：

| 用途 | 深色 | 淺色 | 淺色對比 |
|---|---|---|---|
| 背景 | `#1C1C1C` | `#FAF8F3`（暖白紙，純白對楷體長文偏刺眼） | — |
| 內文 | `#CECECE` | `#2A2A2A` | 13.5:1 |
| 重點（粗體） | `#DD9853` | `#A2541A` | 5.2:1 |
| 標題（閱讀主題） | `#A2D2FC` | `#2C5C8A` | 6.6:1 |

實作上，淺色覆寫寫在**各自的主題檔裡**（`:root[data-theme="X"][data-appearance="light"]`），
不是集中在 base.css —— 這樣一個主題檔仍然自給自足，自訂主題複製一份就能改。

兩個踩過的坑：

- 強制淺色／深色時要設 `NSWindow.appearance`，否則只有網頁內容變色，
  視窗外框（側欄、工具列、標題列）還是系統的。設在 `NSApp` 也有效，
  但那是全 App 的，一個視窗切淺色會把所有視窗一起拖下去 —— 外觀是
  每個視窗各自的（第 11 節），所以要設在視窗上。
- 跟隨系統時**不要用 KVO 盯 `NSApp.effectiveAppearance`** —— 它不保證 KVO
  相容，實測系統切換時不會觸發，結果是側欄自己變淺了、網頁內容還留在深色。
  要聽系統廣播的 `AppleInterfaceThemeChangedNotification`。

### 4.5 字體（與主題正交）

中文字體是獨立於主題的第二個軸。主題決定顏色與版面，`data-font` 只決定用哪套中文字：

| | 楷體 `kai`（預設） | 黑體 `gothic` |
|---|---|---|
| 比例（閱讀主題） | LXGW WenKai TC | Sarasa Gothic TC |
| 等寬（終端機主題） | LXGW WenKai Mono TC | Sarasa Mono TC |

`base.css` 把這兩組寫成 `--cjk` / `--cjk-mono`，主題檔只引用變數。
自訂主題想跟著切換，`font-family` 寫 `var(--cjk)` 就好。

**黑體的粗體也不加粗。** `switch-font.sh` 的 gothic profile 在終端機裡是把粗體
升到 SemiBold 的，這裡刻意不跟 —— 兩套字體的行為要一致，粗體永遠只換色，
否則「粗體長什麼樣」會隨字體而變。實作上是 `@font-face` 只帶 Regular、
字重範圍開成 `100 900`，任何字重請求都落回同一個字面。

### 4.6 行寬

**隨視窗滿版**，只留固定左右內距（`3rem`），不設 `max-width`。
`Cmd +` / `Cmd -` 調字級，`Cmd 0` 重設。

## 5. 功能

| 功能 | 快捷鍵 | 說明 |
|---|---|---|
| 開新視窗 | `Cmd N` | 空白視窗，接著 `Cmd O` 或從側欄挑。Dock 圖示的右鍵選單也有 |
| 開檔 | `Cmd O` | 換掉目前視窗的內容。Finder 雙點擊走另一套政策，見第 11 節 |
| 最近開啟 | — | 檔案選單的子選單，最多 10 筆，自己存在 UserDefaults |
| 切主題 | `Cmd 1` / `Cmd 2` | 閱讀／終端機。每個視窗各自，新視窗沿用最後一次的選擇 |
| 切字體 | `Cmd 3` / `Cmd 4` | 楷體／黑體。同樣是每個視窗各自 |
| 切外觀 | — | 自動／淺色／深色。同樣是每個視窗各自 |
| 調字級 | `Cmd +` `Cmd -` `Cmd 0` | 每個視窗各自，最後一次的值存進 UserDefaults |
| 側欄 | `Cmd \` | 可收合，每個視窗各自 |
| 搜尋 | `Cmd F` | 全部命中高亮、顯示第 n／共 m、Enter 下一筆、Shift-Enter 上一筆 |
| 用 MarkEdit 開啟 | `Cmd E` | `NSWorkspace.open(_:withApplicationAt:)` |
| 列印／PDF | `Cmd P` | 白底黑字，粗體轉淺色模式那個 `#A2541A` |
| 重新載入 | `Cmd R` | 手動；平常靠自動重載 |

### 5.1 工具列

由左到右：側欄開關、**調色盤（主題與外觀）**、字體、字級加減、搜尋、
用 MarkEdit 開啟、列印。每個都給 `Label`（圖示＋標題），
使用者右鍵可以自己切換要不要顯示文字。

主題與外觀共用調色盤那一顆，用 `Divider()` 分成上下兩段 —— 分類上合理
（調色盤＝所有視覺設定），但**位置不明顯**，第一次找會找不到。
若之後要拆，選項是獨立一顆太陽／月亮按鈕，或補上快捷鍵
（`⌘1`–`⌘4` 已被主題與字體佔用）。

### 5.2 最近開啟

自己維護，不靠 `NSDocumentController` —— 這不是文件型 App，
系統那份清單管不到筆數上限，也不會把已刪掉的檔剔除。
存 10 筆路徑在 UserDefaults，載入時過濾掉已不存在的檔。

### 5.3 側欄

兩段式，上下同時顯示：

- **上半：同資料夾的 `.md`**。排序解析檔名裡的「第X章」，
  中文數字（一二三四五六七八九十）與阿拉伯數字都認；
  抽不出章號的（`附錄與後記`）排到最後，彼此之間按檔名。
  這是必要的 —— 字典序下 `第一章 / 第三章 / 第二章` 就是這個順序，
  兩個現有資料夾都亂掉。
- **下半：本文大綱**。`h1`–`h4`，點擊捲到該標題，捲動時高亮目前位置。

### 5.4 自動重載

用 `DispatchSource.makeFileSystemObjectSource` 監聽 `.write`／`.rename`／`.delete`，
去抖 150 ms。編輯器多半是「寫暫存檔再 rename」，所以 `rename`／`delete` 之後
要重新開 fd 重新掛監聽，否則只會收到一次事件。

重載後捲軸回原位：記下重載前**視窗頂端往下第一個標題的 id 與其偏移量**，
重載後找同 id 的標題捲回去。比純像素位置穩 —— AI 在你上方插入一段，
像素位置就整個位移了。

### 5.5 自訂主題與字型

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

圖片支援本機相對路徑。網頁不是用 `file://` 載入的，而是自訂 scheme `mbres://` ——
`loadFileURL(_:allowingReadAccessTo:)` 只能開放一個目錄樹，但同時要讀三個
不相干的地方：App 自己的網頁資源、目前文件所在資料夾（相對路徑圖片）、
以及 `~/.config/markdownbrowser/fonts`。

    mbres://app/…       → Contents/Resources/web/…
    mbres://doc/…       → 目前文件所在資料夾
    mbres://userfont/…  → ~/.config/markdownbrowser/fonts

渲染後由 JS 把相對路徑的 `img[src]` 改寫成 `mbres://doc/…`，否則它會相對於
頁面位址解析到 App 自己的資源目錄去。handler 會擋掉用 `../` 逃出根目錄的請求。

外部連結（`http`/`https`）用 `NSWorkspace` 丟給預設瀏覽器，不在 App 內導航。

## 7. 字型

內嵌進 `.app`，每套只需要 Regular 字面（粗體靠顏色，不靠字重）：

| 檔案 | 大小 | 用途 |
|---|---|---|
| `LXGWWenKaiTC-Regular.ttf` | 13 MB | 楷體・比例 |
| `LXGWWenKaiMonoTC-Regular.ttf` | 13 MB | 楷體・等寬 |
| `SarasaGothicTC-Regular.ttf` | 24 MB | 黑體・比例 |
| `SarasaMonoTC-Regular.ttf` | 26 MB | 黑體・等寬 |

成品 `.app` 約 73 MB，絕大部分是字型。

**不進版控。** `make` 時依序找 `~/books/fonts/` →
`~/Library/Fonts/` → 官方 GitHub release 下載到 `.cache/fonts/`。

兩個踩過的坑：

- 比例版 `LXGWWenKaiTC-*` 沒裝在系統，只在 `books/fonts/` 裡；等寬版兩處都有。
- Sarasa 官方**只提供 7z**，而且要整個家族一包（約 60 MB）才拿得到那一個字面，
  所以下載那條路需要 `7z`（`brew install p7zip`）。系統裡那份 Sarasa 是
  832 MB 的 `.ttc` 集合檔，拆不出單一 TTF，幫不上忙。

## 8. Finder 關聯

`Info.plist` 的 `CFBundleDocumentTypes` 宣告 `net.daringfireball.markdown`、
`public.markdown` 與副檔名 `md`/`markdown`/`mdown`/`mkd`，
`LSHandlerRank` 設 `Owner`，角色 `Viewer`。

`Info.plist` 裡宣告 `Owner` 只代表「我有能力開」，不等於預設程式 ——
真正的預設是使用者層級的設定。`make set-default` 會呼叫
`NSWorkspace.setDefaultApplication(at:toOpen:)` 明確指定，
等同 Finder 的「取得資訊 → 打開方式 → 全部更改」，`make status` 可以查目前是誰。

一個會踩到的坑：預設程式是**用 bundle ID 存的**，不是路徑。
所以同一個 bundle ID 有兩份副本被 LaunchServices 註冊時（建置產物與安裝的那份），
解析結果不一定是你要的那份。因此 `.app` 一律組在 `.build/` 底下，
`~/Applications` 的那份才是唯一會被開到的；`set-default-app.swift` 也
優先挑 `~/Applications` 而不是用 bundle ID 反查。

開檔走 `NSApplicationDelegate.application(_:open:)`，一次開多個檔就開多個視窗，
政策見第 11 節。

## 9. 建置與安裝

```bash
make          # 取字型 → swift build -c release → 組 .app → codesign --sign -
make install  # 複製到 ~/Applications 並 lsregister
make run          # 建置後直接開
make set-default  # 把 .md 的預設開啟程式設成這個 App
make status       # 查 .md 目前的預設開啟程式是誰
make clean
```

`.app` 由 Makefile 手工組出來：

```
.build/MarkdownBrowser.app/Contents/
  Info.plist
  MacOS/MarkdownBrowser
  Resources/web/{index.html,app.js,base.css,themes/,vendor/}
  Resources/web/fonts/*.ttf
  Resources/{zh-Hant,en}.lproj/      宣告語言，標準選單才會跟系統變中文
```

ad-hoc 簽章（`codesign --sign -`），第一次開可能要去
「系統設定 → 隱私權與安全性」放行。

## 10. 版控

private GitHub repo。`.gitignore` 排掉 `.build/`、`.cache/`、`*.app`、`Resources/fonts/*.ttf`。
Commit 訊息用中文祈使句，比照 書庫 repo的習慣。

---

## 11. 視窗模型

多視窗。一個視窗讀一個檔，關掉最後一個視窗就結束 App。

### 11.1 狀態怎麼切

單視窗版本只有一個 `AppState.shared`，所以 Finder 再開一個檔就把正在讀的那一份
蓋掉。拆法是按「範圍」切，不是按功能切（見第 3 節的表）：

- 一個視窗一份的東西放 `DocumentState` —— 讀哪個檔、側欄、主題、字體、字級、外觀
- 跨視窗共用的放 `AppSettings` —— 新視窗的起始設定、最近開啟、自訂主題目錄
- 「誰開著、誰在前景」放 `WindowRouter`

**主題與字體是每個視窗各自的。** 並排比對兩套主題是這個 App 的實際用法，
而「記住上次選的」仍然成立 —— 任何視窗改了設定就寫回 `AppSettings`，
當下一個新視窗的起始值。

**前景視窗用 `NSWindow` 的 key 通知自己記一份，不用 SwiftUI 的 focus。**
選單要作用在前景視窗上，`⌘F` 的按鍵監聽也要找到前景視窗的 bridge，
而 AppDelegate 與 `NSEvent` 監聽都在 SwiftUI 的 focus 環境之外拿不到。
`WindowRouter.active` 是唯一的來源。它同時把前景視窗自己的變化轉發出去
（`objectWillChange`），否則開了檔之後選單的啟用狀態不會重算。

### 11.2 開檔的兩套政策

| 入口 | 政策 |
|---|---|
| Finder 雙點擊、`open` 指令、拖到 Dock | **不動已經開著檔的視窗** |
| `Cmd O`、最近開啟、側欄點擊 | 換掉前景視窗的內容 |

Finder 那條依序試：已經有視窗在讀這個檔就帶到前景 → 還沒開檔的空白視窗載入它
→ 都沒有才開新視窗。第一條讓重複雙點擊不會開出兩個一樣的視窗，第二條讓
`Cmd N` 之後雙點擊不會多留一個空白視窗。

選單那條維持單視窗時的語意 —— 那是使用者當下指定的動作，要另開一個就先 `Cmd N`。

Dock 圖示右鍵的選單要自己給（`applicationDockMenu`）—— 那個選單不會自動抄
App 的選單列，SwiftUI 的 `Commands` 只長在選單列上。目前只放「開新視窗」。

### 11.3 SwiftUI 的三個坑

都是實測踩到的，改動視窗相關的程式前先讀這一段。

**`WindowGroup` 不要帶值。** `WindowGroup(for: T.self)` 看起來剛好可以用「這個
視窗在讀哪個檔」當視窗的身分，但 SwiftUI 會把那個值存起來做視窗還原，而視窗內
換檔時要把新值寫回 binding，寫回去又會被當成「請開一個新視窗」—— 於是視窗數
每次啟動都往上加（實測乾淨啟動被還原成三個視窗，而且那份狀態清 UserDefaults
也清不掉）。現在 `WindowGroup` 不帶值，「新視窗要讀哪個檔」由
`WindowRouter.handoffs` 這個佇列交棒，新視窗的 `onAppear` 自己來取。

**開檔會冒出空殼視窗。** App 每次收到開檔請求，SwiftUI 都會生一個視窗又馬上
丟掉（帶著檔案啟動、以及執行中被 Finder 要求開檔都會）。被丟掉的那個只是內容
被拆走，視窗本體還留在畫面上，就疊在真正的視窗底下 —— `isVisible` 與
`orderedWindows` 都認為它在。把開檔處理全部停掉也一樣發生，所以這是 SwiftUI
自己的行為。`WindowRouter.closeOrphanWindows` 負責收掉：只關「本來有
`DocumentState`、現在沒有」的視窗，不掃全部視窗 —— 開檔對話框與關於視窗也
都沒有 `DocumentState`，掃全部會把它們一起關掉。

**而且那個空殼會半路把檔案接走。** 它在消失之前是個合法的「還沒開檔的空白
視窗」，所以可能被挑去載入檔案，也可能先取走交棒佇列裡的檔 —— 兩種都會讓
檔案跟著它一起消失，畫面上什麼都沒發生。實測空殼消失與開檔請求只差 2 ms，
而視窗大、內容多的時候順序就會反過來（真的開不出來）。順序賭不起，所以
`openFromFinder` 之後 0.4 秒回頭確認：沒有任何活著的視窗在讀那個檔就重開一次，
最多三次。

**一個視窗都還沒有的時候不要搶著開窗。** 帶著檔案啟動時，AppKit 會叫 SwiftUI
收掉它預設開的那個視窗（啟動是為了開文件，不是為了開空白視窗），而 Finder 的
開檔請求剛好落在那個空檔裡。這時自己開窗，就會跟 SwiftUI 接著補上的那個視窗
撞成兩個。所以沒有視窗時先把檔案存起來，等下一個視窗出現再接手。

還有一個時機問題：視窗掛上 SwiftUI 的過程中會呼叫 `WindowRouter.register`，
在那裡直接開檔會撞進 SwiftUI 的更新週期，所以待開的檔要晚一個 runloop 才處理。
