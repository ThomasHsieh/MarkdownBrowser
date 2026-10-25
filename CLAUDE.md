# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

原生 macOS Markdown 閱讀器（唯讀）。完整規格在 `docs/SPEC.md`，動手前先讀。

## 建置與執行

沒有測試；`make check` 只檢查網頁端 JS 的語法（`make app` 會先跑）。驗證方式是
`make run` 後拿真實的中文 Markdown（`~/books/心得/`）開起來看。

改手感（捲動、動畫、按鍵、字型渲染）之前，先在安裝版（`~/Applications` 那份）上操作一次
記下**基準**；做完跟安裝版並排比過，再交給使用者驗收。

要看網頁端執行期的數值時，暫時加 `MB.debugLog(…)`，從終端機讀
`/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "com.thomashsieh.markdownbrowser"'`
（zsh 的 `log` 是內建指令，要寫完整路徑）。看完把呼叫拿掉。

```bash
make              # = make app：JS 語法檢查 → 取字型 → swift build -c release → 組 .app → ad-hoc 簽章
make check        # 只跑 node --check Resources/web/*.js（沒裝 node 就略過）
make run          # 建置後重開 .build/ 那份（舊的先正常結束，不動安裝版）
make test-copy ID=epubtest  # 另一個 bundle ID 的測試版，放 ~/Library/Caches/MarkdownBrowser-test/<ID>/
make test-clean ID=epubtest # 結束測試版、刪掉那個資料夾與它的 UserDefaults
make install      # 裝到 ~/Applications 並向 LaunchServices 註冊
make set-default  # 把 .md 的預設開啟程式設成這個 App
make status       # 查 .md 目前的預設開啟程式是誰
make icons        # 由 AppIcon-v4.png 重建透明書本圖層與 ICNS（通常不需執行）
make fonts-update # 發版前跑：字型有新版就改寫鎖定的版本、換掉快取
make release-zip  # 發版 commit 之後跑：查三處版號同步、沒有未 commit 的改動，打包 Release 附檔
make clean        # 清 .build/，保留 .cache/fonts
```

只改 CSS 或 JS 時仍要重跑 `make app` —— `Resources/web/` 是在組 `.app` 時
複製進 bundle 的，不是符號連結。

建置需要 **Xcode 26** 或更新版本，`actool` 要編 `AppIcon.icon`。字型不進版控，
`make` 時依序找 `$FONTS_DIR`（有設才找）→ `~/Library/Fonts/` → 官方 release
下載到 `.cache/fonts/`。每套字型都鎖定版本，找到的檔要讀出檔內記載的版本對得上才用
（`scripts/font-version.swift`）：檔名不帶版本的字型，只比檔名會用到放在那裡的任何一版。

## 架構

```
SwiftUI（視窗、選單、Finder 關聯、檔案監聽、側欄）
        │  evaluateJavaScript("MB.xxx(…)")  ↓
        │  webkit.messageHandlers.mb.postMessage({type, …})  ↑
        ▼
WKWebView（內容區：markdown-it + base.css，一欄一份）
        ├── highlights.js：標記與註記（docs/SPEC.md 第 12 節）
        ├── book.js：書那欄（docs/SPEC.md 第 13 節）
        └── bookpdf.js：書那欄的 PDF，用 vendor 的 pdf.js 畫（docs/SPEC.md 13.13）
```

對照模式下一個視窗有兩欄（左書右心得），各自一個 WKWebView。

Swift 端只做殼，**所有排版都在 CSS 裡**。切字體、切明暗只是換 `<html>` 上一個
屬性，Swift 完全不知道畫面長什麼樣。

多視窗。Swift 端的狀態按「範圍」切，不是按功能切：

| | 範圍 | 內容 |
|---|---|---|
| `PaneDocument` | 一欄一份 | 讀哪個檔、大綱、標記、sidecar、檔案監聽 |
| `DocumentState` | 一個視窗一份 | 心得那欄（繼承 `PaneDocument`）＋側欄、字體、字級、外觀、對照開關、`book` |
| `BookPane` | 一個視窗一份 | 書那欄（繼承 `PaneDocument`），`EpubBook` 或 `PdfBook` 與閱讀位置 |
| `AppSettings` | 全 App（單例） | 新視窗的起始設定、最近開啟 |
| `WindowRouter` | 全 App（單例） | 誰開著、誰在前景、下一個檔案開到哪裡 |

- 設定用 `@Published` + `didSet` 同時寫回 `AppSettings`（當新視窗的起始值）
  並推給自己那個視窗的網頁端，沒有其他同步路徑
- `WebBridge` protocol 是 Swift → JS 的唯一介面，由 `WebPane.Coordinator` 實作，
  一欄一份。兩欄之間不直接溝通，一律經過 Swift 轉送（章名對應、換檔、搬視窗都要 Swift）
- JS → Swift 有十七種訊息：`ready`、`outline`、`activeHeading`、`openExternal`、除錯用的 `debugLog`，
  標記的 `highlights`、`saveHighlights`、`copy`、`bannerAction`，以及對照的
  `headingClicked`、`quoteClicked`、`bookPosition`、`focus`、`pageKey`、`scrollKey`、`switchPane`，
  以及 PDF 的書籤 `bookToc`。需要回傳值的呼叫（`highlightSelection`、`commitNote`、
  `probeHighlights`）用 `evaluateJavaScript` 的完成回呼拿，不另外設計訊息
- **選單與按鍵監聽一律作用在 `WindowRouter.active` 上。** SwiftUI 的 focus 環境在
  `AppDelegate` 與 `NSEvent` 監聽那邊拿不到，所以前景視窗自己用 `NSWindow` 的
  key 通知記一份，來源唯一
- 開檔有兩套政策：Finder 走 `openFromFinder`（**不動已經開著檔的視窗**），
  選單與側欄走 `openInActiveWindow`（換掉前景視窗）。細節見 `docs/SPEC.md` 第 11 節
- **一檔一窗**：同一個檔只會開在一個視窗裡，視窗內換檔一律走
  `WindowRouter.open(_:in:)`，不要直接呼叫 `DocumentState.open`。每個視窗的網頁端
  各自是標記資料的唯一真相，同一個檔開兩份就會互相覆蓋 sidecar。**EPUB 也一樣**：
  「誰在讀這個檔」要同時看心得與書兩欄（`isShowing`）；對照時書或心得在別的視窗，
  就用 `WindowRouter.takeBook` / `takeNote` 搬過來（SPEC 13.7），不是開第二份

### 書與對照

EPUB 的規格在 `docs/SPEC.md` 第 13 節。最容易被改壞的：

- **書的 CSS 只拿來讀，不拿來顯示**。`book.js` 在看不見的 iframe 裡套書的 CSS，用
  `getComputedStyle` 轉成 `mb-b`／`mb-i`／`mb-center`… 再全部丟掉。直接套書的 CSS，
  書裡的粗體就會真的加粗，違反核心不變量
- 書的配對與章節對應是開檔當下算的（`BookPairing`、`ChapterMap`），不存書目。
  只有手動指定、各資料夾上次讀的心得、書的閱讀位置存在 UserDefaults
- 改 `ChapterMap` 的比對規則之前，先拿現有四本書（書 A、書 B、書 C、
  書 D）跑一遍看結果 —— SPEC 13.6 那幾條規則都是被真實資料逼出來的
- **PDF 照原樣顯示**，粗體照樣加粗，跟固定版面 EPUB 同一個例外（SPEC 13.13）。`book.js` 只在
  幾個分岔點（渲染、位置、同步、按鍵、版面）轉給 `bookpdf.js`。書那欄的檔案經 `BookResources`
  （`EpubBook`／`PdfBook`）從 `mbres://book/` 送
- **PDF 的一切都掛在頁框上**：canvas、文字層、標記框、搜尋命中、閃示都是 `.mb-pdf-page` 的子元素，
  頁框開檔就全部在；翻頁模式只隱藏、不重建。新功能照這個做，標記與搜尋才不必跟著翻頁重來
- **PDF 全文只有一份**（`P.text`）：抽字時逐字正規化康熙部首、照 13.13 接起換行，並記下每個文字項目
  在頁內的起點（`itemStarts`）。標記、搜尋、引文、選取換算、字的框都靠它；改全文的組法就要一起看
  `lineRects` 與 `offsetAt`

### 標記

**網頁端（`highlights.js`）是標記資料的唯一真相**，Swift 只負責讀寫 sidecar 檔
（`<原檔名>_highlights.json`）與鏡像給側欄。合併、擦除、錨點比對都需要渲染後的
文字位置，只有網頁端拿得到。完整規格在 `docs/SPEC.md` 第 12 節，三條最容易被改壞的：

- **只有使用者的動作才寫檔**。打開、重載、重新比對、發現對不上都不寫，否則唯讀
  閱讀器光是打開來看就會在 git 裡留下變動。唯一的例外是跟著 `.md` 改名
- **sidecar 讀不出來（合併衝突、版本太新）一律唯讀、絕不覆蓋**
- 錨點是引文（exact／prefix／suffix／heading），**不存偏移量**。重載同一份文件時
  `render` 不帶 `highlights`，網頁端沿用記憶體裡的標記重新比對

`highlights.js` 綁 DOM 的事（取全文、位置提示、選取換算、畫標記、找滑鼠下的標記）都經過
**文字來源** `src()`：心得與 EPUB 是檔內的 DOM 版，PDF 是 `MBBook.pdfSource`。新增要碰 DOM 的
標記邏輯就加進這個介面、兩邊都實作，第 12 節的規則才維持一份。PDF 的位置提示存在 `page`、
不寫 `heading`（SPEC 12.4）。

### 兩個正交的軸

樣式只有一套（`base.css`，取捨見 `docs/SPEC.md` 4.2 節），沒有主題可選。
字體與外觀互不相干，各自是 `<html>` 上一個屬性：

| 軸 | 屬性 | 值 | 決定 |
|---|---|---|---|
| 字體 | `data-font` | `kai`（預設）/ `gothic` / `ming` / `round` | 用哪套中文字 |
| 外觀 | `data-appearance` | `light` / `dark`（`auto` 由 Swift 解析後才送） | 明暗那一組顏色 |

兩個軸都是**每個視窗各自的**，存在 UserDefaults 的那一份只是新視窗的起始值。

顏色一律是 `base.css` 開頭的 CSS 變數：`:root` 是深色，`:root[data-appearance="light"]`
覆寫淺色。規則裡不要寫死顏色，否則明暗切換會漏掉它。

## 不可違反的核心不變量

**粗體永不加粗，只換成橘色**。這是整個 App 存在的理由（見 `docs/SPEC.md` 第 1 節）。
中文字加粗會糊成一團，所以重點訊號完全交給顏色。實作上有三層保險，任何一層
都不要拆：

1. `@font-face` 只帶 Regular 字面，`font-weight: 100 900` —— 任何字重請求都
   落回同一個字面
2. `base.css` 的 `font-synthesis-weight: none` 與 `-webkit-font-synthesis: none`
3. `strong` 一律 `font-weight: normal` 加 accent 色

黑體的粗體也不加粗。兩套字體的行為要一致，否則「粗體長什麼樣」會隨字體而變。

## 改動時的連動點

- **新增 bridge 方法**：三處要一起改 —— `DocumentState.swift` 底部的 `WebBridge`
  protocol、`WebPane.Coordinator` 的實作、`app.js` 的 `MB.xxx`（標記相關的在
  `highlights.js`，書相關的在 `book.js`）
- **新增顏色變數**：`base.css` 的 `:root` 與 `:root[data-appearance="light"]` 兩組都要給，
  `print.css` 也要看要不要蓋（列印一律白底）。標記的 `--hl-*` 淺色那組要另外驗算
  標記內粗體（`--hl-accent`）的對比
- **淺色不是把深色反過來**。`#DD9853` 在暖白紙上對比只有 2.28:1，淺色要維持
  同色相往下壓到通過 WCAG AA。現行值見 `docs/SPEC.md` 4.4 節的對照表
- **新增選單項目**：`MarkdownBrowserApp.swift` 的 `menus`，動作對象是
  `router.active`（Picker 用 `activeBinding(_:fallback:)`）；工具列在
  `ContentView.swift` 的 `toolbarItems`，直接用自己視窗的 `state`。
  `⌘N`、`⌘O`、`⌘3`～`⌘6`（字體）、`⇧⌘H`、`⇧⌘B`、`⌃Tab`（tab 模式切欄）、`Tab`（對照時切到另一欄）已被佔用；`⌘1`／`⌘2` 原本是主題，現在空著
- **選單與按鍵作用在焦點欄**：搜尋、列印、標記走 `router.active?.focusedBridge`，
  不是 `bridge`（那只是心得那欄）
- **對照並排時按鍵綁目標不綁焦點**（SPEC 13.5）：左右與空白翻書，其他捲心得；
  書在捲動模式時上下鍵才跟著焦點。兩個方向各一條轉送（`pageKey`、`scrollKey`），
  要不要轉由 `DocumentState.pushLinked` 推給兩欄，翻頁還是捲動模式由 `book.js` 自己判斷。
  切焦點欄不能只改 `focusedPane`，還要把 first responder 交給那一欄的 WKWebView（`takeFocus`），
  否則外框移過去了，按鍵還是送到原來那欄。`Tab` 有兩條路：鍵盤焦點在網頁上時由網頁端攔
  （只有它知道是不是正在打字），不在網頁上（剛開檔時常在側欄）時由 `installKeyMonitor` 直接切

## 踩過的坑（改到附近時別踩回去）

程式碼裡的註解都寫了為什麼，動之前先讀那段註解。最容易再次踩到的幾個：

- `.app` 一律組在 `.build/` 底下。預設開啟程式是**用 bundle ID 存的**，
  同一個 bundle ID 有兩份副本被 LaunchServices 註冊時會解析錯那份
- 視窗外框的明暗用 `preferredColorScheme`（掛在 `DocumentWindow`），**不要自己設
  `NSWindow.appearance`**：SwiftUI 每次更新環境都會把它寫回自己認定的值，兩邊搶著寫，
  來回切幾次標題列、側欄、內文就各自卡在不同明暗。`auto` 也不交 nil，交系統目前的
  明暗 —— 從 `.light` 改回 nil 時側欄會留在淺色。也不要設 `NSApp.appearance`（全 App 的）
- 跟隨系統時**不要用 KVO 盯 `NSApp.effectiveAppearance`**，它不保證 KVO 相容。
  要聽 `AppleInterfaceThemeChangedNotification`
- `⌘F` / `⌘G` 走 `NSEvent` local monitor 而不是選單快捷鍵：從選單觸發時
  menu tracking 結束後焦點會回到網頁，搜尋框的 `focus()` 當場被吃掉。
  比對 `keyCode`（3 = F、5 = G）而不是字元，注音輸入法下字元會是「ㄑ」
- `FileWatcher` 收到 `.rename` / `.delete` 後必須重開 fd 重掛監聽 ——
  編輯器多半是「寫暫存檔再 rename」，不重掛就只會收到一次事件
- 不聽 `.attrib`：讀檔本身會更新 atime，會變成「讀→事件→再讀」的迴圈
- 重載後捲軸靠**標題的 slug id** 回位，不是像素位置也不是出現順序編號 ——
  AI 在上方插入一段時，像素與序號都會整排位移
- Swift → JS 的字串一律走 `Coordinator.literal()`（JSON 編碼）。心得檔裡有
  反引號、`${` 與全形標點
- 網頁資源走自訂的 `mbres://` scheme 而不是 `file://`：
  `loadFileURL(_:allowingReadAccessTo:)` 只能開放一個目錄樹，而我們要同時讀
  `app`（bundle 網頁資源）、`doc`（文件所在資料夾）、`book`（EPUB 裡面）三個位置
- `Package.swift` 刻意停在 Swift 5 language mode，也刻意不用 SPM resources。
  全在主執行緒的 App，嚴格併發檢查只會製造 `@Sendable` 樣板
- **`WindowGroup` 刻意不帶值。** 用 `WindowGroup(for:)` 把「視窗在讀哪個檔」
  當視窗身分，會讓 SwiftUI 存起來做還原，而視窗內換檔要寫回 binding，
  寫回去又被當成「請開新視窗」—— 視窗數每次啟動都往上加。改用
  `WindowRouter.handoffs` 佇列交棒
- **開檔時 SwiftUI 會生一個視窗又丟掉**，被丟掉的那個只是內容被拆走，
  本體還疊在畫面上。`closeOrphanWindows` 只收「本來有 `DocumentState`、
  現在沒有」的視窗 —— 掃全部視窗會把開檔對話框一起關掉
- **那個空殼會半路把檔案接走**：消失之前它是個合法的「空白視窗」，會被挑去
  載入檔案或取走交棒佇列裡的檔，檔案就跟著它一起消失（實測只差 2 ms，視窗一大
  順序就反過來）。所以 `openFromFinder` 之後要回頭確認真的開在活著的視窗裡，
  沒有就重開 —— 別把這段拿掉
- `FileWatcher` 收到 `.rename` 時要**趁 fd 還開著**用 `fcntl(F_GETPATH)` 問新路徑，
  再晚一點確認舊路徑沒有又出現 —— 那是編輯器的原子存檔，不是改名
- **測試建置版時別跟安裝版混在一起**：兩份是同一個 bundle ID，也共用同一組
  UserDefaults。`open -n` 開測試版會把測試檔寫進「最近開啟」與「上次讀的檔」；
  用 bundle ID 帶到前景的工具（UI 自動化的前景模式、`⌘Q`）可能作用到安裝版
- **一個視窗都沒有時不要搶著開窗**，先存起來等 SwiftUI 那個視窗出現再接手；
  `register` 裡待開的檔要晚一個 runloop 處理，否則撞進 SwiftUI 的更新週期
- **書的圖片不能在讀 CSS 的 iframe 裡開始載**：iframe 一拿掉，還沒載完的全部中斷變破圖。
  圖少的書剛好來得及，看不出問題；《書 D》101 張圖幾乎全破。位址先放 `data-mb-src`
- **書的 CSS 要一章一章套**：某一頁自帶的 `<style>p{...}</style>` 整本一起套就會漏到全書。
  轉語意 class 時「粗體改回一般」（`mb-nb`）、「置中改回靠左」（`mb-left`）也要轉 ——
  粗體是顏色，會往下繼承
- **翻頁模式的多欄容器上下不能有 padding**：WebKit 會把上下 padding 再扣一次當分頁高度，
  頁尾冒出切掉一半的殘字、段落中間多一行空白。上方留白用 margin，頁高用 calc 扣掉留白。
  另外段落第一行被推到下一頁時，上一頁底部還會畫出一截殘影 —— `fixPushedLines` 偵測後
  讓那段直接從下一頁開始，版面一變就要重跑
- **翻頁模式的頁寬用小數**（`getBoundingClientRect().width`，不是 `clientWidth`），算元素在第幾頁
  以目前這一頁為基準。四捨五入的誤差每頁 0.25px，幾十頁後就把元素算進前一頁
- **calibre 轉出來的書常沒有標題標籤**，章節標題是加大加粗的 `<p>`。`book.js` 會升格成標題，
  層級照書的目錄；改這段之前拿《書 E》試
- **翻頁模式橫向捲動的是 `#content`，不是文件**：根元素 `overflow: hidden` 之後
  `window.scrollTo` 橫向沒反應。翻頁模式下要跳到某個元素一律走 `reveal()`，
  不要直接 `scrollIntoView`（會停在兩頁中間）
- **版面在回位之後還會變**：圖片與字型晚到會讓整本重新斷行。回位、同步之後都要再校正一次
  （`afterLayout`、`settleOn`），而且使用者自己動過就不能再拉回去。欄寬改變（拖分隔線、縮放視窗）
  也一樣會漂，`app.js` 在 resize 時回到捲動停下時記住的位置
- **整本書串成一條時，任何「每個標題做一次 O(n)」的事都會變慢**：`highlights.js` 的
  `headingOffsets` 是一次走完整份文件算的，不要改回每個標題各建一個 Range
- **兩個 `WebPane` 不能因為切雙欄／tab 而改變視圖結構**，只能改大小與透明度，
  否則 SwiftUI 會重建 WKWebView（見 `ReadingArea`）
- **實機測試用 `make test-copy`**：另一個 bundle ID 的副本，UserDefaults 跟安裝版分開，
  不會把測試檔寫進「最近開啟」。測試檔放它印出的資料夾，用完 `make test-clean`。標記要測就拿 EPUB 或 PDF 的**複本**（不是捷徑：
  開檔會解析捷徑，sidecar 就寫到原檔旁邊），別在 `~/books/` 旁邊生出 sidecar。AX 式的 UI 自動化
  點不到 SwiftUI 的 List 與分段控制；用 `CGEvent` 送真的滑鼠點擊就點得到（終端機要有輔助使用權限）。
  但送到 HID 的事件會跟使用者搶前景，使用者正在用別的 App 時按鍵會送進那個 App。按鍵改用
  `CGEvent.postToPid` 直接送給測試版，App 在背景也收得到、不必帶到前景。滑鼠不行：`postToPid`
  的點擊送不進 SwiftUI 控制項，要點側欄或分段控制時先跟使用者說好再用 HID。能繞就繞，例如版面模式
  在 App 關著時用 `defaults write` 改測試版的設定再重開。
  `screencapture -l` 也會抓到 SwiftUI 隱藏的空視窗，先確認視窗標題再截
- **測試檔放家目錄底下**（例如 `~/Library/Caches/…`），不要放 `/tmp`：開檔時
  `resolvingSymlinksInPath` 把 `/private/tmp` 變成 `/tmp`，列資料夾卻得到 `/private/tmp`，
  同一份心得比對不起來，章節對應整個失效，看起來像同步壞了
- **PDF 不能走 `mbres://doc/`**：那支回沒有狀態碼的 `URLResponse`，pdf.js 當成失敗；網頁在
  `mbres://app`，`fetch` 它又是跨來源被擋。PDF 走 `mbres://book/`（`HTTPURLResponse` 帶 CORS）
- **WKWebView 不支援 canvas 的 `ctx.filter`**（讀回 `undefined`、設了不報錯），pdf.js 的
  `pageColors` 因此完全沒作用。要替 canvas 換色只能用 CSS `filter` 或自己處理像素
- **PDF 的書籤與全文是網頁端事後讀的**，比 Swift 的配對、同步、標記載入都晚到。用到它們的動作
  先存著、到了再做（`pendingOpenSync`、`P.pendingSync`、`P.hlPayload`），別假設開檔當下就有
- **雙頁的章首常在右頁**：翻頁模式記住跳到的那一頁（`P.cur`），翻頁才以跨頁為單位。換成跨頁的
  左頁的話，章名、`Home`／`End`、翻頁跨章換心得都會算成上一章

## 慣例

- 註解與 commit 訊息都用中文。commit 用祈使句，說明**為什麼**而不是改了什麼
- 註解只寫「為什麼這樣做」與「試過什麼失敗了」，不複述程式碼
- 版本號用日期 `YYYY.MM.DD`（`Info.plist` 的 `CFBundleShortVersionString`、`CFBundleVersion`
  與 `CHANGELOG.md` 三處要同步）。`Info.plist` 用文字替換改那兩行，`PlistBuddy -c Set` 會把整個檔
  重新排版，diff 變成上百行。發版前先跑 `make fonts-update`，字型換了版就 `make run` 看過
  字形與行距，`fetch-fonts.sh` 的版本號跟著那次發版 commit
- 明確不做的事：編輯功能、書庫管理、Mermaid、KaTeX（EPUB 對照不算書庫管理，見 SPEC 第 2 節）
- 命名尚未定案。中文名「硃閱」已定，英文名待決定，目前語義首選 Cinnabar；
  現況與待改清單見 `docs/NAMING.md`（根目錄的 `APP-NAMING.md` 是較早的
  發想紀錄）。專案目錄與 bundle ID 維持 `MarkdownBrowser` /
  `com.thomashsieh.markdownbrowser`，未經指示不要改名
