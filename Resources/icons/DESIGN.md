# App 圖示

保留象牙白多層書頁、橘色 Markdown M、向下箭頭與閱讀短線。
背景採均勻的 `#1B1B1B`，不再把背景紋理、底板高光和書本一起當成單張圖片交給系統。

## 原生資產

`AppIcon.icon` 是 Icon Composer 文件，包含透明的書本圖層與獨立純色背景。
圖層的 Glass，以及群組的 Specular、Translucency、Shadow 都關閉，避免額外的材質與陰影。
macOS 自身的外輪廓呈現仍由系統控制。

`make` 使用 Xcode 26 的 `actool` 編譯成 `Assets.car`，透過 `CFBundleIconName` 接入 App。
另保留 `AppIcon.icns` 作為舊版系統的圖示資源，其輪廓使用 824/1024 的透明安全邊界。

## 來源與產生方式

- `AppIcon-v4.png`：保留左右多層書頁的原始母圖；書本本體不重新生成。
- `AppIcon.icon/Assets/Book.png`：由 `make icons` 產生的 1024 px 透明書本圖層。
- `AppIcon.icon/icon.json`：純色背景、圖層與材質設定。
- `AppIcon.png`、`AppIcon.icns`：由 `make icons` 產生的傳統圖示預覽與封裝。
- v2、v3 與其提示詞：保留先前設計來源。

`generate-icon.swift` 針對 v4 的深灰背景移除底色與外部陰影，保留書本本體像素。
邊緣先去除混入的灰底，再以預乘 alpha 輸出，最後用 Lanczos 產生各尺寸。
這個去背門檻是針對目前母圖設定，替換母圖後需要重新檢查透明邊緣。

## 驗證

除了檢查圖檔與簽章，也透過 `NSWorkspace.icon(forFile:)` 讀取已安裝 App 的
系統解析圖示，與本機 Obsidian 比對。這與直接顯示 PNG 不同，會包含 macOS 的圖示呈現效果。
