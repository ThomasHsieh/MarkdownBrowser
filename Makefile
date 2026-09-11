APP        := MarkdownBrowser
BUNDLE     := $(APP).app
BUILD_DIR  := .build/release
CACHE      := .cache/fonts
INSTALL_TO := $(HOME)/Applications

.PHONY: all build app fonts install run clean uninstall

all: app

fonts:
	@echo "→ 取字型"
	@bash scripts/fetch-fonts.sh "$(CACHE)"

build:
	@echo "→ 編譯"
	@swift build -c release --disable-sandbox

app: fonts build
	@echo "→ 組 $(BUNDLE)"
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources/web/fonts"
	@cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
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

install: app
	@mkdir -p "$(INSTALL_TO)"
	@rm -rf "$(INSTALL_TO)/$(BUNDLE)"
	@cp -R "$(BUNDLE)" "$(INSTALL_TO)/"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(INSTALL_TO)/$(BUNDLE)"
	@echo "→ 已安裝到 $(INSTALL_TO)/$(BUNDLE)"
	@echo "   .md 目前由 MarkEdit 持有。LaunchServices 不准 App 自己搶預設程式，"
	@echo "   要在 Finder 對任一 .md 按「取得資訊 → 打開方式 → 全部更改」一次。"

run: app
	@open "$(BUNDLE)"

uninstall:
	@rm -rf "$(INSTALL_TO)/$(BUNDLE)"
	@echo "→ 已移除 $(INSTALL_TO)/$(BUNDLE)"

clean:
	@rm -rf .build "$(BUNDLE)"
	@echo "→ 已清除（字型快取 $(CACHE) 保留）"
