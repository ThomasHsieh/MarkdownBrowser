# 命名：待決定

狀態：**中文名已定，英文名待決定。** 專案目錄、bundle ID、GitHub repo 一律維持
`MarkdownBrowser` / `com.thomashsieh.markdownbrowser`，不隨顯示名稱變動。

## 已定

**中文顯示名稱：硃閱**

「硃」取硃批的紅色批註意象，「閱」是翻閱。這個方向能解釋 App 為什麼用橘色
而不是加粗來標重點 —— 中世紀抄本的 rubrication 也是用紅色顏料標出章節與
要點，與「用顏色建立閱讀層次」的做法同源。

## 英文名：候選與查核

| 候選 | 狀態 | 說明 |
|---|---|---|
| **Cinnabar** | 語義首選 | 硃砂的英文就是 cinnabar，中英文指向同一顆礦物。同類別（Markdown 工具／閱讀器／Mac 生產力）無撞名；他類別有 Cinnabar Lab、Cinnabar Coil、git-cinnabar |
| Rubrino | 不建議 | 與 App Store 的 Rubino 只差一個字母，同一發音空間 |
| Vermil / Rubrum / Ochre / Ream / Minium / Verso / Lectio | 已排除 | 各有既有軟體或公司在用 |
| MarkScroll / MarkUnfold / MarkBrief | 不建議 | 無同名，但會沉進 Marked／MarkEdit 那片 `Mark-` 命名空間；且與「硃閱」的典故無關。MarkBrief 的語意還是錯的（本 App 不做摘要） |

## 查核過程留下的結論

**「全球軟體範圍內無同名、無近似」是達不到的門檻。** 任何真實存在、唸得出來、
有意涵的字，在全球軟體命名空間裡都已經被某個東西用掉了 —— 實測 Vermil、
Rubrum、Ochre、Ream、Minium 全部中彈。能過這個門檻的只有純造詞，而純造詞
會失去「有典故可講」這件事。

所以實際採用的門檻是**同類別無撞名**，理由是撞名的三種成本在這個 App 上都很低：
沒有商標註冊（非商業發行）、不需要被陌生人搜尋到（private repo 的個人工具）、
口頭指稱不會誤會。

## 決定之後要改的地方

- `CFBundleName`
- `zh-Hant.lproj/InfoPlist.strings` 的 `CFBundleDisplayName` → 硃閱
- `en.lproj/InfoPlist.strings` 的 `CFBundleDisplayName` → 英文名
- 三處寫死字串：`MarkdownBrowserApp.swift` 的 `Window(...)`、
  `ContentView.swift` 沒開檔時的 `navigationTitle`、`Resources/web/index.html` 的 `<title>`
- README、CHANGELOG、GitHub Release 標題
