#!/usr/bin/env bash
# 取得內嵌用的中文字型，放到 .cache/fonts/（docs/SPEC.md 第 7 節）。
#
# 楷體：霞鶩文楷 LXGW WenKai TC（比例版與等寬版）
# 黑體：更紗黑體 Sarasa Gothic TC / Sarasa Mono TC（明體、圓體的程式碼也用 Sarasa Mono）
# 明體：源雲明體 GenWanMin2 TW（月版）
# 圓體：jf open 粉圓
#
# 每種只要 Regular 一個字面 —— 粗體的訊號交給顏色，不交給字重。
# 依序找：快取 → ${FONTS_DIR}（有設才找）→ 系統已安裝 → 官方 release 下載。
# 每一處找到的檔都要讀出字型檔裡的版本、跟下面鎖定的一樣才用：檔名不帶版本的字型，
# 只比檔名會用到放在那裡的任何一版。字型放在自己的資料夾時，在 shell 設定裡
# export FONTS_DIR=<那個資料夾>。
#
# 版本號由 `make fonts-update` 改寫（scripts/update-fonts.sh），格式要維持 NAME_VER="x.y"。
set -euo pipefail

DEST="${1:?用法: fetch-fonts.sh <目的資料夾> <font-version 工具>}"
VERSION_TOOL="${2:?用法: fetch-fonts.sh <目的資料夾> <font-version 工具>}"
mkdir -p "$DEST"

FONTS_DIR="${FONTS_DIR:-}"
SYSTEM_FONTS=("$HOME/Library/Fonts" "/Library/Fonts")

LXGW_VER="1.530"
SARASA_VER="1.0.42"
GENWAN_VER="2.100"
HUNINN_VER="2.1"

LXGW_BASE="https://github.com/lxgw/LxgwWenKaiTC/releases/download/v${LXGW_VER}"
SARASA_BASE="https://github.com/be5invis/Sarasa-Gothic/releases/download/v${SARASA_VER}"
GENWAN_BASE="https://github.com/ButTaiwan/genwan-font/releases/download/v${GENWAN_VER}"
HUNINN_BASE="https://github.com/justfont/open-huninn-font/releases/download/v${HUNINN_VER}"

# 快取裡的檔名｜在別處找的檔名｜版本｜取得方式｜網址
#   快取裡的檔名固定，fonts.css 才不必跟著版本改；粉圓的官方檔名帶版本
#   ttf = 直接下載；7z、zip = 下載壓縮檔再抽出那一個檔
WANTED=(
  "LXGWWenKaiTC-Regular.ttf|LXGWWenKaiTC-Regular.ttf|${LXGW_VER}|ttf|${LXGW_BASE}/LXGWWenKaiTC-Regular.ttf"
  "LXGWWenKaiMonoTC-Regular.ttf|LXGWWenKaiMonoTC-Regular.ttf|${LXGW_VER}|ttf|${LXGW_BASE}/LXGWWenKaiMonoTC-Regular.ttf"
  "SarasaGothicTC-Regular.ttf|SarasaGothicTC-Regular.ttf|${SARASA_VER}|7z|${SARASA_BASE}/SarasaGothicTC-TTF-${SARASA_VER}.7z"
  "SarasaMonoTC-Regular.ttf|SarasaMonoTC-Regular.ttf|${SARASA_VER}|7z|${SARASA_BASE}/SarasaMonoTC-TTF-${SARASA_VER}.7z"
  "GenWanMin2TW-R.otf|GenWanMin2TW-R.otf|${GENWAN_VER}|zip|${GENWAN_BASE}/GenWanMin2TW-otf.zip"
  "jf-openhuninn.ttf|jf-openhuninn-${HUNINN_VER}.ttf|${HUNINN_VER}|ttf|${HUNINN_BASE}/jf-openhuninn-${HUNINN_VER}.ttf"
)

fail() {
  echo "  ✗ 取不到 $1" >&2
  echo "    手動放一份（版本 $3）到 \$FONTS_DIR 再重跑 make。" >&2
  echo "    來源：$2" >&2
  exit 1
}

version_of() { "$VERSION_TOOL" "$1" 2>/dev/null || true; }

# 版本對得上就複製進快取；對不上回傳失敗，讓呼叫端繼續找下一處
take() {
  local src="$1" dest="$2" want="$3" label="$4"
  [[ -f "$src" ]] || return 1
  local got
  got="$(version_of "$src")"
  if [[ "$got" != "$want" ]]; then
    echo "  略過　${src/#$HOME/~}（版本 ${got:-?}，要 ${want}）"
    return 1
  fi
  cp "$src" "$DEST/$dest"
  echo "  ${label}　$dest $want"
}

# 快取裡不在清單上的檔（舊版、已經不用的字型）清掉，免得一起被打包
for f in "$DEST"/*; do
  [[ -e "$f" ]] || continue
  keep=""
  for entry in "${WANTED[@]}"; do [[ "$(basename "$f")" == "${entry%%|*}" ]] && keep=1; done
  [[ -n "$keep" ]] || { rm -f "$f"; echo "  清掉　$(basename "$f")"; }
done

for entry in "${WANTED[@]}"; do
  IFS='|' read -r dest name want kind url <<<"$entry"

  if [[ -f "$DEST/$dest" ]]; then
    got="$(version_of "$DEST/$dest")"
    [[ "$got" == "$want" ]] && { echo "  已有　$dest $want"; continue; }
    echo "  換新　${dest}（快取是 ${got:-?}，要 ${want}）"
    rm -f "$DEST/$dest"
  fi

  [[ -n "$FONTS_DIR" ]] && take "$FONTS_DIR/$name" "$dest" "$want" "自訂" && continue
  found=""
  for dir in "${SYSTEM_FONTS[@]}"; do
    take "$dir/$name" "$dest" "$want" "系統" && { found=1; break; }
  done
  [[ -n "$found" ]] && continue

  tmp="$(mktemp -d)"
  case "$kind" in
    ttf)
      echo "  下載　$dest $want"
      curl -fsSL --retry 2 -o "$tmp/$name" "$url" || fail "$name" "$url" "$want"
      ;;
    7z)
      # 更紗官方只提供 7z，而且是整個家族一包（約 60 MB）才拿得到那一個字面。
      # macOS 內建的 tar（bsdtar）讀得了 7z，不必另裝 p7zip
      echo "  下載　${dest} ${want}（來源是 60 MB 的家族壓縮檔，只抽這一個字面）"
      curl -fsSL --retry 2 -o "$tmp/a.7z" "$url" || fail "$name" "$url" "$want"
      tar -xf "$tmp/a.7z" -C "$tmp" "$name" 2>/dev/null || fail "$name" "$url" "$want"
      ;;
    zip)
      # 源雲明體只有整包 zip（約 84 MB，五個字重），只抽 Regular。不管壓縮檔裡的資料夾層級
      echo "  下載　$dest ${want}（來源是 84 MB 的整包 zip，只抽這一個字面）"
      curl -fsSL --retry 2 -o "$tmp/a.zip" "$url" || fail "$name" "$url" "$want"
      unzip -j -o -q "$tmp/a.zip" "*/$name" "$name" -d "$tmp" 2>/dev/null || true
      ;;
  esac
  [[ -f "$tmp/$name" ]] || fail "$name" "$url" "$want"
  got="$(version_of "$tmp/$name")"
  # 官方檔案自己記載的版本跟 release 標籤不一樣時，照樣用，但講出來
  [[ "$got" == "$want" ]] || echo "  ⚠️  $name 檔內記載的版本是 ${got:-?}，release 標籤是 $want"
  mv "$tmp/$name" "$DEST/$dest"
  rm -rf "$tmp"
done
