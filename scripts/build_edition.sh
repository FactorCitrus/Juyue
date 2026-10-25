#!/usr/bin/env bash
# 一份源码出两种包：sideload（全功能侧载）/ appstore（商店干净版）。
# 用法: scripts/build_edition.sh sideload|appstore [archive|build]
set -euo pipefail

MODE="${1:-sideload}"
ACTION="${2:-archive}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
DESTINATION="${DESTINATION:-generic/platform=iOS}"

case "$MODE" in
  sideload) scheme="LegadoApp";   configuration="Release" ;;
  appstore) scheme="JuyueReader"; configuration="AppStore" ;;
  *) echo "usage: $0 sideload|appstore [archive|build]" >&2; exit 2 ;;
esac

if [ "$MODE" = "sideload" ] && [[ "$DESTINATION" == *Simulator* ]]; then
  echo "WARN: 侧载版链接百度静态库（仅 iOS arm64 切片），模拟器目标必然链接失败。" >&2
  echo "      验证侧载代码用 DESTINATION='generic/platform=iOS'。" >&2
fi

args=(
  -project "$ROOT/Legado.xcodeproj"
  -scheme "$scheme"
  -configuration "$configuration"
  -destination "$DESTINATION"
  -derivedDataPath "$OUT/DerivedData"
)
overrides=()
if [ "${NO_SIGN:-0}" = "1" ]; then
  overrides+=(CODE_SIGNING_ALLOWED=NO)
fi
if [ -n "${ARCHS:-}" ]; then
  overrides+=(ARCHS="$ARCHS")
fi
if [ -n "${MARKETING_VERSION:-}" ]; then
  overrides+=(MARKETING_VERSION="$MARKETING_VERSION"
              CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-$MARKETING_VERSION}")
fi

mkdir -p "$OUT"
case "$ACTION" in
  archive) xcodebuild "${args[@]}" "${overrides[@]}" -archivePath "$OUT/Juyue-${MODE}.xcarchive" archive ;;
  build)   xcodebuild "${args[@]}" "${overrides[@]}" build ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
