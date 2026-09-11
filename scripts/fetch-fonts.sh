#!/usr/bin/env bash
# 取得內嵌用的霞鶩文楷字型，放到 .cache/fonts/。
#
# 只需要 Regular 一個字面 —— 粗體的訊號交給顏色，不交給字重。
# 依序找：書庫的 fonts/ → 系統已安裝 → 從 LXGW 官方 release 下載。
set -euo pipefail

DEST="${1:?用法: fetch-fonts.sh <目的資料夾>}"
mkdir -p "$DEST"

BOOKS_FONTS="$HOME/books/fonts"
SYSTEM_FONTS=("$HOME/Library/Fonts" "/Library/Fonts")

# 檔名 → 官方 release 的下載網址
declare -a WANTED=(
  "LXGWWenKaiTC-Regular.ttf|https://github.com/lxgw/LxgwWenKaiTC/releases/download/v1.520/LXGWWenKaiTC-Regular.ttf"
  "LXGWWenKaiMonoTC-Regular.ttf|https://github.com/lxgw/LxgwWenKaiTC/releases/download/v1.520/LXGWWenKaiMonoTC-Regular.ttf"
)

for entry in "${WANTED[@]}"; do
  name="${entry%%|*}"
  url="${entry##*|}"

  if [[ -f "$DEST/$name" ]]; then
    echo "  已有　$name"
    continue
  fi

  if [[ -f "$BOOKS_FONTS/$name" ]]; then
    cp "$BOOKS_FONTS/$name" "$DEST/$name"
    echo "  books  $name"
    continue
  fi

  found=""
  for dir in "${SYSTEM_FONTS[@]}"; do
    if [[ -f "$dir/$name" ]]; then
      cp "$dir/$name" "$DEST/$name"
      found="$dir"
      break
    fi
  done
  if [[ -n "$found" ]]; then
    echo "  系統　$name"
    continue
  fi

  echo "  下載　$name"
  if ! curl -fsSL --retry 2 -o "$DEST/$name.part" "$url"; then
    rm -f "$DEST/$name.part"
    echo "  ✗ 取不到 $name" >&2
    echo "    手動放一份到 $DEST/ 或 ~/Library/Fonts/ 再重跑 make。" >&2
    echo "    來源：https://github.com/lxgw/LxgwWenKaiTC/releases" >&2
    exit 1
  fi
  mv "$DEST/$name.part" "$DEST/$name"
done
