# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

原生 macOS Markdown 閱讀器（唯讀）。完整規格在 `docs/SPEC.md`，動手前先讀。

## 建置與執行

沒有測試、沒有 linter。驗證方式是 `make run` 後拿真實的中文 Markdown（
`~/books/心得/`）開起來看。

```bash
make              # = make app：取字型 → swift build -c release → 組 .app → ad-hoc 簽章
make run          # 建置後直接開
make install      # 裝到 ~/Applications 並向 LaunchServices 註冊
make set-default  # 把 .md 的預設開啟程式設成這個 App
make status       # 查 .md 目前的預設開啟程式是誰
make icons        # 由 AppIcon-v4.png 重建透明書本圖層與 ICNS（通常不需執行）
make clean        # 清 .build/，保留 .cache/fonts
```

只改 CSS 或 JS 時仍要重跑 `make app` —— `Resources/web/` 是在組 `.app` 時
複製進 bundle 的，不是符號連結。

建置需要 **Xcode 26** 或更新版本，`actool` 要編 `AppIcon.icon`。字型不進版控，
`make` 時依序找 `~/books/fonts/` → `~/Library/Fonts/` → 官方 release
下載到 `.cache/fonts/`；Sarasa 那條下載路徑需要 `brew install p7zip`。

## 架構

```
SwiftUI（視窗、選單、Finder 關聯、檔案監聽、側欄）
        │  evaluateJavaScript("MB.xxx(…)")  ↓
        │  webkit.messageHandlers.mb.postMessage({type, …})  ↑
        ▼
WKWebView（內容區：markdown-it + base.css + themes/*.css，一個視窗一份）
```

Swift 端只做殼，**所有排版都在 CSS 裡**。切主題只是換 `<html>` 上一個
`data-theme` 屬性，Swift 完全不知道主題長什麼樣。

多視窗。Swift 端的狀態按「範圍」切成三份，不是按功能切：

| | 範圍 | 內容 |
|---|---|---|
| `DocumentState` | 一個視窗一份 | 讀哪個檔、側欄、主題、字體、字級、外觀 |
| `AppSettings` | 全 App（單例） | 新視窗的起始設定、最近開啟、自訂主題目錄 |
| `WindowRouter` | 全 App（單例） | 誰開著、誰在前景、下一個檔案開到哪裡 |

- 設定用 `@Published` + `didSet` 同時寫回 `AppSettings`（當新視窗的起始值）
  並推給自己那個視窗的網頁端，沒有其他同步路徑
- `WebBridge` protocol 是 Swift → JS 的唯一介面，由 `WebPane.Coordinator` 實作，
  一個視窗一份
- JS → Swift 只有四種訊息：`ready`、`outline`、`activeHeading`、`openExternal`
- **選單與按鍵監聽一律作用在 `WindowRouter.active` 上。** SwiftUI 的 focus 環境在
  `AppDelegate` 與 `NSEvent` 監聽那邊拿不到，所以前景視窗自己用 `NSWindow` 的
  key 通知記一份，來源唯一
- 開檔有兩套政策：Finder 走 `openFromFinder`（**不動已經開著檔的視窗**），
  選單與側欄走 `openInActiveWindow`（換掉前景視窗）。細節見 `docs/SPEC.md` 第 11 節

### 三個正交的軸

主題、字體、外觀互不相干，各自是 `<html>` 上一個屬性：

| 軸 | 屬性 | 值 | 決定 |
|---|---|---|---|
| 主題 | `data-theme` | `reading`（預設）/ `terminal` / 自訂檔名 | 版面與配色 |
| 字體 | `data-font` | `kai`（預設）/ `gothic` | 用哪套中文字 |
| 外觀 | `data-appearance` | `light` / `dark`（`auto` 由 Swift 解析後才送） | 明暗那一組顏色 |

三個軸都是**每個視窗各自的**，存在 UserDefaults 的那一份只是新視窗的起始值。

`base.css` 只放結構與 `--cjk` / `--cjk-mono` 的定義，顏色與字型一律由主題檔
的 CSS 變數提供。`:root` 裡那份變數是安全網，正常不會被用到。

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
  protocol、`WebPane.Coordinator` 的實作、`app.js` 的 `MB.xxx`
- **新增主題 CSS 變數**：`base.css` 的 `:root` 補安全網值，兩個主題檔都要提供
- **改主題顏色**：淺色覆寫寫在**各自的主題檔裡**（
  `:root[data-theme="X"][data-appearance="light"]`），不集中在 `base.css` ——
  這樣主題檔仍然自給自足，自訂主題複製一份就能改
- **淺色不是把深色反過來**。`#DD9853` 在暖白紙上對比只有 2.28:1，淺色要維持
  同色相往下壓到通過 WCAG AA。現行值見 `docs/SPEC.md` 4.4 節的對照表
- **新增選單項目**：`MarkdownBrowserApp.swift` 的 `menus`，動作對象是
  `router.active`（Picker 用 `activeBinding(_:fallback:)`）；工具列在
  `ContentView.swift` 的 `toolbarItems`，直接用自己視窗的 `state`。
  `⌘N`、`⌘O`、`⌘1`–`⌘4` 已被佔用

## 踩過的坑（改到附近時別踩回去）

程式碼裡的註解都寫了為什麼，動之前先讀那段註解。最容易再次踩到的幾個：

- `.app` 一律組在 `.build/` 底下。預設開啟程式是**用 bundle ID 存的**，
  同一個 bundle ID 有兩份副本被 LaunchServices 註冊時會解析錯那份
- 強制淺色／深色要設 `NSWindow.appearance`，不是 `NSApp.appearance`（那是全 App 的，
  外觀是每個視窗各自的）。完全不設的話只有網頁內容變色，側欄與工具列還是系統的
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
  `app`（bundle 網頁資源）、`doc`（文件所在資料夾）、`userfont` 三個位置
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
- **一個視窗都沒有時不要搶著開窗**，先存起來等 SwiftUI 那個視窗出現再接手；
  `register` 裡待開的檔要晚一個 runloop 處理，否則撞進 SwiftUI 的更新週期

## 慣例

- 註解與 commit 訊息都用中文。commit 用祈使句，說明**為什麼**而不是改了什麼
- 註解只寫「為什麼這樣做」與「試過什麼失敗了」，不複述程式碼
- 版本號用日期 `YYYY.MM.DD`（`Info.plist` 的 `CFBundleShortVersionString`
  與 `CHANGELOG.md` 要同步）
- 明確不做的事：編輯功能、書庫管理、Mermaid、KaTeX
- 命名尚未定案。中文名「硃閱」已定，英文名待決定，目前語義首選 Cinnabar；
  現況與待改清單見 `docs/NAMING.md`（根目錄的 `APP-NAMING.md` 是較早的
  發想紀錄）。專案目錄與 bundle ID 維持 `MarkdownBrowser` /
  `com.thomashsieh.markdownbrowser`，未經指示不要改名
