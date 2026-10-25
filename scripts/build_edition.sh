#!/usr/bin/env bash
# 一份源码出两种包：sideload（全功能侧载）/ appstore（商店干净版）。
# 用法: scripts/build_edition.sh sideload|appstore [archive|build]
set -euo pipefail

MODE="${1:-sideload}"
ACTION="${2:-archive}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Legado.xcodeproj"
SCHEME="${SCHEME:-LegadoApp}"
OUT="$ROOT/build"

common=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=iOS"
  -derivedDataPath "$OUT/DerivedData"
)

case "$MODE" in
  sideload)
    overrides=(
      PRODUCT_BUNDLE_IDENTIFIER=com.factorcitrus.juyue
      PRODUCT_NAME=Juyue
      INFOPLIST_FILE=Sources/LegadoApp/Info.plist
      INFOPLIST_KEY_CFBundleDisplayName=橘阅
      SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited)'
    )
    ;;
  appstore)
    overrides=(
      PRODUCT_BUNDLE_IDENTIFIER=com.factorcitrus.juyue.reader
      PRODUCT_NAME=JuyueReader
      INFOPLIST_FILE=Sources/LegadoApp/Info-AppStore.plist
      INFOPLIST_KEY_CFBundleDisplayName=橘阅阅读器
      SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) JUYUE_APPSTORE'
    )
    ;;
  *)
    echo "usage: $0 sideload|appstore [archive|build]" >&2
    exit 2
    ;;
esac

mkdir -p "$OUT"
if [ "$ACTION" = "archive" ]; then
  xcodebuild "${common[@]}" "${overrides[@]}" \
    -archivePath "$OUT/Juyue-${MODE}.xcarchive" archive
elif [ "$ACTION" = "build" ]; then
  xcodebuild "${common[@]}" "${overrides[@]}" build
else
  echo "unknown action: $ACTION" >&2
  exit 2
fi
