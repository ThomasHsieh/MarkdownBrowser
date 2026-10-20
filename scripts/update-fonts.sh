#!/usr/bin/env bash
# make fonts-update：發版前手動跑一次（docs/SPEC.md 第 7 節）。
#
# 查每套字型在 GitHub 上的最新 release，比 fetch-fonts.sh 鎖定的版本新就改寫版本號，
# 再跑一次 fetch-fonts.sh —— 快取裡版本不符的檔會被換掉。版本號的變動跟著那次發版 commit。
# 不放進每次 make：每次建置都要連網，而且換版可能改變字形與行距，要建置出來看過才算數。
set -euo pipefail

FETCH="scripts/fetch-fonts.sh"
CACHE="${1:?用法: update-fonts.sh <快取資料夾> <font-version 工具>}"
TOOL="${2:?用法: update-fonts.sh <快取資料夾> <font-version 工具>}"

# fetch-fonts.sh 裡的變數｜GitHub repo｜名稱
FAMILIES=(
  "LXGW_VER|lxgw/LxgwWenKaiTC|霞鶩文楷 TC"
  "SARASA_VER|be5invis/Sarasa-Gothic|更紗黑體"
  "GENWAN_VER|ButTaiwan/genwan-font|源雲明體"
  "HUNINN_VER|justfont/open-huninn-font|jf open 粉圓"
)

latest_tag() {
  # 不需要 gh：GitHub API 未登入每小時 60 次，這裡只查四次
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
    sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1
}

changed=0
for entry in "${FAMILIES[@]}"; do
  IFS='|' read -r var repo label <<<"$entry"
  current="$(sed -n "s/^${var}=\"\(.*\)\"$/\1/p" "$FETCH")"
  latest="$(latest_tag "$repo" || true)"
  if [[ -z "$latest" ]]; then
    echo "  ？　${label}：查不到最新版（網路或 GitHub API 限制），維持 $current"
  elif [[ "$latest" == "$current" ]]; then
    echo "  ＝　$label $current 已是最新"
  else
    sed -i '' "s/^${var}=\"${current}\"$/${var}=\"${latest}\"/" "$FETCH"
    echo "  ↑　$label $current → $latest"
    changed=1
  fi
done

if [[ "$changed" == 1 ]]; then
  echo "→ 取新版字型"
  bash "$FETCH" "$CACHE" "$TOOL"
  echo "→ 有字型換版：make run 看過字形與行距，再跟著這次發版 commit $FETCH"
fi
