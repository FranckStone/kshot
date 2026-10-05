#!/bin/bash
# 由 tools/make-icon.swift 生成 1024 PNG，再打包成 Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swiftc -O tools/make-icon.swift -o "$TMP/make-icon" 2>&1 | grep -v warning || true
"$TMP/make-icon" "${ICON_VARIANT:-corners-cross}" Resources/AppIcon-1024.png
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "✅ Resources/AppIcon.icns"
