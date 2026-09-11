#!/usr/bin/env bash
# 取得內嵌用的中文字型，放到 .cache/fonts/。
#
# 楷體：霞鶩文楷 LXGW WenKai TC（比例版與等寬版）
# 黑體：更紗黑體 Sarasa Gothic TC / Sarasa Mono TC
#
# 每種只要 Regular 一個字面 —— 粗體的訊號交給顏色，不交給字重。
# 依序找：書庫的 fonts/ → 系統已安裝 → 官方 release 下載。
set -euo pipefail

DEST="${1:?用法: fetch-fonts.sh <目的資料夾>}"
mkdir -p "$DEST"

BOOKS_FONTS="$HOME/books/fonts"
SYSTEM_FONTS=("$HOME/Library/Fonts" "/Library/Fonts")

SARASA_VER="1.0.41"
SARASA_BASE="https://github.com/be5invis/Sarasa-Gothic/releases/download/v${SARASA_VER}"
LXGW_BASE="https://github.com/lxgw/LxgwWenKaiTC/releases/download/v1.520"

# 檔名｜取得方式｜網址
#   ttf = 直接下載；7z  = 下載壓縮檔再抽出同名檔案
WANTED=(
  "LXGWWenKaiTC-Regular.ttf|ttf|${LXGW_BASE}/LXGWWenKaiTC-Regular.ttf"
  "LXGWWenKaiMonoTC-Regular.ttf|ttf|${LXGW_BASE}/LXGWWenKaiMonoTC-Regular.ttf"
  "SarasaGothicTC-Regular.ttf|7z|${SARASA_BASE}/SarasaGothicTC-TTF-${SARASA_VER}.7z"
  "SarasaMonoTC-Regular.ttf|7z|${SARASA_BASE}/SarasaMonoTC-TTF-${SARASA_VER}.7z"
)

fail() {
  echo "  ✗ 取不到 $1" >&2
  echo "    手動放一份到 $DEST/ 再重跑 make。" >&2
  echo "    來源：$2" >&2
  exit 1
}

for entry in "${WANTED[@]}"; do
  IFS='|' read -r name kind url <<<"$entry"

  [[ -f "$DEST/$name" ]] && { echo "  已有　$name"; continue; }

  if [[ -f "$BOOKS_FONTS/$name" ]]; then
    cp "$BOOKS_FONTS/$name" "$DEST/$name"
    echo "  books  $name"
    continue
  fi

  found=""
  for dir in "${SYSTEM_FONTS[@]}"; do
    [[ -f "$dir/$name" ]] && { cp "$dir/$name" "$DEST/$name"; found=1; break; }
  done
  [[ -n "$found" ]] && { echo "  系統　$name"; continue; }

  case "$kind" in
    ttf)
      echo "  下載　$name"
      curl -fsSL --retry 2 -o "$DEST/$name.part" "$url" || fail "$name" "$url"
      mv "$DEST/$name.part" "$DEST/$name"
      ;;
    7z)
      # 官方只提供 7z，而且是整個家族一包（約 60 MB）才拿得到那一個字面。
      # 抽完就把壓縮檔刪掉，快取裡只留 ttf。
      command -v 7z >/dev/null || fail "$name" "${url}（需要 7z：brew install p7zip）"
      echo "  下載　${name}（來源是 60 MB 的家族壓縮檔，只抽這一個字面）"
      tmp="$(mktemp -d)"
      curl -fsSL --retry 2 -o "$tmp/a.7z" "$url" || fail "$name" "$url"
      7z e -y -o"$tmp" "$tmp/a.7z" "$name" >/dev/null || fail "$name" "$url"
      [[ -f "$tmp/$name" ]] || fail "$name" "$url"
      mv "$tmp/$name" "$DEST/$name"
      rm -rf "$tmp"
      ;;
  esac
done
