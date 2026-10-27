APP        := MarkdownBrowser
# 組在 .build/ 底下而不是專案根目錄：同一個 bundle ID 有兩份副本被
# LaunchServices 註冊時，.md 的預設程式會解析到開發那份，而它會被 make clean 砍掉。
BUNDLE     := .build/$(APP).app
BUNDLE_NAME := $(APP).app
BUILD_DIR  := .build/release
CACHE      := .cache/fonts
INSTALL_TO := $(HOME)/Applications
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# 實機測試用的副本：換一個 bundle ID，UserDefaults 才跟安裝版分開。放家目錄底下而不是 /tmp，
# 原因見 CLAUDE.md「測試檔放家目錄底下」
ID         ?= epubtest
TEST_ID    := com.thomashsieh.markdownbrowser.$(ID)
TEST_DIR   := $(HOME)/Library/Caches/MarkdownBrowser-test/$(ID)
TEST_APP   := $(TEST_DIR)/$(BUNDLE_NAME)

.PHONY: all build app check test fonts fonts-update icons icon-assets install run clean uninstall set-default status test-copy test-clean release-zip

all: app

icons:
	@CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/clang-module-cache" swift scripts/generate-icon.swift

icon-assets:
	@mkdir -p .build/icon-assets
	@xcrun actool Resources/icons/AppIcon.icon --compile .build/icon-assets \
		--output-format human-readable-text --app-icon AppIcon --include-all-app-icons \
		--platform macosx --minimum-deployment-target 14.0 \
		--output-partial-info-plist .build/icon-assets/Info.plist

# 讀字型檔裡記載的版本，fetch-fonts.sh 拿來確認找到的是鎖定的那一版
FONT_VERSION := .build/font-version
$(FONT_VERSION): scripts/font-version.swift
	@mkdir -p .build
	@swiftc -O -o $@ $<

fonts: $(FONT_VERSION)
	@echo "→ 取字型"
	@bash scripts/fetch-fonts.sh "$(CACHE)" "$(FONT_VERSION)"

# 發版前手動跑：有新版就改寫 fetch-fonts.sh 鎖定的版本並換掉快取（docs/SPEC.md 第 7 節）
fonts-update: $(FONT_VERSION)
	@echo "→ 檢查字型新版"
	@bash scripts/update-fonts.sh "$(CACHE)" "$(FONT_VERSION)"

# 連結器會把每個原始碼與 .o 的絕對路徑寫進除錯符號表（stabs），等於把這台機器的
# 使用者名稱與資料夾結構跟著 .app 一起散佈出去。發版的 .app 不附 dSYM，用 -S 叫
# 連結器不寫除錯資訊。試過 -file-prefix-map：路徑一處也沒少。
build:
	@echo "→ 編譯"
	@swift build -c release --disable-sandbox -Xlinker -S

# 網頁端的 JS 語法錯不會在建置時報，App 裡只是一片空白。沒裝 node 就略過，不擋建置
check:
	@if command -v node >/dev/null 2>&1; then \
		for f in Resources/web/*.js; do node --check "$$f" || exit 1; done; \
		echo "→ JS 語法檢查通過"; \
	else echo "  ⚠️  沒有 node，略過 JS 語法檢查"; fi

# 章節對應（ChapterMap）的比對規則。fixture 是自編的，私人書庫的總體檢見 CLAUDE.md「書與對照」
test:
	@swift test

app: check fonts build icon-assets
	@echo "→ 組 $(BUNDLE)"
	@rm -rf "$(BUNDLE)"
	@mkdir -p .build
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources/web/fonts"
	@cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp Resources/icons/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon-5.icns"
	@cp .build/icon-assets/Assets.car "$(BUNDLE)/Contents/Resources/Assets.car"
	@cp "$(BUILD_DIR)/$(APP)" "$(BUNDLE)/Contents/MacOS/$(APP)"
	@cp -R Resources/web/. "$(BUNDLE)/Contents/Resources/web/"
	@cp "$(CACHE)"/*.ttf "$(CACHE)"/*.otf "$(BUNDLE)/Contents/Resources/web/fonts/"
	@# 字型是 SIL OFL 1.1，散佈時要附授權條文
	@cp Resources/fonts/LICENSE-*.txt "$(BUNDLE)/Contents/Resources/web/fonts/"
	@# 編進執行檔的 ZIPFoundation 是 MIT，散佈時同樣要附授權聲明
	@mkdir -p "$(BUNDLE)/Contents/Resources/licenses"
	@cp Resources/licenses/LICENSE-*.txt "$(BUNDLE)/Contents/Resources/licenses/"
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
	@$(LSREGISTER) -f "$(INSTALL_TO)/$(BUNDLE_NAME)"
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

# 以測試版的 bundle ID 結束，碰不到安裝版與 .build/ 那份
define quit_test
	@osascript -l JavaScript -e 'ObjC.import("AppKit"); \
		const apps = $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("$(TEST_ID)").js; \
		apps.forEach(a => a.terminate); \
		for (let i = 0; i < 50 && apps.some(a => !a.terminated); i++) delay(0.1);' >/dev/null
endef

test-copy: app
	@case "$(ID)" in *[!a-zA-Z0-9-]*|"") echo "ID 只能有英數字與 -：$(ID)"; exit 1;; esac
	$(quit_test)
	@rm -rf "$(TEST_APP)"
	@mkdir -p "$(TEST_DIR)"
	@cp -R "$(BUNDLE)" "$(TEST_APP)"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(TEST_ID)" "$(TEST_APP)/Contents/Info.plist"
	@codesign --force --sign - --timestamp=none "$(TEST_APP)" >/dev/null 2>&1 \
		|| echo "  ⚠️  ad-hoc 簽章失敗，App 仍可執行"
	@echo "→ 測試版：$(TEST_APP)（$(TEST_ID)）"
	@echo "   測試用的書與心得放 $(TEST_DIR)/，用 open -a \"$(TEST_APP)\" <檔案> 開"
	@echo "   改設定：defaults write $(TEST_ID) <key> <value>（App 關著時改）；用完 make test-clean ID=$(ID)"

test-clean:
	@case "$(ID)" in *[!a-zA-Z0-9-]*|"") echo "ID 只能有英數字與 -：$(ID)"; exit 1;; esac
	$(quit_test)
	@# 跟 clean 一樣先取消註冊再刪
	@if [ -d "$(TEST_APP)" ]; then $(LSREGISTER) -u "$(TEST_APP)" 2>/dev/null || true; fi
	@rm -rf "$(TEST_DIR)"
	@# defaults delete 會留下一個空的 plist，一起刪
	@defaults delete "$(TEST_ID)" >/dev/null 2>&1 || true
	@rm -f "$(HOME)/Library/Preferences/$(TEST_ID).plist"
	@echo "→ 已清掉測試版 $(TEST_ID) 與 $(TEST_DIR)"

# GitHub Release 的附檔。先查三處版號同步（CLAUDE.md「慣例」）、已追蹤的檔沒有未 commit 的改動，
# zip 才對得上那個 tag。ditto 保留 .app 的權限與簽章，zip 指令會弄壞
release-zip: app
	@v=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist); \
	b=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist); \
	c=$$(sed -n 's/^## \([0-9.]*\).*/\1/p' CHANGELOG.md | head -1); \
	if [ "$${v}" != "$${b}" ] || [ "$${v}" != "$${c}" ]; then \
		echo "版號不一致：CFBundleShortVersionString $${v}、CFBundleVersion $${b}、CHANGELOG $${c}"; exit 1; fi; \
	if [ -n "$$(git status --porcelain --untracked-files=no)" ]; then \
		echo "有未 commit 的改動，zip 會對不上 tag："; git status --short --untracked-files=no; exit 1; fi; \
	rm -f ".build/$(APP)-$${v}.zip"; \
	ditto -c -k --keepParent "$(BUNDLE)" ".build/$(APP)-$${v}.zip" && \
	echo "→ .build/$(APP)-$${v}.zip（$$(( $$(stat -f %z ".build/$(APP)-$${v}.zip") / 1000000 )) MB）"

# 跟 clean 一樣先取消註冊再刪
uninstall:
	@if [ -d "$(INSTALL_TO)/$(BUNDLE_NAME)" ]; then $(LSREGISTER) -u "$(INSTALL_TO)/$(BUNDLE_NAME)" 2>/dev/null || true; fi
	@rm -rf "$(INSTALL_TO)/$(BUNDLE_NAME)"
	@echo "→ 已移除 $(INSTALL_TO)/$(BUNDLE_NAME)"

# 先取消註冊再刪：只刪資料夾的話 LaunchServices 還記著這份，.md 仍可能解析到已經不存在的它
# 從沒打開過的那份（只跑過 make install、make release-zip）沒有註冊，lsregister -u 會回 -10814 擋住後面的刪除
clean:
	@if [ -d "$(BUNDLE)" ]; then $(LSREGISTER) -u "$(CURDIR)/$(BUNDLE)" 2>/dev/null || true; fi
	@rm -rf .build
	@echo "→ 已清除（字型快取 $(CACHE) 保留）"
