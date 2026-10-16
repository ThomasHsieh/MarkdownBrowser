APP        := MarkdownBrowser
# 組在 .build/ 底下而不是專案根目錄：同一個 bundle ID 有兩份副本被
# LaunchServices 註冊時，.md 的預設程式會解析到開發那份，而它會被 make clean 砍掉。
BUNDLE     := .build/$(APP).app
BUNDLE_NAME := $(APP).app
BUILD_DIR  := .build/release
CACHE      := .cache/fonts
INSTALL_TO := $(HOME)/Applications

.PHONY: all build app fonts icons icon-assets install run clean uninstall set-default status

all: app

icons:
	@CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/clang-module-cache" swift scripts/generate-icon.swift

icon-assets:
	@mkdir -p .build/icon-assets
	@xcrun actool Resources/icons/AppIcon.icon --compile .build/icon-assets \
		--output-format human-readable-text --app-icon AppIcon --include-all-app-icons \
		--platform macosx --minimum-deployment-target 14.0 \
		--output-partial-info-plist .build/icon-assets/Info.plist

fonts:
	@echo "→ 取字型"
	@bash scripts/fetch-fonts.sh "$(CACHE)"

build:
	@echo "→ 編譯"
	@swift build -c release --disable-sandbox

app: fonts build icon-assets
	@echo "→ 組 $(BUNDLE)"
	@rm -rf "$(BUNDLE)"
	@mkdir -p .build
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources/web/fonts"
	@cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp Resources/icons/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon-5.icns"
	@cp .build/icon-assets/Assets.car "$(BUNDLE)/Contents/Resources/Assets.car"
	@cp "$(BUILD_DIR)/$(APP)" "$(BUNDLE)/Contents/MacOS/$(APP)"
	@cp -R Resources/web/. "$(BUNDLE)/Contents/Resources/web/"
	@cp "$(CACHE)"/*.ttf "$(BUNDLE)/Contents/Resources/web/fonts/"
	@printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"
	@# 宣告語言，標準選單（檔案／編輯／顯示方式）才會跟系統一起變中文。
	@mkdir -p "$(BUNDLE)/Contents/Resources/zh-Hant.lproj" "$(BUNDLE)/Contents/Resources/en.lproj"
	@touch "$(BUNDLE)/Contents/Resources/zh-Hant.lproj/InfoPlist.strings" \
	       "$(BUNDLE)/Contents/Resources/en.lproj/InfoPlist.strings"
	@codesign --force --sign - --timestamp=none "$(BUNDLE)" >/dev/null 2>&1 \
		|| echo "  ⚠️  ad-hoc 簽章失敗，App 仍可執行"
	@echo "→ 完成：$(BUNDLE)"

set-default:
	@swift scripts/set-default-app.swift

status:
	@swift scripts/set-default-app.swift --status

install: app
	@mkdir -p "$(INSTALL_TO)"
	@rm -rf "$(INSTALL_TO)/$(BUNDLE_NAME)"
	@cp -R "$(BUNDLE)" "$(INSTALL_TO)/"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(INSTALL_TO)/$(BUNDLE_NAME)"
	@echo "→ 已安裝到 $(INSTALL_TO)/$(BUNDLE_NAME)"
	@echo "   要讓 Finder 雙點擊 .md 開這個 App，再跑一次：make set-default"

# 只結束 .build/ 那份舊的再開新的。直接 open 的話，同一個 bundle ID 已經在跑時
# 只會把舊的帶到前景，測到的是舊程式碼。用 terminate 正常結束（關窗前要寫完註記），
# 不用 kill；以 bundle ID 結束（osascript quit）會連安裝版一起關。
# 開新的用 open -n：安裝版開著時，不加 -n 會被帶到前景的是安裝版
run: app
	@osascript -l JavaScript -e 'ObjC.import("AppKit"); \
		const want = $$.NSURL.fileURLWithPath("$(CURDIR)/$(BUNDLE)").path.js; \
		const apps = $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.thomashsieh.markdownbrowser").js \
			.filter(a => a.bundleURL.path.js === want); \
		apps.forEach(a => a.terminate); \
		for (let i = 0; i < 50 && apps.some(a => !a.terminated); i++) delay(0.1);' >/dev/null
	@open -n "$(BUNDLE)"

uninstall:
	@rm -rf "$(INSTALL_TO)/$(BUNDLE_NAME)"
	@echo "→ 已移除 $(INSTALL_TO)/$(BUNDLE_NAME)"

clean:
	@rm -rf .build
	@echo "→ 已清除（字型快取 $(CACHE) 保留）"
