#!/bin/zsh
# 查询中国区 App Store，列出可能冒用“橘阅 / Legado”的应用。
# 用法：scripts/appstore-clone-check.sh
set -euo pipefail

terms=("橘阅" "Legado" "Legado iOS" "开源阅读")
seen_file=$(mktemp)
trap 'mv "$seen_file" /tmp/appstore-clone-seen-$$.txt 2>/dev/null || true' EXIT

for term in "${terms[@]}"; do
  echo "== $term"
  encoded=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$term")
  curl -fsSL "https://itunes.apple.com/search?term=${encoded}&entity=software&country=cn&limit=50" \
    | jq -r --arg term "$term" '
        .results[]
        | select(
            (.trackName | ascii_downcase | contains($term | ascii_downcase))
            or (.bundleId | ascii_downcase | contains("legado"))
          )
        | [.trackName, .sellerName, .bundleId, .trackViewUrl]
        | @tsv' \
    | while IFS=$'\t' read -r name seller bundle url; do
        key="${bundle}"
        if ! grep -qxF "$key" "$seen_file"; then
          echo "$key" >> "$seen_file"
          printf '%s\t%s\t%s\t%s\n' "$name" "$seller" "$bundle" "$url"
        fi
      done
done
